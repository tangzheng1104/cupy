from cpython cimport sequence

from libcpp cimport vector

from cupy.core cimport _carray
from cupy.core._carray cimport shape_t
from cupy.core._dtype cimport get_dtype
from cupy.core cimport _kernel
from cupy.core._kernel cimport _broadcast
from cupy.core._kernel cimport _check_array_device_id
from cupy.core._kernel cimport _get_arginfos
from cupy.core._kernel cimport _get_kernel_params
from cupy.core._kernel cimport _get_out_args
from cupy.core._kernel cimport _get_out_args_with_params
from cupy.core._kernel cimport _preprocess_args
from cupy.core._kernel cimport _reduce_dims
from cupy.core._kernel cimport ParameterInfo, _ArgInfo
from cupy.core cimport _optimize_config
from cupy.core cimport _routines_manipulation as _manipulation
from cupy.core cimport _scalar
from cupy.core._scalar import get_typename as _get_typename
from cupy.core.core cimport _convert_object_with_cuda_array_interface
from cupy.core.core cimport _create_ndarray_from_shape_strides
from cupy.core.core cimport _internal_asfortranarray
from cupy.core.core cimport compile_with_cache
from cupy.core.core cimport ndarray
from cupy.core cimport internal
from cupy.cuda cimport device
from cupy.cuda cimport function
from cupy.cuda cimport memory
from cupy.cuda cimport runtime

import math
import string

import numpy

from cupy.core._kernel import _get_param_info
from cupy.core._kernel import _decide_params_type
from cupy.core._ufuncs import elementwise_copy
from cupy.cuda import compiler
from cupy import util
from cupy import _environment


cpdef function.Function _create_reduction_function(
        name, block_size, reduce_type, params, arginfos, identity,
        pre_map_expr, reduce_expr, post_map_expr,
        _kernel._TypeMap type_map, input_expr, output_expr, preamble, options):
    module_code = string.Template('''
${type_preamble}
${preamble}
#define REDUCE(a, b) (${reduce_expr})
#define POST_MAP(a) (${post_map_expr})
#define _REDUCE(_offset) if (_tid < _offset) { \
  _type_reduce _a = _sdata[_tid], _b = _sdata[(_tid + _offset)]; \
  _sdata[_tid] = REDUCE(_a, _b); \
}

typedef ${reduce_type} _type_reduce;
extern "C" __global__ void ${name}(${params}) {
  __shared__ char _sdata_raw[${block_size} * sizeof(_type_reduce)];
  _type_reduce *_sdata = reinterpret_cast<_type_reduce*>(_sdata_raw);
  unsigned int _tid = threadIdx.x;

  int _J_offset = _tid >> __popc(_block_stride - 1);  // _tid / _block_stride
  ptrdiff_t _j_offset = (ptrdiff_t)_J_offset * _out_ind.size();
  int _J_stride = ${block_size} >> __popc(_block_stride - 1);
  ptrdiff_t _j_stride = (ptrdiff_t)_J_stride * _out_ind.size();

  for (ptrdiff_t _i_base = (ptrdiff_t)blockIdx.x * _block_stride;
       _i_base < _out_ind.size();
       _i_base += (ptrdiff_t)gridDim.x * _block_stride) {
    _type_reduce _s = _type_reduce(${identity});
    ptrdiff_t _i =
        _i_base + (_tid & (_block_stride - 1));  // _tid % _block_stride
    int _J = _J_offset;
    for (ptrdiff_t _j = _i + _j_offset; _j < _in_ind.size();
         _j += _j_stride, _J += _J_stride) {
      _in_ind.set(_j);
      ${input_expr}
      _type_reduce _a = static_cast<_type_reduce>(${pre_map_expr});
      _s = REDUCE(_s, _a);
    }
    _sdata[_tid] = _s;
    __syncthreads();
    for (unsigned int _block = ${block_size} / 2;
         _block >= _block_stride; _block >>= 1) {
      if (_tid < _block) {
        _REDUCE(_block);
      }
      __syncthreads();
    }
    if (_tid < _block_stride) {
      _s = _sdata[_tid];
    }
    if (_tid < _block_stride && _i < _out_ind.size()) {
      _out_ind.set(static_cast<ptrdiff_t>(_i));
      ${output_expr}
      POST_MAP(_s);
    }
  }
}''').substitute(
        name=name,
        block_size=block_size,
        reduce_type=reduce_type,
        params=_kernel._get_kernel_params(params, arginfos),
        identity=identity,
        reduce_expr=reduce_expr,
        pre_map_expr=pre_map_expr,
        post_map_expr=post_map_expr,
        type_preamble=type_map.get_typedef_code(),
        input_expr=input_expr,
        output_expr=output_expr,
        preamble=preamble)
    module = compile_with_cache(module_code, options)
    return module.get_function(name)


cpdef function.Function _create_cub_reduction_function(
        name, block_size, items_per_thread,
        reduce_type, params, arginfos, identity,
        pre_map_expr, reduce_expr, post_map_expr,
        _kernel._TypeMap type_map, preamble, options):
    # static_assert needs at least C++11 in NVRTC
    options += ('--std=c++11',)

    # TODO(leofang): try splitting the for-loop into full tiles and partial
    # tiles to utilize LoadDirectBlockedVectorized? See, for example,
    # https://github.com/NVlabs/cub/blob/c3cceac115c072fb63df1836ff46d8c60d9eb304/cub/agent/agent_reduce.cuh#L311-L346

    cdef str module_code = _get_cub_header_include()
    module_code += '''
${preamble}

${type_preamble}
typedef ${reduce_type} _type_reduce;

static_assert(sizeof(_type_reduce) <= 32,
    "The intermediate reduction type is assumed to be at most 32 bytes.");

// Compile-time constants for CUB template specializations
#define ITEMS_PER_THREAD  ${items_per_thread}
#define BLOCK_SIZE        ${block_size}

#if defined FIRST_PASS
    typedef type_in0_raw  type_mid_in;
    typedef _type_reduce  type_mid_out;
    #define POST_MAP(a)   out0 = a;
#elif defined SECOND_PASS
    typedef _type_reduce  type_mid_in;
    typedef type_out0_raw type_mid_out;
    #define POST_MAP(a)   (${post_map_expr})
#else  // one-pass reduction
    typedef type_in0_raw  type_mid_in;
    typedef type_out0_raw type_mid_out;
    #define POST_MAP(a)   (${post_map_expr})
#endif

struct _reduction_op {
    __device__ __forceinline__ _type_reduce operator()(
        const _type_reduce &a, const _type_reduce &b) const {
        return ${reduce_expr};
    }
};

extern "C"
__global__ void ${name}(${params}) {
  unsigned int _tid = threadIdx.x;
'''

    if pre_map_expr == 'in0':
        module_code += '''
  // Specialize BlockLoad type for faster (?) loading
  typedef cub::BlockLoad<_type_reduce, BLOCK_SIZE,
                         ITEMS_PER_THREAD, cub::BLOCK_LOAD_DIRECT> BlockLoadT;

  // Shared memory for loading
  __shared__ typename BlockLoadT::TempStorage temp_storage_load;
'''

    module_code += '''
  // Specialize BlockReduce type for our thread block
  typedef cub::BlockReduce<_type_reduce, BLOCK_SIZE> BlockReduceT;

  // Shared memory for reduction
  __shared__ typename BlockReduceT::TempStorage temp_storage;

  // Declare reduction operation
  _reduction_op op;

  // input & output raw pointers
  const type_mid_in* _in0 = static_cast<const type_mid_in*>(_raw_in0);
  type_mid_out* _out0 = static_cast<type_mid_out*>(_raw_out0);

  // Per-thread tile data
  _type_reduce _sdata[ITEMS_PER_THREAD];
  #pragma unroll
  for (int j = 0; j < ITEMS_PER_THREAD; j++) {
      _sdata[j] = _type_reduce(${identity});
  }

  // each block handles the reduction of 1 segment
  size_t segment_id = blockIdx.x * _segment_size;
  const type_mid_in* segment_head = _in0 + segment_id;
  size_t i = 0;  // tile head within the segment
  int tile_size = (BLOCK_SIZE * ITEMS_PER_THREAD < _segment_size ?
                   BLOCK_SIZE * ITEMS_PER_THREAD :
                   _segment_size);

  #if defined FIRST_PASS
  // for two-pass reduction only: "last segment" is special
  if (_array_size > 0) {
      if (_array_size - segment_id <= _segment_size) {
          _segment_size = _array_size - segment_id;
      }
  }
  #endif

  // loop over tiles within 1 segment
  _type_reduce aggregate = _type_reduce(${identity});
  for (i = 0; i < _segment_size; i += BLOCK_SIZE * ITEMS_PER_THREAD) {
      // for the last tile
      if (_segment_size - i <= tile_size) { tile_size = _segment_size - i; }
'''

    if pre_map_expr == 'in0':
        module_code += '''
      // load a tile
      BlockLoadT(temp_storage_load).Load(segment_head + i, _sdata, tile_size,
                                         _type_reduce(${identity}));
'''
    else:  # pre_map_expr could be something like "in0 != type_in0_raw(0)"
        module_code += '''
      // load a tile
      #pragma unroll
      for (int j = 0; j < ITEMS_PER_THREAD; j++) {
          // index of the element in a tile
          int e_idx = _tid * ITEMS_PER_THREAD + j;

          // some pre_map_expr uses _J internally...
          #if defined FIRST_PASS
          int _J = (segment_id + i + e_idx);
          #else  // only one pass
          int _J = (segment_id + i + e_idx) % _segment_size;
          #endif

          if (e_idx < tile_size) {
              const type_mid_in in0 = *(segment_head + i + e_idx);
              _sdata[j] = static_cast<_type_reduce>(${pre_map_expr});
          } else {
              _sdata[j] = _type_reduce(${identity});
          }
      }
'''

    module_code += '''
      // Compute block reduction
      // Note that the output is only meaningful for thread 0
      aggregate = op(aggregate, BlockReduceT(temp_storage).Reduce(_sdata, op));

      __syncthreads();  // for reusing temp_storage
  }

  if (_tid == 0) {
      type_mid_out& out0 = *(_out0 + blockIdx.x);
      POST_MAP(aggregate);
  }
}
'''

    module_code = string.Template(module_code).substitute(
        name=name,
        block_size=block_size,
        items_per_thread=items_per_thread,
        reduce_type=reduce_type,
        params=_get_cub_kernel_params(params, arginfos),
        identity=identity,
        reduce_expr=reduce_expr,
        pre_map_expr=pre_map_expr,
        post_map_expr=post_map_expr,
        type_preamble=type_map.get_typedef_code(),
        preamble=preamble)

    # CUB is not natively supported by NVRTC (NVlabs/cub#131), so use nvcc
    # instead. For this, we have to explicitly spell out the default values for
    # arch, cachd, and prepend_cupy_headers to bypass cdef/cpdef limitation...
    # TODO(leofang): investigate Jitify for using NVRTC (also NVlabs/cub#171)
    module = compile_with_cache(
        module_code, options, arch=None, cachd_dir=None,
        prepend_cupy_headers=True, backend='nvcc')
    return module.get_function(name)


cdef str _cub_path = _environment.get_cub_path()
cdef str _cub_header = None


cdef str _get_cub_header_include():
    global _cub_header
    if _cub_header is not None:
        return _cub_header

    assert _cub_path is not None
    if _cub_path == '<bundle>':
        _cub_header = '''
#include <cupy/cub/cub/block/block_reduce.cuh>
#include <cupy/cub/cub/block/block_load.cuh>
'''
    elif _cub_path == '<CUDA>':
        _cub_header = '''
#include <cub/block/block_reduce.cuh>
#include <cub/block/block_load.cuh>
'''
    else:
        _cub_header = '''
#include \"${CUB}/cub/block/block_reduce.cuh\"
#include \"${CUB}/cub/block/block_load.cuh\"
'''
        _cub_header = string.Template(_cub_header).substitute(CUB=_cub_path)
    return _cub_header


# make it cpdef'd for unit tests
cpdef inline tuple _can_use_cub_block_reduction(
        list in_args, list out_args, tuple reduce_axis, tuple out_axis):
    '''
    If CUB BlockReduce can be used, this function returns a tuple of the needed
    parameters, otherwise returns None.
    '''
    from cupy import core

    cdef tuple axis_permutes_cub
    cdef ndarray in_arr, out_arr
    cdef Py_ssize_t contiguous_size = 1

    # first check the flag settable at runtime from outside
    if not core.cub_block_reduction_enabled:
        return None

    # detect whether CUB headers exists somewhere:
    if _cub_path is None:
        import warnings
        warnings.warn('cupy.core.cub_block_reduction_enabled is set to True, '
                      'but the CUB headers are not found, please set the '
                      'environment variable CUPY_CUB_PATH to the CUB '
                      'location.', RuntimeWarning)
        return None

    # rare event (mainly for conda-forge users): nvcc is not found!
    if _environment.get_nvcc_path() is None:
        return None

    # we currently support only _SimpleReductionKernel
    if len(in_args) != 1 or len(out_args) != 1:
        return None

    in_arr = in_args[0]
    out_arr = out_args[0]

    # To support generic reductions, note that some NumPy casting rules
    # are not applicable in the C++ space (unless we tweak the type
    # definitions). To circumvent this, we fall back to the old kernel.
    # TODO(leofang): can we relax this?
    if in_arr.dtype.kind != out_arr.dtype.kind:
        # cannot cast complex to anything else
        if in_arr.dtype.kind == 'c':
            return None
        # cannot cast float16 to complex
        if in_arr.dtype.char == 'e' and out_arr.dtype.kind == 'c':
            return None

    # check reduction axes, if not contiguous then fall back to old kernel
    reduce_axis = tuple(sorted(reduce_axis))
    out_axis = tuple(sorted(out_axis))
    if in_arr.flags.f_contiguous:
        axis_permutes_cub = reduce_axis + out_axis
    elif in_arr.flags.c_contiguous:
        axis_permutes_cub = out_axis + reduce_axis
    else:
        return None
    if axis_permutes_cub != tuple(range(in_arr.ndim)):
        return None

    # full-reduction of N-D array: need to invoke the kernel twice
    cdef bint full_reduction = True if len(out_axis) == 0 else False

    # check if the number of elements is too large
    # (ref: cupy/cupy#3309 for CUB limit)
    for i in reduce_axis:
        contiguous_size *= in_arr.shape[i]
    if contiguous_size > 0x7fffffffffffffff or contiguous_size == 0:
        return None
    if full_reduction:
        # assume a GPU has at most 64 GB of physical memory
        if contiguous_size > 0x1000000000:
            return None
    else:
        # the number of blocks to be launched exceeds INT_MAX:
        if in_arr.size // contiguous_size > 0x7fffffff:
            return None

    return (axis_permutes_cub, contiguous_size, full_reduction)


# similar to cupy.core._kernel._get_kernel_params()
cdef str _get_cub_kernel_params(tuple params, tuple arginfos):
    cdef ParameterInfo p
    cdef _ArgInfo arginfo
    cdef lst = []
    cdef str c_type
    cdef int i
    assert len(params) == len(arginfos)

    for i, (p, arginfo) in enumerate(zip(params, arginfos)):
        if i < len(params) - 2:
            c_type = 'const void*' if p.is_const else 'void*'
        else:
            # for segment size and array size
            c_type = arginfo.get_param_c_type(p)
        lst.append('{} {}'.format(
            c_type,
            arginfo.get_c_var_name(p)))
    return ', '.join(lst)


cdef (Py_ssize_t, Py_ssize_t) _get_cub_block_specs(  # noqa
        Py_ssize_t contiguous_size):
    # This is recommended in the CUB internal and should be an
    # even number
    items_per_thread = 4

    # Calculate the reduction block dimensions.
    # Ideally, we want each block to handle one segment, so:
    # 1. block size < segment size: the block loops over the segment
    # 2. block size >= segment size: the segment fits in the block
    block_size = (contiguous_size + items_per_thread - 1) // items_per_thread
    block_size = internal.clp2(block_size)
    if block_size < 32:
        block_size = 32  # warp size
    elif block_size > _default_block_size:
        # TODO(leofang): try 1024 as maximum?
        block_size = _default_block_size

    return items_per_thread, block_size


cdef _scalar.CScalar _cub_convert_to_c_scalar(
        Py_ssize_t segment_size, Py_ssize_t value):
    if segment_size > 0x7fffffff:
        return _scalar.scalar_to_c_scalar(value)
    else:
        return _scalar.CScalar.from_int32(value)


cdef inline _cub_two_pass_launch(
        str name, Py_ssize_t block_size, Py_ssize_t segment_size,
        Py_ssize_t items_per_thread, str reduce_type, tuple params,
        list in_args, list out_args,
        str identity, str pre_map_expr, str reduce_expr, str post_map_expr,
        _kernel._TypeMap type_map, str input_expr, str output_expr,
        str preamble, tuple options, stream):
    '''
    Notes:
    1. Two-pass reduction: the first pass distributes an even share over
       a number of blocks (with block_size threads), and the second pass
       does reduction over 1 block of threads
    2. input_expr & output_expr are used only as part of the cache key;
       the actual kernel does not use them
    '''

    cdef list out_args_2nd_pass = [out_args[0]]
    cdef Py_ssize_t contiguous_size, out_block_num
    cdef function.Function func
    cdef memory.MemoryPointer memptr
    cdef str post_map_expr1, post_map_expr2
    cdef list inout_args
    cdef tuple cub_params
    cdef size_t gridx, blockx

    # fair share
    contiguous_size = min(segment_size, block_size * items_per_thread)
    out_block_num = (segment_size + contiguous_size - 1) // contiguous_size
    assert out_block_num <= 0x7fffffff

    # Because we can't know sizeof(reduce_type) in advance, here we
    # conservatively assume it's 32 bytes and allocate a work area
    memptr = memory.alloc(out_block_num * 32)
    out_args[0] = memptr

    # ************************ 1st pass ************************
    name += '_pass1'
    inout_args = [in_args[0], out_args[0],
                  _cub_convert_to_c_scalar(segment_size, contiguous_size),
                  _cub_convert_to_c_scalar(segment_size, segment_size)]
    cub_params = (True, items_per_thread)

    # For mean()
    if 'mean' in name:
        post_map_expr1 = post_map_expr.replace('_in_ind.size()', '1.0')
        post_map_expr1 = post_map_expr1.replace('_out_ind.size()', '1.0')
    else:
        post_map_expr1 = post_map_expr

    # Retrieve the kernel function
    func = _SimpleReductionKernel_get_cached_function(
        pre_map_expr, reduce_expr, post_map_expr1, reduce_type,
        params,
        _get_arginfos(inout_args),
        type_map,
        name, block_size, identity,
        input_expr, output_expr, preamble,
        ('-DFIRST_PASS=1',), cub_params)

    # Kernel arguments passed to the __global__ function.
    gridx = <size_t>(out_block_num * block_size)
    blockx = <size_t>block_size

    # Launch the kernel
    func.linear_launch(gridx, inout_args, 0, blockx, stream)

    # ************************ 2nd pass ************************
    name = name[:-1] + '2'
    contiguous_size = out_block_num
    out_block_num = 1
    in_args = out_args
    out_args = out_args_2nd_pass
    inout_args = [in_args[0], out_args[0],
                  _cub_convert_to_c_scalar(segment_size, contiguous_size),
                  _cub_convert_to_c_scalar(segment_size, segment_size)]

    # For mean()
    if 'mean' in name:
        post_map_expr2 = post_map_expr.replace('_in_ind.size()',
                                               '_array_size')
        post_map_expr2 = post_map_expr2.replace('_out_ind.size()', '1.0')
    else:
        post_map_expr2 = post_map_expr

    # Retrieve the kernel function
    func = _SimpleReductionKernel_get_cached_function(
        'in0', reduce_expr, post_map_expr2, reduce_type,
        params,
        _get_arginfos(inout_args),
        type_map,
        name, block_size, identity,
        input_expr, output_expr, preamble,
        ('-DSECOND_PASS=1',), cub_params)

    # Kernel arguments passed to the __global__ function.
    gridx = <size_t>(out_block_num * block_size)
    blockx = <size_t>block_size

    # Launch the kernel
    func.linear_launch(gridx, inout_args, 0, blockx, stream)


cpdef tuple _get_axis(object axis, Py_ssize_t ndim):
    cdef Py_ssize_t dim
    if axis is None:
        return (tuple(range(ndim)), ())
    elif sequence.PySequence_Check(axis):
        axis = tuple(axis)
    else:
        axis = axis,

    for dim in axis:
        if dim < -ndim or dim >= ndim:
            raise numpy.AxisError('Axis overrun')
    reduce_axis = tuple(sorted([dim % ndim for dim in axis]))
    out_axis = tuple([dim for dim in range(ndim) if dim not in reduce_axis])
    return reduce_axis, out_axis


cpdef shape_t _get_out_shape(
        const shape_t& shape, tuple reduce_axis, tuple out_axis,
        bint keepdims):
    cdef shape_t out_shape
    if keepdims:
        out_shape = shape
        for i in reduce_axis:
            out_shape[i] = 1
    else:
        out_shape.reserve(len(out_axis))
        for i in out_axis:
            out_shape.push_back(shape[i])
    return out_shape


cdef shape_t _set_permuted_args(
        list args, tuple axis_permutes, const shape_t& shape, tuple params):
    # This function updates `args`
    cdef ParameterInfo p
    cdef Py_ssize_t i, s
    cdef bint need_permutation = False
    cdef shape_t out_shape
    for i, s in enumerate(axis_permutes):
        if i != s:
            need_permutation = True
            break
    if need_permutation:
        for p in params:
            if p.raw:
                raise NotImplementedError('Illegal conditions')
        for i, a in enumerate(args):
            if isinstance(a, ndarray):
                args[i] = _manipulation._transpose(a, axis_permutes)
        out_shape.reserve(len(axis_permutes))
        for i in axis_permutes:
            out_shape.push_back(shape[i])
        return out_shape
    else:
        return shape


cdef Py_ssize_t _get_contiguous_size(
        list args, tuple params, Py_ssize_t ndim,
        Py_ssize_t out_ndim) except -1:
    '''
    get contiguous size in the *output* axis (not *reduce* axis!)
    '''
    cdef int i, j
    cdef ParameterInfo p
    cdef Py_ssize_t contiguous_size, tmp_contiguous_size, itemsize
    contiguous_size = 1
    for i, a in enumerate(args):
        if not isinstance(a, ndarray):
            continue
        p = params[i]
        if p.raw:
            continue
        tmp_contiguous_size = 1
        itemsize = a.dtype.itemsize
        for j in range(out_ndim):
            if a._strides[ndim-j-1] != tmp_contiguous_size * itemsize:
                break
            tmp_contiguous_size *= a._shape[ndim-j-1]
        contiguous_size = max(contiguous_size, tmp_contiguous_size)
    return contiguous_size


cdef Py_ssize_t _default_block_size = (
    256 if runtime._is_hip_environment else 512)


cpdef (Py_ssize_t, Py_ssize_t, Py_ssize_t) _get_block_specs(  # NOQA
        Py_ssize_t in_size, Py_ssize_t out_size,
        Py_ssize_t contiguous_size,
        Py_ssize_t block_size) except*:
    cdef Py_ssize_t reduce_block_size, block_stride, out_block_num
    if block_size == -1:
        block_size = _default_block_size

    reduce_block_size = max(1, in_size // out_size)
    contiguous_size = min(contiguous_size, 32)
    block_stride = max(contiguous_size, block_size // reduce_block_size)
    block_stride = internal.clp2(block_stride // 2 + 1)  # floor
    out_block_num = (out_size + block_stride - 1) // block_stride

    return block_size, block_stride, out_block_num


def _sort_axis(tuple axis, tuple strides):
    # Sorts axis in the decreasing order of absolute values of strides.
    return tuple(sorted(axis, key=lambda i: -abs(strides[i])))


cdef tuple _get_shape_and_strides(list in_args, list out_args):
    cdef list shape_and_strides = []
    for x in in_args + out_args:
        if isinstance(x, ndarray):
            shape_and_strides.append(x.shape)
            shape_and_strides.append(x.strides)
        else:
            shape_and_strides.append(None)
            shape_and_strides.append(None)
    return tuple(shape_and_strides)


cdef _optimizer_copy_arg(a):
    if isinstance(a, ndarray):
        x = _create_ndarray_from_shape_strides(
            a._shape, a._strides, a.dtype)
        assert a.data.device_id == x.data.device_id
        elementwise_copy(a, x)
        return x
    return a


cdef class _AbstractReductionKernel:

    def __init__(
            self, str name, str identity, str in_params, str out_params):
        assert name is not None
        assert identity is not None
        assert in_params is not None
        assert out_params is not None

        in_params_ = _get_param_info(in_params, True)
        out_params_ = _get_param_info(out_params, False)
        params = (
            in_params_
            + out_params_
            + _get_param_info('CIndexer _in_ind, CIndexer _out_ind', False)
            + _get_param_info('int32 _block_stride', True))

        self.name = name
        self.identity = identity
        self.in_params = in_params_
        self.out_params = out_params_
        self._params = params

    cpdef ndarray _call(
            self,
            list in_args, list out_args,
            const shape_t& a_shape, axis, dtype,
            bint keepdims, bint reduce_dims, int device_id,
            stream, bint try_use_cub=False):
        cdef tuple reduce_axis, out_axis, axis_permutes
        cdef tuple can_use_cub, cub_params
        cdef tuple params, opt_params
        cdef tuple shape_and_strides
        cdef Py_ssize_t i
        cdef Py_ssize_t contiguous_size = -1, items_per_thread
        cdef Py_ssize_t block_size, block_stride, out_block_num = 0
        cdef shape_t in_shape, out_shape
        cdef ndarray ret
        cdef bint use_cub = False, full_reduction = False

        if dtype is not None:
            dtype = get_dtype(dtype).type

        (
            map_expr, reduce_expr, post_map_expr,
            in_types, out_types, reduce_type,
            type_map,
        ) = self._get_expressions_and_types(in_args, out_args, dtype)

        reduce_axis, out_axis = _get_axis(axis, a_shape.size())

        # When there is only one input array, sort the axes in such a way that
        # contiguous (C or F) axes can be squashed in _reduce_dims() later.
        # TODO(niboshi): Support (out_axis) > 1
        if (len(in_args) == 1
                and len(out_axis) <= 1
                and not in_args[0]._c_contiguous):
            strides = in_args[0].strides
            reduce_axis = _sort_axis(reduce_axis, strides)
            out_axis = _sort_axis(out_axis, strides)

        out_shape = _get_out_shape(a_shape, reduce_axis, out_axis, keepdims)
        out_args = self._get_out_args(out_args, out_types, out_shape)
        ret = out_args[0]
        if ret.size == 0:
            return ret

        if self.identity == '' and internal.is_in(a_shape, 0):
            raise ValueError(('zero-size array to reduction operation'
                              ' %s which has no identity') % self.name)

        in_args = [x if isinstance(x, ndarray) else
                   _scalar.CScalar.from_numpy_scalar_with_dtype(x, t)
                   for x, t in zip(in_args, in_types)]

        # decide to use CUB or not
        axis_permutes = reduce_axis + out_axis
        if try_use_cub:
            can_use_cub = _can_use_cub_block_reduction(
                in_args, out_args, reduce_axis, out_axis)
            if can_use_cub is not None:
                use_cub = True
                axis_permutes, contiguous_size, full_reduction = can_use_cub

        in_shape = _set_permuted_args(in_args, axis_permutes,
                                      a_shape, self.in_params)

        if not use_cub:
            if reduce_dims:
                in_shape = _reduce_dims(in_args, self.in_params, in_shape)
                out_shape = _reduce_dims(out_args, self.out_params, out_shape)

            cub_params = (False,)
            params = self._params

            # Calculate the reduction block dimensions.
            optimize_context = _optimize_config.get_current_context()
            if optimize_context is None:
                # Calculate manually
                contiguous_size = _get_contiguous_size(
                    in_args, self.in_params, in_shape.size(), out_shape.size())
                block_size, block_stride, out_block_num = _get_block_specs(
                    internal.prod(in_shape),
                    internal.prod(out_shape),
                    contiguous_size, -1)
            else:
                # Optimize dynamically

                # Calculate a key unique to the reduction setting.
                shape_and_strides = _get_shape_and_strides(in_args, out_args)
                key = (self.name, shape_and_strides,
                       in_types, out_types, reduce_type, device_id,
                       use_cub, full_reduction,)

                opt_params = optimize_context.get_params(key)
                if opt_params is None:
                    opt_params = self._get_optimized_params(
                        optimize_context.config, in_args, out_args,
                        in_shape, out_shape, type_map, map_expr, reduce_expr,
                        post_map_expr, reduce_type, stream)
                    optimize_context.set_params(key, opt_params)
                block_size, block_stride, out_block_num = opt_params
        else:
            # Note: reduce_dims is not needed in this call path

            if in_args[0].flags.f_contiguous:
                ret = out_args[0] = _internal_asfortranarray(ret)

            if not full_reduction:  # just need one pass
                out_block_num = 1  # = number of segments
                for i in out_axis:
                    out_block_num *= in_shape[i]

                if 'mean' in self.name:
                    post_map_expr = post_map_expr.replace('_in_ind.size()',
                                                          '_segment_size')
                    post_map_expr = post_map_expr.replace('_out_ind.size()',
                                                          '1.0')

            if contiguous_size > 0x7fffffff:  # INT_MAX
                size_type = 'uint64 '
            else:
                size_type = 'int32 '
            params = (self._params[0:2]
                      + _get_param_info(size_type + '_segment_size',
                                        not full_reduction)
                      + _get_param_info(size_type + '_array_size', True))

            # Calculate the reduction block dimensions.
            optimize_context = _optimize_config.get_current_context()
            if optimize_context is None:
                # Calculate manually

                items_per_thread, block_size = \
                    _get_cub_block_specs(contiguous_size)
            else:
                # Optimize dynamically

                # Calculate a key unique to the reduction setting.
                shape_and_strides = _get_shape_and_strides(in_args, out_args)
                key = (self.name, shape_and_strides,
                       in_types, out_types, reduce_type, device_id,
                       use_cub, full_reduction,)

                opt_params = optimize_context.get_params(key)
                if opt_params is None:
                    opt_params = self._get_cub_optimized_params(
                        optimize_context.config, in_args, out_args,
                        in_shape, out_shape, type_map, map_expr, reduce_expr,
                        post_map_expr, reduce_type, stream,
                        full_reduction, out_block_num, contiguous_size, params)
                    optimize_context.set_params(key, opt_params)
                items_per_thread, block_size = opt_params

            block_stride = block_size * items_per_thread
            cub_params = (
                True, items_per_thread, contiguous_size, full_reduction)

        # Launch the kernel
        self._launch(
            out_block_num,
            block_size,
            block_stride,
            in_args, out_args,
            in_shape, out_shape,
            type_map,
            map_expr, reduce_expr, post_map_expr, reduce_type,
            stream, params, cub_params)

        return ret

    def _get_optimized_params(
            self, optimize_config, in_args, out_args, in_shape, out_shape,
            type_map, map_expr, reduce_expr, post_map_expr, reduce_type,
            stream):
        out_size = internal.prod(out_shape)
        in_args = [_optimizer_copy_arg(a) for a in in_args]
        out_args = [_optimizer_copy_arg(a) for a in out_args]

        contiguous_size = _get_contiguous_size(
            in_args, self.in_params, len(in_shape), len(out_shape))
        block_size, block_stride, default_out_block_num = _get_block_specs(
            internal.prod(in_shape),
            internal.prod(out_shape),
            contiguous_size, -1)
        default_block_size_log = math.floor(math.log2(block_size))
        default_block_stride_log = math.floor(math.log2(block_stride))

        def target_func(block_size, block_stride, out_block_num):
            self._launch(
                out_block_num, block_size, block_stride, in_args, out_args,
                in_shape, out_shape, type_map, map_expr, reduce_expr,
                post_map_expr, reduce_type, stream, self._params, (False,))

        def suggest_func(trial):
            block_size_log = trial.suggest_int('block_size_log', 5, 9)
            block_size = 2 ** block_size_log
            block_stride_log = trial.suggest_int(
                'block_stride_log', 0, block_size_log)
            block_stride = 2 ** block_stride_log
            max_out_block_num = (out_size + block_stride - 1) // block_stride
            out_block_num = trial.suggest_int(
                'out_block_num', 1, max_out_block_num)

            trial.set_user_attr('block_size', block_size)
            trial.set_user_attr('block_stride', block_stride)
            return block_size, block_stride, out_block_num

        optimize_impl = optimize_config.optimize_impl
        best = optimize_impl(
            optimize_config, target_func, suggest_func,
            default_best={
                'block_size_log': default_block_size_log,
                'block_stride_log': default_block_stride_log,
                'out_block_num': default_out_block_num,
            }
        )
        return (
            best.user_attrs['block_size'],
            best.user_attrs['block_stride'],
            best.params['out_block_num'])

    def _get_cub_optimized_params(
            self, optimize_config, in_args, out_args, in_shape, out_shape,
            type_map, map_expr, reduce_expr, post_map_expr, reduce_type,
            stream, full_reduction, out_block_num, contiguous_size, params):
        out_size = internal.prod(out_shape)
        in_args = [_optimizer_copy_arg(a) for a in in_args]
        out_args = [_optimizer_copy_arg(a) for a in out_args]

        items_per_thread, block_size = _get_cub_block_specs(contiguous_size)
        default_block_size_log = math.floor(math.log2(block_size))
        default_items_per_thread = items_per_thread

        def target_func(block_size, items_per_thread):
            block_stride = block_size * items_per_thread
            cub_params = (
                True, items_per_thread, contiguous_size, full_reduction)
            self._launch(
                out_block_num, block_size, block_stride, in_args, out_args,
                in_shape, out_shape, type_map, map_expr, reduce_expr,
                post_map_expr, reduce_type, stream, params, cub_params)

        def suggest_func(trial):
            block_size_log = trial.suggest_int('block_size_log', 5, 9)
            block_size = 2 ** block_size_log
            items_per_thread = trial.suggest_int(
                'items_per_thread', 2, 32, step=2)

            trial.set_user_attr('block_size', block_size)
            return block_size, items_per_thread

        optimize_impl = optimize_config.optimize_impl
        best = optimize_impl(
            optimize_config, target_func, suggest_func,
            default_best={
                'block_size_log': default_block_size_log,
                'items_per_thread': default_items_per_thread,
            })

        return best.params['items_per_thread'], best.user_attrs['block_size']

    cdef inline void _launch(
            self, out_block_num, block_size, block_stride,
            in_args, out_args, in_shape, out_shape, type_map,
            map_expr, reduce_expr, post_map_expr, reduce_type,
            stream, params, cub_params):
        cdef bint full_reduction, use_cub = cub_params[0]
        cdef Py_ssize_t contiguous_size, items_per_thread
        cdef function.Function func

        # Kernel arguments passed to the __global__ function.
        if use_cub:
            items_per_thread = cub_params[1]
            contiguous_size = cub_params[2]
            full_reduction = cub_params[3]
            if full_reduction:
                _cub_two_pass_launch(
                    self.name, block_size, contiguous_size, items_per_thread,
                    reduce_type, params, in_args, out_args, self.identity,
                    map_expr, reduce_expr, post_map_expr,
                    type_map, self._input_expr, self._output_expr,
                    self._preamble, (), stream)
                return
            else:
                inout_args = (
                    in_args + out_args +
                    [_cub_convert_to_c_scalar(contiguous_size,
                                              contiguous_size),
                     _cub_convert_to_c_scalar(contiguous_size, 0)])
        else:
            inout_args = (
                in_args
                + out_args
                + [
                    _carray._indexer_init(in_shape),
                    _carray._indexer_init(out_shape),
                    # block_stride is passed as the last argument.
                    _scalar.CScalar.from_int32(block_stride),
                ])

        # Retrieve the kernel function
        func = self._get_function(
            params,
            _get_arginfos(inout_args),
            type_map,
            map_expr, reduce_expr, post_map_expr, reduce_type,
            block_size, cub_params)

        # Launch the kernel
        func.linear_launch(
            out_block_num * block_size, inout_args, 0, block_size, stream)

    cdef tuple _get_expressions_and_types(
            self, list in_args, list out_args, dtype):
        raise NotImplementedError()

    cdef list _get_out_args(
            self, list out_args, tuple out_types, const shape_t& out_shape):
        raise NotImplementedError()

    cdef function.Function _get_function(
            self,
            tuple params, tuple arginfos, _kernel._TypeMap type_map,
            str map_expr, str reduce_expr, str post_map_expr, str reduce_type,
            Py_ssize_t block_size, tuple cub_params=(False,)):
        raise NotImplementedError()


# -----------------------------------------------------------------------------
# create_reduction_func
# -----------------------------------------------------------------------------

cpdef _SimpleReductionKernel create_reduction_func(
        name, ops, routine=None, identity=None, preamble=''):
    ops = _kernel._Ops.from_tuples(ops, routine)
    return _SimpleReductionKernel(name, ops, identity, preamble)


cdef class _SimpleReductionKernel(_AbstractReductionKernel):

    cdef:
        readonly _kernel._Ops _ops
        readonly _preamble
        readonly int nin
        readonly int nout
        readonly str _input_expr
        readonly str _output_expr
        readonly dict _routine_cache

    def __init__(self, name, _kernel._Ops ops, identity, preamble):
        super().__init__(
            name,
            '' if identity is None else str(identity),
            'T in0',
            'T out0',
        )
        self._ops = ops
        self._preamble = preamble
        self.nin = 1
        self.nout = 1
        self._input_expr = 'const type_in0_raw in0 = _raw_in0[_in_ind.get()];'
        self._output_expr = 'type_out0_raw &out0 = _raw_out0[_out_ind.get()];'
        self._routine_cache = {}

    def __call__(self, object a, axis=None, dtype=None, ndarray out=None,
                 bint keepdims=False):

        cdef ndarray arr

        if isinstance(a, ndarray):
            arr = a
        elif hasattr(a, '__cuda_array_interface__'):
            arr = _convert_object_with_cuda_array_interface(a)
        else:
            raise TypeError(
                'Argument \'a\' has incorrect type (expected %s, got %s)' %
                (ndarray, type(a)))
        in_args = [arr]

        dev_id = device.get_device_id()
        _check_array_device_id(arr, dev_id)

        if out is None:
            out_args = []
        else:
            _check_array_device_id(out, dev_id)
            out_args = [out]

        reduce_dims = True
        return self._call(
            in_args, out_args,
            arr._shape, axis, dtype, keepdims, reduce_dims, dev_id, None, True)

    cdef tuple _get_expressions_and_types(
            self, list in_args, list out_args, dtype):
        cdef _kernel._Op op

        op = self._ops.guess_routine(
            self.name, self._routine_cache, in_args, dtype, self._ops)
        map_expr, reduce_expr, post_map_expr, reduce_type = op.routine

        if reduce_type is None:
            reduce_type = _get_typename(op.out_types[0])

        if out_args:
            out_type = out_args[0].dtype.type
        else:
            out_type = op.out_types[0]

        type_map = _kernel._TypeMap((
            ('type_in0_raw', in_args[0].dtype.type),
            ('type_out0_raw', out_type),
        ))

        return (
            map_expr, reduce_expr, post_map_expr,
            op.in_types, op.out_types, reduce_type,
            type_map)

    cdef list _get_out_args(
            self, list out_args, tuple out_types, const shape_t& out_shape):
        return _get_out_args(
            out_args, out_types, out_shape, 'unsafe')

    cdef function.Function _get_function(
            self,
            tuple params, tuple arginfos, _kernel._TypeMap type_map,
            str map_expr, str reduce_expr, str post_map_expr, str reduce_type,
            Py_ssize_t block_size, tuple cub_params=(False,)):
        return _SimpleReductionKernel_get_cached_function(
            map_expr, reduce_expr, post_map_expr, reduce_type,
            params, arginfos, type_map,
            self.name, block_size, self.identity,
            self._input_expr, self._output_expr, self._preamble,
            (), cub_params)


@util.memoize(for_each_device=True)
def _SimpleReductionKernel_get_cached_function(
        map_expr, reduce_expr, post_map_expr, reduce_type,
        params, arginfos, _kernel._TypeMap type_map,
        name, block_size, identity, input_expr, output_expr, _preamble,
        options, cub_params):
    use_cub = cub_params[0]
    if not use_cub:
        return _create_reduction_function(
            name, block_size, reduce_type, params, arginfos, identity,
            map_expr, reduce_expr, post_map_expr,
            type_map, input_expr, output_expr, _preamble, options)
    else:
        items_per_thread = cub_params[1]
        name = name.replace('cupy_', 'cupy_cub_')
        name = name.replace('cupyx_', 'cupyx_cub_')
        return _create_cub_reduction_function(
            name, block_size, items_per_thread,
            reduce_type, params, arginfos, identity,
            map_expr, reduce_expr, post_map_expr,
            type_map, _preamble, options)


# -----------------------------------------------------------------------------
# ReductionKernel
# -----------------------------------------------------------------------------


cdef class ReductionKernel(_AbstractReductionKernel):

    """User-defined reduction kernel.

    This class can be used to define a reduction kernel with or without
    broadcasting.

    The kernel is compiled at an invocation of the
    :meth:`~ReductionKernel.__call__` method, which is cached for each device.
    The compiled binary is also cached into a file under the
    ``$HOME/.cupy/kernel_cache/`` directory with a hashed file name. The cached
    binary is reused by other processes.

    Args:
        in_params (str): Input argument list.
        out_params (str): Output argument list.
        map_expr (str): Mapping expression for input values.
        reduce_expr (str): Reduction expression.
        post_map_expr (str): Mapping expression for reduced values.
        identity (str): Identity value for starting the reduction.
        name (str): Name of the kernel function. It should be set for
            readability of the performance profiling.
        reduce_type (str): Type of values to be used for reduction. This type
            is used to store the special variables ``a``.
        reduce_dims (bool): If ``True``, input arrays are reshaped without copy
            to smaller dimensions for efficiency.
        preamble (str): Fragment of the CUDA-C/C++ code that is inserted at the
            top of the cu file.
        options (tuple of str): Additional compilation options.

    """

    def __init__(self, str in_params, str out_params,
                 map_expr, reduce_expr, post_map_expr,
                 identity, name='reduce_kernel', reduce_type=None,
                 reduce_dims=True, preamble='', options=()):
        if not compiler.is_valid_kernel_name(name):
            raise ValueError(
                'Invalid kernel name: "%s"' % name)

        super().__init__(
            name,
            '' if identity is None else str(identity),
            in_params,
            out_params,
        )
        self.nin = len(self.in_params)
        self.nout = len(self.out_params)
        self.nargs = self.nin + self.nout
        self.reduce_expr = reduce_expr
        self.map_expr = map_expr
        self.post_map_expr = post_map_expr
        self.options = options
        self.reduce_dims = reduce_dims
        if reduce_type is None:
            self.reduce_type = self.out_params[0].ctype
        else:
            self.reduce_type = reduce_type
        self.preamble = preamble

    def __call__(self, *args, **kwargs):
        """Compiles and invokes the reduction kernel.

        The compilation runs only if the kernel is not cached. Note that the
        kernels with different argument dtypes, ndims, or axis are not
        compatible. It means that single ReductionKernel object may be compiled
        into multiple kernel binaries.

        Args:
            args: Arguments of the kernel.
            axis (int or tuple of ints): Axis or axes along which the
                reduction is performed.
            keepdims (bool): If ``True``, the specified axes are remained as
                axes of length one.

        Returns:
            Arrays are returned according to the ``out_params`` argument of the
            ``__init__`` method.

        """
        cdef shape_t broad_shape

        out = kwargs.pop('out', None)
        axis = kwargs.pop('axis', None)
        keepdims = kwargs.pop('keepdims', False)
        stream = kwargs.pop('stream', None)
        if kwargs:
            raise TypeError('Wrong arguments %s' % kwargs)

        n_args = len(args)
        if n_args != self.nin and n_args != self.nargs:
            raise TypeError('Wrong number of arguments for %s' % self.name)

        out_args = list(args[self.nin:])
        if out is not None:
            if self.nout != 1:
                raise NotImplementedError('')
            if len(out_args) != 0:
                raise ValueError("cannot specify 'out' as both "
                                 "a positional and keyword argument")
            out_args = [out]

        dev_id = device.get_device_id()
        in_args = _preprocess_args(dev_id, args[:self.nin], False)
        out_args = _preprocess_args(dev_id, out_args, False)
        in_args = _broadcast(in_args, self.in_params, False, broad_shape)

        return self._call(
            in_args, out_args,
            broad_shape, axis, None,
            keepdims, self.reduce_dims, dev_id, stream, False)

    cdef tuple _get_expressions_and_types(
            self, list in_args, list out_args, dtype):

        in_ndarray_types = tuple(
            [a.dtype.type if isinstance(a, ndarray) else None
             for a in in_args])
        out_ndarray_types = tuple(
            [a.dtype.type if isinstance(a, ndarray) else None
             for a in out_args])
        in_types, out_types, type_map = _decide_params_type(
            self.in_params, self.out_params,
            in_ndarray_types, out_ndarray_types)
        return (
            self.map_expr, self.reduce_expr, self.post_map_expr,
            in_types, out_types, self.reduce_type,
            type_map)

    cdef list _get_out_args(
            self, list out_args, tuple out_types, const shape_t& out_shape):
        return _get_out_args_with_params(
            out_args, out_types, out_shape, self.out_params, False)

    cdef function.Function _get_function(
            self,
            tuple params, tuple arginfos, _kernel._TypeMap type_map,
            str map_expr, str reduce_expr, str post_map_expr, str reduce_type,
            Py_ssize_t block_size, tuple cub_params=(False,)):
        return _ReductionKernel_get_cached_function(
            self.nin, self.nout, params, arginfos, type_map,
            self.name, block_size, reduce_type, self.identity,
            map_expr, reduce_expr, post_map_expr,
            self.preamble, self.options)


@util.memoize(for_each_device=True)
def _ReductionKernel_get_cached_function(
        nin, nout, params, arginfos, _kernel._TypeMap type_map,
        name, block_size, reduce_type, identity, map_expr, reduce_expr,
        post_map_expr, preamble, options):
    cdef ParameterInfo p
    cdef _ArgInfo arginfo
    in_arrays = [
        p for p, arginfo in zip(params[:nin], arginfos[:nin])
        if not p.raw and arginfo.is_ndarray()]
    out_arrays = [
        p for p, arginfo in zip(params[nin:nin+nout], arginfos[nin:nin+nout])
        if not p.raw and arginfo.is_ndarray()]
    input_expr = '\n'.join(
        [(('const {0} {1}' if p.is_const else '{0}& {1}') +
          ' = _raw_{1}[_in_ind.get()];').format(p.ctype, p.name)
         for p in in_arrays])
    output_expr = '\n'.join(
        ['{0} &{1} = _raw_{1}[_out_ind.get()];'.format(p.ctype, p.name)
         for p in out_arrays if not p.is_const])

    return _create_reduction_function(
        name, block_size, reduce_type, params, arginfos, identity,
        map_expr, reduce_expr, post_map_expr,
        type_map, input_expr, output_expr, preamble, options)
