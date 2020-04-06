/* Generated by Cython 0.29.15 */

#ifndef __PYX_HAVE__cudf___libxx__gpuarrow
#define __PYX_HAVE__cudf___libxx__gpuarrow

#include "Python.h"

#ifndef __PYX_HAVE_API__cudf___libxx__gpuarrow

#ifndef __PYX_EXTERN_C
  #ifdef __cplusplus
    #define __PYX_EXTERN_C extern "C"
  #else
    #define __PYX_EXTERN_C extern
  #endif
#endif

#ifndef DL_IMPORT
  #define DL_IMPORT(_T) _T
#endif

__PYX_EXTERN_C int pyarrow_is_cudabuffer(PyObject *);

#endif /* !__PYX_HAVE_API__cudf___libxx__gpuarrow */

/* WARNING: the interface of the module init function changed in CPython 3.5. */
/* It now returns a PyModuleDef instance instead of a PyModule instance. */

#if PY_MAJOR_VERSION < 3
PyMODINIT_FUNC initgpuarrow(void);
#else
PyMODINIT_FUNC PyInit_gpuarrow(void);
#endif

#endif /* !__PYX_HAVE__cudf___libxx__gpuarrow */
