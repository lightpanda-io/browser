/*
 * QuickJS Javascript Engine
 *
 * Copyright (c) 2017-2026 Fabrice Bellard
 * Copyright (c) 2017-2024 Charlie Gordon
 * Copyright (c) 2023-2026 Ben Noordhuis
 * Copyright (c) 2023-2026 Saúl Ibarra Corretgé
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
#ifndef QUICKJS_H
#define QUICKJS_H

#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

#define QUICKJS_NG 1

/* Helpers. */
#if defined(_WIN32) || defined(__CYGWIN__)
# define QUICKJS_NG_PLAT_WIN32 1
#endif /* defined(_WIN32) || defined(__CYGWIN__) */

#if defined(__GNUC__) || defined(__clang__)
# define QUICKJS_NG_CC_GNULIKE 1
#endif /* defined(__GNUC__) || defined(__clang__) */

/*
 * `JS_EXTERN` -- helper macro that must be used to mark the external
 * interfaces of libqjs.
 *
 * Define BUILDING_QJS_SHARED when building and USING_QJS_SHARED when using
 * shared libqjs.
 *
 * Windows note: The `__declspec` syntax is supported by both Clang and GCC.
 * If building qjs, the BUILDING_QJS_SHARED macro must be defined for libqjs
 * (and only for it) to properly export symbols.
 */
#ifdef QUICKJS_NG_PLAT_WIN32
# if defined(BUILDING_QJS_SHARED)
#  define JS_EXTERN __declspec(dllexport)
# elif defined(USING_QJS_SHARED)
#  define JS_EXTERN __declspec(dllimport)
# else
#  define JS_EXTERN /* nothing */
# endif
#else
# ifdef QUICKJS_NG_CC_GNULIKE
#  define JS_EXTERN __attribute__((visibility("default")))
# else
#  define JS_EXTERN /* nothing */
# endif
#endif /* QUICKJS_NG_PLAT_WIN32 */

/*
 * `JS_LIBC_EXTERN` -- helper macro that must be used to mark the extern
 * interfaces of quickjs-libc specifically.
 */
#if defined(QUICKJS_NG_BUILD) && !defined(QJS_BUILD_LIBC) && defined(QUICKJS_NG_PLAT_WIN32)
/*
 * We are building QuickJS-NG, quickjs-libc is a static library and we are on
 * Windows. Then, make sure to not export any interfaces.
 */
# define JS_LIBC_EXTERN /* nothing */
#else
/*
 * Otherwise, if we are either (1) not building QuickJS-NG, (2) libc is built as
 * a part of libqjs, or (3) we are not on Windows, define JS_LIBC_EXTERN to
 * JS_EXTERN.
 */
# define JS_LIBC_EXTERN JS_EXTERN
#endif

/*
 * `JS_MODULE_EXTERN` -- helper macro that must be used to mark `js_init_module`
 * and other public functions of the binary modules. See examples/ for examples
 * of the usage.
 *
 * Windows note: -DQUICKJS_NG_MODULE_BUILD must be set when building a binary
 * module to properly set __declspec.
 */
#ifdef QUICKJS_NG_PLAT_WIN32
# ifdef QUICKJS_NG_MODULE_BUILD
#  define JS_MODULE_EXTERN __declspec(dllexport)
# else
#  define JS_MODULE_EXTERN __declspec(dllimport)
# endif
#else
# ifdef QUICKJS_NG_CC_GNULIKE
#  define JS_MODULE_EXTERN __attribute__((visibility("default")))
# else
#  define JS_MODULE_EXTERN /* nothing */
# endif
#endif /* QUICKJS_NG_PLAT_WIN32 */

/* Borrowed from Folly */
#ifndef JS_PRINTF_FORMAT
/* Clang on Windows doesn't seem to support _Printf_format_string_ */
#if defined(_MSC_VER) && !defined(__clang__)
#include <sal.h>
#define JS_PRINTF_FORMAT _Printf_format_string_
#define JS_PRINTF_FORMAT_ATTR(format_param, dots_param)
#else
#define JS_PRINTF_FORMAT
#if !defined(__clang__) && defined(__GNUC__)
#define JS_PRINTF_FORMAT_ATTR(format_param, dots_param) \
  __attribute__((format(gnu_printf, format_param, dots_param)))
#else
#define JS_PRINTF_FORMAT_ATTR(format_param, dots_param) \
  __attribute__((format(printf, format_param, dots_param)))
#endif
#endif
#endif

#undef QUICKJS_NG_CC_GNULIKE
#undef QUICKJS_NG_PLAT_WIN32

typedef struct JSRuntime JSRuntime;
typedef struct JSContext JSContext;
typedef struct JSObject JSObject;
typedef struct JSClass JSClass;
typedef uint32_t JSClassID;
typedef uint32_t JSAtom;

/* Unless documented otherwise, C string pointers (`char *` or `const char *`)
   are assumed to verify these constraints:
   - unless a length is passed separately, the string has a null terminator
   - string contents is either pure ASCII or is UTF-8 encoded.
 */

/* Overridable purely for testing purposes; don't touch. */
#ifndef JS_NAN_BOXING
#if INTPTR_MAX < INT64_MAX
#define JS_NAN_BOXING 1 /* Use NAN boxing for 32bit builds. */
#endif
#endif

enum {
    /* all tags with a reference count are negative */
    JS_TAG_FIRST       = -9, /* first negative tag */
    JS_TAG_BIG_INT     = -9,
    JS_TAG_SYMBOL      = -8,
    JS_TAG_STRING      = -7,
    JS_TAG_STRING_ROPE = -6,
    JS_TAG_MODULE      = -3, /* used internally */
    JS_TAG_FUNCTION_BYTECODE = -2, /* used internally */
    JS_TAG_OBJECT      = -1,

    JS_TAG_INT         = 0,
    JS_TAG_BOOL        = 1,
    JS_TAG_NULL        = 2,
    JS_TAG_UNDEFINED   = 3,
    JS_TAG_UNINITIALIZED = 4,
    JS_TAG_CATCH_OFFSET = 5,
    JS_TAG_EXCEPTION   = 6,
    JS_TAG_SHORT_BIG_INT = 7,
    JS_TAG_FLOAT64     = 8,
    /* any larger tag is FLOAT64 if JS_NAN_BOXING */
};

#if !defined(JS_CHECK_JSVALUE)
#define JSValueConst JSValue
#endif

// JS_CHECK_JSVALUE build mode does not produce working code but is here to
// help catch reference counting bugs at compile time, by making it harder
// to mix up JSValue and JSValueConst
//
// rules:
//
// - a function with a JSValue parameter takes ownership;
//   caller must *not* call JS_FreeValue
//
// - a function with a JSValueConst parameter does not take ownership;
//   caller *must* call JS_FreeValue
//
// - a function returning a JSValue transfers ownership to caller;
//   caller *must* call JS_FreeValue
//
// - a function returning a JSValueConst does *not* transfer ownership;
//   caller must *not* call JS_FreeValue
#if defined(JS_CHECK_JSVALUE)

typedef struct JSValue *JSValue;
typedef const struct JSValue *JSValueConst;

#define JS_MKVAL(tag, val)       ((JSValue)((tag) | (intptr_t)(val) << 4))
#define JS_MKPTR(tag, ptr)       ((JSValue)((tag) | (intptr_t)(ptr)))
#define JS_VALUE_GET_NORM_TAG(v) ((int)((intptr_t)(v) & 15))
#define JS_VALUE_GET_TAG(v)      ((int)((intptr_t)(v) & 15))
#define JS_VALUE_GET_SHORT_BIG_INT(v) JS_VALUE_GET_INT(v)
#define JS_VALUE_GET_PTR(v)      ((void *)((intptr_t)(v) & ~15))
#define JS_VALUE_GET_INT(v)      ((int)((intptr_t)(v) >> 4))
#define JS_VALUE_GET_BOOL(v)     ((int)((intptr_t)(v) >> 4))
#define JS_VALUE_GET_FLOAT64(v)  ((double)((intptr_t)(v) >> 4))
#define JS_TAG_IS_FLOAT64(tag)   ((int)(tag) == JS_TAG_FLOAT64)
#define JS_NAN                   JS_MKVAL(JS_TAG_FLOAT64, 0)

static inline JSValue __JS_NewFloat64(double d)
{
    return JS_MKVAL(JS_TAG_FLOAT64, (int)d);
}

static inline bool JS_VALUE_IS_NAN(JSValue v)
{
    (void)&v;
    return false;
}

#elif defined(JS_NAN_BOXING) && JS_NAN_BOXING

typedef uint64_t JSValue;

#define JS_VALUE_GET_TAG(v) (int)((v) >> 32)
#define JS_VALUE_GET_INT(v) (int)(v)
#define JS_VALUE_GET_BOOL(v) (int)(v)
#define JS_VALUE_GET_SHORT_BIG_INT(v) (int)(v)
#define JS_VALUE_GET_PTR(v) (void *)(intptr_t)(v)

#define JS_MKVAL(tag, val) (((uint64_t)(tag) << 32) | (uint32_t)(val))
#define JS_MKPTR(tag, ptr) (((uint64_t)(tag) << 32) | (uintptr_t)(ptr))

#define JS_FLOAT64_TAG_ADDEND (0x7ff80000 - JS_TAG_FIRST + 1) /* quiet NaN encoding */

static inline double JS_VALUE_GET_FLOAT64(JSValue v)
{
    union {
        JSValue v;
        double d;
    } u;
    u.v = v;
    u.v += (uint64_t)JS_FLOAT64_TAG_ADDEND << 32;
    return u.d;
}

#define JS_NAN (0x7ff8000000000000 - ((uint64_t)JS_FLOAT64_TAG_ADDEND << 32))

static inline JSValue __JS_NewFloat64(double d)
{
    union {
        double d;
        uint64_t u64;
    } u;
    JSValue v;
    u.d = d;
    /* normalize NaN */
    if ((u.u64 & 0x7fffffffffffffff) > 0x7ff0000000000000)
        v = JS_NAN;
    else
        v = u.u64 - ((uint64_t)JS_FLOAT64_TAG_ADDEND << 32);
    return v;
}

#define JS_TAG_IS_FLOAT64(tag) ((unsigned)((tag) - JS_TAG_FIRST) >= (JS_TAG_FLOAT64 - JS_TAG_FIRST))

/* same as JS_VALUE_GET_TAG, but return JS_TAG_FLOAT64 with NaN boxing */
static inline int JS_VALUE_GET_NORM_TAG(JSValue v)
{
    uint32_t tag;
    tag = JS_VALUE_GET_TAG(v);
    if (JS_TAG_IS_FLOAT64(tag))
        return JS_TAG_FLOAT64;
    else
        return tag;
}

static inline bool JS_VALUE_IS_NAN(JSValue v)
{
    uint32_t tag;
    tag = JS_VALUE_GET_TAG(v);
    return tag == (JS_NAN >> 32);
}

#else /* !JS_NAN_BOXING */

typedef union JSValueUnion {
    int32_t int32;
    double float64;
    void *ptr;
    int32_t short_big_int;
} JSValueUnion;

typedef struct JSValue {
    JSValueUnion u;
    int64_t tag;
} JSValue;

#define JS_VALUE_GET_TAG(v) ((int32_t)(v).tag)
/* same as JS_VALUE_GET_TAG, but return JS_TAG_FLOAT64 with NaN boxing */
#define JS_VALUE_GET_NORM_TAG(v) JS_VALUE_GET_TAG(v)
#define JS_VALUE_GET_INT(v) ((v).u.int32)
#define JS_VALUE_GET_BOOL(v) ((v).u.int32)
#define JS_VALUE_GET_FLOAT64(v) ((v).u.float64)
#define JS_VALUE_GET_SHORT_BIG_INT(v) ((v).u.short_big_int)
#define JS_VALUE_GET_PTR(v) ((v).u.ptr)

/* msvc doesn't understand designated initializers without /std:c++20 */
#ifdef __cplusplus
static inline JSValue JS_MKPTR(int64_t tag, void *ptr)
{
    JSValue v;
    v.u.ptr = ptr;
    v.tag = tag;
    return v;
}
static inline JSValue JS_MKVAL(int64_t tag, int32_t int32)
{
    JSValue v;
    v.u.int32 = int32;
    v.tag = tag;
    return v;
}
static inline JSValue JS_MKNAN(void)
{
    JSValue v;
    v.u.float64 = NAN;
    v.tag = JS_TAG_FLOAT64;
    return v;
}
/* provide as macros for consistency and backward compat reasons */
#define JS_MKPTR(tag, ptr) JS_MKPTR(tag, ptr)
#define JS_MKVAL(tag, val) JS_MKVAL(tag, val)
#define JS_NAN             JS_MKNAN() /* alas, not a constant expression */
#else
#define JS_MKPTR(tag, p)   (JSValue){ (JSValueUnion){ .ptr = p }, tag }
#define JS_MKVAL(tag, val) (JSValue){ (JSValueUnion){ .int32 = val }, tag }
#define JS_NAN             (JSValue){ (JSValueUnion){ .float64 = NAN }, JS_TAG_FLOAT64 }
#endif

#define JS_TAG_IS_FLOAT64(tag) ((unsigned)(tag) == JS_TAG_FLOAT64)

static inline JSValue __JS_NewFloat64(double d)
{
    JSValue v;
    v.tag = JS_TAG_FLOAT64;
    v.u.float64 = d;
    return v;
}

static inline bool JS_VALUE_IS_NAN(JSValue v)
{
    union {
        double d;
        uint64_t u64;
    } u;
    if (v.tag != JS_TAG_FLOAT64)
        return 0;
    u.d = v.u.float64;
    return (u.u64 & 0x7fffffffffffffff) > 0x7ff0000000000000;
}

#endif /* !JS_NAN_BOXING */

#define JS_VALUE_IS_BOTH_INT(v1, v2) ((JS_VALUE_GET_TAG(v1) | JS_VALUE_GET_TAG(v2)) == 0)
#define JS_VALUE_IS_BOTH_FLOAT(v1, v2) (JS_TAG_IS_FLOAT64(JS_VALUE_GET_TAG(v1)) && JS_TAG_IS_FLOAT64(JS_VALUE_GET_TAG(v2)))

#define JS_VALUE_HAS_REF_COUNT(v) ((unsigned)JS_VALUE_GET_TAG(v) >= (unsigned)JS_TAG_FIRST)

/* special values */
#define JS_NULL      JS_MKVAL(JS_TAG_NULL, 0)
#define JS_UNDEFINED JS_MKVAL(JS_TAG_UNDEFINED, 0)
#define JS_FALSE     JS_MKVAL(JS_TAG_BOOL, 0)
#define JS_TRUE      JS_MKVAL(JS_TAG_BOOL, 1)
#define JS_EXCEPTION JS_MKVAL(JS_TAG_EXCEPTION, 0)
#define JS_UNINITIALIZED JS_MKVAL(JS_TAG_UNINITIALIZED, 0)

/* flags for object properties */
#define JS_PROP_CONFIGURABLE  (1 << 0)
#define JS_PROP_WRITABLE      (1 << 1)
#define JS_PROP_ENUMERABLE    (1 << 2)
#define JS_PROP_C_W_E         (JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE | JS_PROP_ENUMERABLE)
#define JS_PROP_LENGTH        (1 << 3) /* used internally in Arrays */
#define JS_PROP_TMASK         (3 << 4) /* mask for NORMAL, GETSET, VARREF, AUTOINIT */
#define JS_PROP_NORMAL         (0 << 4)
#define JS_PROP_GETSET         (1 << 4)
#define JS_PROP_VARREF         (2 << 4) /* used internally */
#define JS_PROP_AUTOINIT       (3 << 4) /* used internally */

/* flags for JS_DefineProperty */
#define JS_PROP_HAS_SHIFT        8
#define JS_PROP_HAS_CONFIGURABLE (1 << 8)
#define JS_PROP_HAS_WRITABLE     (1 << 9)
#define JS_PROP_HAS_ENUMERABLE   (1 << 10)
#define JS_PROP_HAS_GET          (1 << 11)
#define JS_PROP_HAS_SET          (1 << 12)
#define JS_PROP_HAS_VALUE        (1 << 13)

/* throw an exception if false would be returned
   (JS_DefineProperty/JS_SetProperty) */
#define JS_PROP_THROW            (1 << 14)
/* throw an exception if false would be returned in strict mode
   (JS_SetProperty) */
#define JS_PROP_THROW_STRICT     (1 << 15)

#define JS_PROP_NO_ADD           (1 << 16) /* internal use */
#define JS_PROP_NO_EXOTIC        (1 << 17) /* internal use */
#define JS_PROP_DEFINE_PROPERTY  (1 << 18) /* internal use */
#define JS_PROP_REFLECT_DEFINE_PROPERTY (1 << 19) /* internal use */

#ifndef JS_DEFAULT_STACK_SIZE
#define JS_DEFAULT_STACK_SIZE (1024 * 1024)
#endif

/* JS_Eval() flags */
#define JS_EVAL_TYPE_GLOBAL   (0 << 0) /* global code (default) */
#define JS_EVAL_TYPE_MODULE   (1 << 0) /* module code */
#define JS_EVAL_TYPE_DIRECT   (2 << 0) /* direct call (internal use) */
#define JS_EVAL_TYPE_INDIRECT (3 << 0) /* indirect call (internal use) */
#define JS_EVAL_TYPE_MASK     (3 << 0)

#define JS_EVAL_FLAG_STRICT   (1 << 3) /* force 'strict' mode */
#define JS_EVAL_FLAG_UNUSED   (1 << 4) /* unused */
/* compile but do not run. The result is an object with a
   JS_TAG_FUNCTION_BYTECODE or JS_TAG_MODULE tag. It can be executed
   with JS_EvalFunction(). */
#define JS_EVAL_FLAG_COMPILE_ONLY (1 << 5)
/* don't include the stack frames before this eval in the Error() backtraces */
#define JS_EVAL_FLAG_BACKTRACE_BARRIER (1 << 6)
/* allow top-level await in normal script. JS_Eval() returns a
   promise. Only allowed with JS_EVAL_TYPE_GLOBAL */
#define JS_EVAL_FLAG_ASYNC (1 << 7)

typedef JSValue JSCFunction(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
typedef JSValue JSCFunctionMagic(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic);
typedef JSValue JSCFunctionData(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValueConst *func_data);
typedef JSValue JSCClosure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, void *opaque);

typedef struct JSMallocFunctions {
    void *(*js_calloc)(void *opaque, size_t count, size_t size);
    void *(*js_malloc)(void *opaque, size_t size);
    void (*js_free)(void *opaque, void *ptr);
    void *(*js_realloc)(void *opaque, void *ptr, size_t size);
    size_t (*js_malloc_usable_size)(const void *ptr);
} JSMallocFunctions;

// Debug trace system: the debug output will be produced to the dump stream (currently
// stdout) if dumps are enabled and JS_SetDumpFlags is invoked with the corresponding
// bit set.
#define JS_DUMP_BYTECODE_FINAL   0x01  /* dump pass 3 final byte code */
#define JS_DUMP_BYTECODE_PASS2   0x02  /* dump pass 2 code */
#define JS_DUMP_BYTECODE_PASS1   0x04  /* dump pass 1 code */
#define JS_DUMP_BYTECODE_HEX     0x10  /* dump bytecode in hex */
#define JS_DUMP_BYTECODE_PC2LINE 0x20  /* dump line number table */
#define JS_DUMP_BYTECODE_STACK   0x40  /* dump compute_stack_size */
#define JS_DUMP_BYTECODE_STEP    0x80  /* dump executed bytecode */
#define JS_DUMP_READ_OBJECT     0x100  /* dump the marshalled objects at load time */
#define JS_DUMP_FREE            0x200  /* dump every object free */
#define JS_DUMP_GC              0x400  /* dump the occurrence of the automatic GC */
#define JS_DUMP_GC_FREE         0x800  /* dump objects freed by the GC */
#define JS_DUMP_MODULE_RESOLVE 0x1000  /* dump module resolution steps */
#define JS_DUMP_PROMISE        0x2000  /* dump promise steps */
#define JS_DUMP_LEAKS          0x4000  /* dump leaked objects and strings in JS_FreeRuntime */
#define JS_DUMP_ATOM_LEAKS     0x8000  /* dump leaked atoms in JS_FreeRuntime */
#define JS_DUMP_MEM           0x10000  /* dump memory usage in JS_FreeRuntime */
#define JS_DUMP_OBJECTS       0x20000  /* dump objects in JS_FreeRuntime */
#define JS_DUMP_ATOMS         0x40000  /* dump atoms in JS_FreeRuntime */
#define JS_DUMP_SHAPES        0x80000  /* dump shapes in JS_FreeRuntime */
#define JS_ABORT_ON_LEAKS    0x10C000  /* abort on atom/object/string leaks; for testing */

// Finalizers run in LIFO order at the very end of JS_FreeRuntime.
// Intended for cleanup of associated resources; the runtime itself
// is no longer usable.
typedef void JSRuntimeFinalizer(JSRuntime *rt, void *arg);

typedef struct JSGCObjectHeader JSGCObjectHeader;

JS_EXTERN JSRuntime *JS_NewRuntime(void);
/* info lifetime must exceed that of rt */
JS_EXTERN void JS_SetRuntimeInfo(JSRuntime *rt, const char *info);
/* use 0 to disable memory limit */
JS_EXTERN void JS_SetMemoryLimit(JSRuntime *rt, size_t limit);
JS_EXTERN void JS_SetDumpFlags(JSRuntime *rt, uint64_t flags);
JS_EXTERN uint64_t JS_GetDumpFlags(JSRuntime *rt);
JS_EXTERN size_t JS_GetGCThreshold(JSRuntime *rt);
JS_EXTERN void JS_SetGCThreshold(JSRuntime *rt, size_t gc_threshold);
/* use 0 to disable maximum stack size check */
JS_EXTERN void JS_SetMaxStackSize(JSRuntime *rt, size_t stack_size);
/* should be called when changing thread to update the stack top value
   used to check stack overflow. */
JS_EXTERN void JS_UpdateStackTop(JSRuntime *rt);
JS_EXTERN JSRuntime *JS_NewRuntime2(const JSMallocFunctions *mf, void *opaque);
JS_EXTERN void JS_FreeRuntime(JSRuntime *rt);
JS_EXTERN void *JS_GetRuntimeOpaque(JSRuntime *rt);
JS_EXTERN void JS_SetRuntimeOpaque(JSRuntime *rt, void *opaque);
JS_EXTERN int JS_AddRuntimeFinalizer(JSRuntime *rt,
                                     JSRuntimeFinalizer *finalizer, void *arg);
typedef void JS_MarkFunc(JSRuntime *rt, JSGCObjectHeader *gp);
JS_EXTERN void JS_MarkValue(JSRuntime *rt, JSValueConst val,
                            JS_MarkFunc *mark_func);
JS_EXTERN void JS_RunGC(JSRuntime *rt);
JS_EXTERN bool JS_IsLiveObject(JSRuntime *rt, JSValueConst obj);

JS_EXTERN JSContext *JS_NewContext(JSRuntime *rt);
JS_EXTERN void JS_FreeContext(JSContext *s);
JS_EXTERN JSContext *JS_DupContext(JSContext *ctx);
JS_EXTERN void *JS_GetContextOpaque(JSContext *ctx);
JS_EXTERN void JS_SetContextOpaque(JSContext *ctx, void *opaque);
JS_EXTERN JSRuntime *JS_GetRuntime(JSContext *ctx);
JS_EXTERN void JS_SetClassProto(JSContext *ctx, JSClassID class_id, JSValue obj);
JS_EXTERN JSValue JS_GetClassProto(JSContext *ctx, JSClassID class_id);
JS_EXTERN JSValue JS_GetFunctionProto(JSContext *ctx);

/* the following functions are used to select the intrinsic object to
   save memory */
JS_EXTERN JSContext *JS_NewContextRaw(JSRuntime *rt);
JS_EXTERN int JS_AddIntrinsicBaseObjects(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicDate(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicEval(JSContext *ctx);
JS_EXTERN void JS_AddIntrinsicRegExpCompiler(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicRegExp(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicJSON(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicProxy(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicMapSet(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicTypedArrays(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicPromise(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicBigInt(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicWeakRef(JSContext *ctx);
JS_EXTERN int JS_AddPerformance(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicDOMException(JSContext *ctx);
JS_EXTERN int JS_AddIntrinsicAToB(JSContext *ctx);

/* for equality comparisons and sameness */
JS_EXTERN int JS_IsEqual(JSContext *ctx, JSValueConst op1, JSValueConst op2);
JS_EXTERN bool JS_IsStrictEqual(JSContext *ctx, JSValueConst op1, JSValueConst op2);
JS_EXTERN bool JS_IsSameValue(JSContext *ctx, JSValueConst op1, JSValueConst op2);
/* Similar to same-value equality, but +0 and -0 are considered equal. */
JS_EXTERN bool JS_IsSameValueZero(JSContext *ctx, JSValueConst op1, JSValueConst op2);

/* Only used for running 262 tests. TODO(saghul) add build time flag. */
JS_EXTERN JSValue js_string_codePointRange(JSContext *ctx, JSValueConst this_val,
                                           int argc, JSValueConst *argv);

JS_EXTERN void *js_calloc_rt(JSRuntime *rt, size_t count, size_t size);
JS_EXTERN void *js_malloc_rt(JSRuntime *rt, size_t size);
JS_EXTERN void js_free_rt(JSRuntime *rt, void *ptr);
JS_EXTERN void *js_realloc_rt(JSRuntime *rt, void *ptr, size_t size);
JS_EXTERN size_t js_malloc_usable_size_rt(JSRuntime *rt, const void *ptr);
JS_EXTERN void *js_mallocz_rt(JSRuntime *rt, size_t size);

JS_EXTERN void *js_calloc(JSContext *ctx, size_t count, size_t size);
JS_EXTERN void *js_malloc(JSContext *ctx, size_t size);
JS_EXTERN void js_free(JSContext *ctx, void *ptr);
JS_EXTERN void *js_realloc(JSContext *ctx, void *ptr, size_t size);
JS_EXTERN size_t js_malloc_usable_size(JSContext *ctx, const void *ptr);
JS_EXTERN void *js_realloc2(JSContext *ctx, void *ptr, size_t size, size_t *pslack);
JS_EXTERN void *js_mallocz(JSContext *ctx, size_t size);
JS_EXTERN char *js_strdup(JSContext *ctx, const char *str);
JS_EXTERN char *js_strndup(JSContext *ctx, const char *s, size_t n);

typedef struct JSMemoryUsage {
    int64_t malloc_size, malloc_limit, memory_used_size;
    int64_t malloc_count;
    int64_t memory_used_count;
    int64_t atom_count, atom_size;
    int64_t str_count, str_size;
    int64_t obj_count, obj_size;
    int64_t prop_count, prop_size;
    int64_t shape_count, shape_size;
    int64_t js_func_count, js_func_size, js_func_code_size;
    int64_t js_func_pc2line_count, js_func_pc2line_size;
    int64_t c_func_count, array_count;
    int64_t fast_array_count, fast_array_elements;
    int64_t binary_object_count, binary_object_size;
} JSMemoryUsage;

JS_EXTERN void JS_ComputeMemoryUsage(JSRuntime *rt, JSMemoryUsage *s);
JS_EXTERN void JS_DumpMemoryUsage(FILE *fp, const JSMemoryUsage *s, JSRuntime *rt);

/* atom support */
#define JS_ATOM_NULL 0

JS_EXTERN JSAtom JS_NewAtomLen(JSContext *ctx, const char *str, size_t len);
JS_EXTERN JSAtom JS_NewAtom(JSContext *ctx, const char *str);
JS_EXTERN JSAtom JS_NewAtomUInt32(JSContext *ctx, uint32_t n);
JS_EXTERN JSAtom JS_DupAtom(JSContext *ctx, JSAtom v);
JS_EXTERN JSAtom JS_DupAtomRT(JSRuntime *rt, JSAtom v);
JS_EXTERN void JS_FreeAtom(JSContext *ctx, JSAtom v);
JS_EXTERN void JS_FreeAtomRT(JSRuntime *rt, JSAtom v);
JS_EXTERN JSValue JS_AtomToValue(JSContext *ctx, JSAtom atom);
JS_EXTERN JSValue JS_AtomToString(JSContext *ctx, JSAtom atom);
JS_EXTERN const char *JS_AtomToCStringLen(JSContext *ctx, size_t *plen, JSAtom atom);
static inline const char *JS_AtomToCString(JSContext *ctx, JSAtom atom)
{
    return JS_AtomToCStringLen(ctx, NULL, atom);
}
JS_EXTERN JSAtom JS_ValueToAtom(JSContext *ctx, JSValueConst val);

/* object class support */

typedef struct JSPropertyEnum {
    bool is_enumerable;
    JSAtom atom;
} JSPropertyEnum;

typedef struct JSPropertyDescriptor {
    int flags;
    JSValue value;
    JSValue getter;
    JSValue setter;
} JSPropertyDescriptor;

typedef struct JSClassExoticMethods {
    /* Return -1 if exception (can only happen in case of Proxy object),
       false if the property does not exists, true if it exists. If 1 is
       returned, the property descriptor 'desc' is filled if != NULL. */
    int (*get_own_property)(JSContext *ctx, JSPropertyDescriptor *desc,
                             JSValueConst obj, JSAtom prop);
    /* '*ptab' should hold the '*plen' property keys. Return 0 if OK,
       -1 if exception. The 'is_enumerable' field is ignored.
    */
    int (*get_own_property_names)(JSContext *ctx, JSPropertyEnum **ptab,
                                  uint32_t *plen, JSValueConst obj);
    /* return < 0 if exception, or true/false */
    int (*delete_property)(JSContext *ctx, JSValueConst obj, JSAtom prop);
    /* return < 0 if exception or true/false */
    int (*define_own_property)(JSContext *ctx, JSValueConst this_obj,
                               JSAtom prop, JSValueConst val,
                               JSValueConst getter, JSValueConst setter,
                               int flags);
    /* The following methods can be emulated with the previous ones,
       so they are usually not needed */
    /* return < 0 if exception or true/false */
    int (*has_property)(JSContext *ctx, JSValueConst obj, JSAtom atom);
    JSValue (*get_property)(JSContext *ctx, JSValueConst obj, JSAtom atom,
                            JSValueConst receiver);
    /* return < 0 if exception or true/false */
    int (*set_property)(JSContext *ctx, JSValueConst obj, JSAtom atom,
                        JSValueConst value, JSValueConst receiver, int flags);
} JSClassExoticMethods;

typedef void JSClassFinalizer(JSRuntime *rt, JSValueConst val);
typedef void JSClassGCMark(JSRuntime *rt, JSValueConst val,
                           JS_MarkFunc *mark_func);
#define JS_CALL_FLAG_CONSTRUCTOR (1 << 0)
typedef JSValue JSClassCall(JSContext *ctx, JSValueConst func_obj,
                            JSValueConst this_val, int argc,
                            JSValueConst *argv, int flags);

typedef struct JSClassDef {
    const char *class_name; /* pure ASCII only! */
    JSClassFinalizer *finalizer;
    JSClassGCMark *gc_mark;
    /* if call != NULL, the object is a function. If (flags &
       JS_CALL_FLAG_CONSTRUCTOR) != 0, the function is called as a
       constructor. In this case, 'this_val' is new.target. A
       constructor call only happens if the object constructor bit is
       set (see JS_SetConstructorBit()). */
    JSClassCall *call;
    /* XXX: suppress this indirection ? It is here only to save memory
       because only a few classes need these methods */
    JSClassExoticMethods *exotic;
} JSClassDef;

#define JS_EVAL_OPTIONS_VERSION 1

typedef struct JSEvalOptions {
  int version;
  int eval_flags;
  const char *filename;
  int line_num;
  // can add new fields in ABI-compatible manner by incrementing JS_EVAL_OPTIONS_VERSION
} JSEvalOptions;

#define JS_INVALID_CLASS_ID 0
JS_EXTERN JSClassID JS_NewClassID(JSRuntime *rt, JSClassID *pclass_id);
/* Returns the class ID if `v` is an object, otherwise returns JS_INVALID_CLASS_ID. */
JS_EXTERN JSClassID JS_GetClassID(JSValueConst v);
JS_EXTERN int JS_NewClass(JSRuntime *rt, JSClassID class_id, const JSClassDef *class_def);
JS_EXTERN bool JS_IsRegisteredClass(JSRuntime *rt, JSClassID class_id);
/* Returns the class name or JS_ATOM_NULL if `id` is not a registered class. Must be freed with JS_FreeAtom. */
JS_EXTERN JSAtom JS_GetClassName(JSRuntime *rt, JSClassID class_id);

/* value handling */

static inline JSValue JS_NewBool(JSContext *ctx, bool val)
{
    (void)&ctx;
    return JS_MKVAL(JS_TAG_BOOL, (val != 0));
}

static inline JSValue JS_NewInt32(JSContext *ctx, int32_t val)
{
    (void)&ctx;
    return JS_MKVAL(JS_TAG_INT, val);
}

static inline JSValue JS_NewFloat64(JSContext *ctx, double val)
{
    (void)&ctx;
    return __JS_NewFloat64(val);
}

static inline JSValue JS_NewCatchOffset(JSContext *ctx, int32_t val)
{
    (void)&ctx;
    return JS_MKVAL(JS_TAG_CATCH_OFFSET, val);
}

static inline JSValue JS_NewInt64(JSContext *ctx, int64_t val)
{
    JSValue v;
    if (val >= INT32_MIN && val <= INT32_MAX) {
        v = JS_NewInt32(ctx, (int32_t)val);
    } else {
        v = JS_NewFloat64(ctx, (double)val);
    }
    return v;
}

static inline JSValue JS_NewUint32(JSContext *ctx, uint32_t val)
{
    JSValue v;
    if (val <= INT32_MAX) {
        v = JS_NewInt32(ctx, (int32_t)val);
    } else {
        v = JS_NewFloat64(ctx, (double)val);
    }
    return v;
}

static inline JSValue JS_NewUint64(JSContext *ctx, uint64_t val)
{
    JSValue v;
    if (val <= INT32_MAX) {
        v = JS_NewInt32(ctx, (int32_t)val);
    } else {
        v = JS_NewFloat64(ctx, (double)val);
    }
    return v;
}

JS_EXTERN JSValue JS_NewNumber(JSContext *ctx, double d);
JS_EXTERN JSValue JS_NewBigInt64(JSContext *ctx, int64_t v);
JS_EXTERN JSValue JS_NewBigUint64(JSContext *ctx, uint64_t v);

static inline bool JS_IsNumber(JSValueConst v)
{
    int tag = JS_VALUE_GET_TAG(v);
    return tag == JS_TAG_INT || JS_TAG_IS_FLOAT64(tag);
}

static inline bool JS_IsBigInt(JSValueConst v)
{
    int tag = JS_VALUE_GET_TAG(v);
    return tag == JS_TAG_BIG_INT || tag == JS_TAG_SHORT_BIG_INT;
}

static inline bool JS_IsBool(JSValueConst v)
{
    return JS_VALUE_GET_TAG(v) == JS_TAG_BOOL;
}

static inline bool JS_IsNull(JSValueConst v)
{
    return JS_VALUE_GET_TAG(v) == JS_TAG_NULL;
}

static inline bool JS_IsUndefined(JSValueConst v)
{
    return JS_VALUE_GET_TAG(v) == JS_TAG_UNDEFINED;
}

static inline bool JS_IsException(JSValueConst v)
{
    return JS_VALUE_GET_TAG(v) == JS_TAG_EXCEPTION;
}

static inline bool JS_IsUninitialized(JSValueConst v)
{
    return JS_VALUE_GET_TAG(v) == JS_TAG_UNINITIALIZED;
}

static inline bool JS_IsString(JSValueConst v)
{
    int tag = JS_VALUE_GET_TAG(v);
    return tag == JS_TAG_STRING || tag == JS_TAG_STRING_ROPE;
}

static inline bool JS_IsSymbol(JSValueConst v)
{
    return JS_VALUE_GET_TAG(v) == JS_TAG_SYMBOL;
}

static inline bool JS_IsObject(JSValueConst v)
{
    return JS_VALUE_GET_TAG(v) == JS_TAG_OBJECT;
}

static inline bool JS_IsModule(JSValueConst v)
{
    return JS_VALUE_GET_TAG(v) == JS_TAG_MODULE;
}

JS_EXTERN JSValue JS_Throw(JSContext *ctx, JSValue obj);
JS_EXTERN JSValue JS_GetException(JSContext *ctx);
JS_EXTERN bool JS_HasException(JSContext *ctx);
JS_EXTERN bool JS_IsError(JSValueConst val);
JS_EXTERN bool JS_IsUncatchableError(JSValueConst val);
JS_EXTERN void JS_SetUncatchableError(JSContext *ctx, JSValueConst val);
JS_EXTERN void JS_ClearUncatchableError(JSContext *ctx, JSValueConst val);
// Shorthand for:
//  JSValue exc = JS_GetException(ctx);
//  JS_ClearUncatchableError(ctx, exc);
//  JS_Throw(ctx, exc);
JS_EXTERN void JS_ResetUncatchableError(JSContext *ctx);
JS_EXTERN JSValue JS_NewError(JSContext *ctx);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_NewInternalError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_NewPlainError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_NewRangeError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_NewReferenceError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_NewSyntaxError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_NewTypeError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_ThrowInternalError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_ThrowPlainError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_ThrowRangeError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_ThrowReferenceError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_ThrowSyntaxError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(2, 3) JS_ThrowTypeError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_PRINTF_FORMAT_ATTR(3, 4) JS_ThrowDOMException(JSContext *ctx, const char *name, JS_PRINTF_FORMAT const char *fmt, ...);
JS_EXTERN JSValue JS_ThrowOutOfMemory(JSContext *ctx);
JS_EXTERN void JS_FreeValue(JSContext *ctx, JSValue v);
JS_EXTERN void JS_FreeValueRT(JSRuntime *rt, JSValue v);
JS_EXTERN JSValue JS_DupValue(JSContext *ctx, JSValueConst v);
JS_EXTERN JSValue JS_DupValueRT(JSRuntime *rt, JSValueConst v);
JS_EXTERN int JS_ToBool(JSContext *ctx, JSValueConst val); /* return -1 for JS_EXCEPTION */
static inline JSValue JS_ToBoolean(JSContext *ctx, JSValueConst val)
{
    return JS_NewBool(ctx, JS_ToBool(ctx, val));
}
JS_EXTERN JSValue JS_ToNumber(JSContext *ctx, JSValueConst val);
JS_EXTERN int JS_ToInt32(JSContext *ctx, int32_t *pres, JSValueConst val);
static inline int JS_ToUint32(JSContext *ctx, uint32_t *pres, JSValueConst val)
{
    return JS_ToInt32(ctx, (int32_t*)pres, val);
}
JS_EXTERN int JS_ToInt64(JSContext *ctx, int64_t *pres, JSValueConst val);
JS_EXTERN int JS_ToIndex(JSContext *ctx, uint64_t *plen, JSValueConst val);
JS_EXTERN int JS_ToFloat64(JSContext *ctx, double *pres, JSValueConst val);
/* return an exception if 'val' is a Number */
JS_EXTERN int JS_ToBigInt64(JSContext *ctx, int64_t *pres, JSValueConst val);
JS_EXTERN int JS_ToBigUint64(JSContext *ctx, uint64_t *pres, JSValueConst val);
/* same as JS_ToInt64() but allow BigInt */
JS_EXTERN int JS_ToInt64Ext(JSContext *ctx, int64_t *pres, JSValueConst val);

JS_EXTERN JSValue JS_NewStringLen(JSContext *ctx, const char *str1, size_t len1);
static inline JSValue JS_NewString(JSContext *ctx, const char *str) {
    return JS_NewStringLen(ctx, str, strlen(str));
}
// makes a copy of the input; does not check if the input is valid UTF-16,
// that is the responsibility of the caller
JS_EXTERN JSValue JS_NewStringUTF16(JSContext *ctx, const uint16_t *buf,
                                    size_t len);
JS_EXTERN JSValue JS_NewAtomString(JSContext *ctx, const char *str);
JS_EXTERN JSValue JS_ToString(JSContext *ctx, JSValueConst val);
JS_EXTERN JSValue JS_ToPropertyKey(JSContext *ctx, JSValueConst val);
JS_EXTERN const char *JS_ToCStringLen2(JSContext *ctx, size_t *plen, JSValueConst val1, bool cesu8);
static inline const char *JS_ToCStringLen(JSContext *ctx, size_t *plen, JSValueConst val1)
{
    return JS_ToCStringLen2(ctx, plen, val1, 0);
}
static inline const char *JS_ToCString(JSContext *ctx, JSValueConst val1)
{
    return JS_ToCStringLen2(ctx, NULL, val1, 0);
}
// returns a utf-16 version of the string in native endianness; the
// string is not nul terminated and can contain unmatched surrogates
// |*plen| is in uint16s, not code points; a surrogate pair such as
// U+D834 U+DF06 has len=2; an unmatched surrogate has len=1
JS_EXTERN const uint16_t *JS_ToCStringLenUTF16(JSContext *ctx, size_t *plen,
                                               JSValueConst val1);
static inline const uint16_t *JS_ToCStringUTF16(JSContext *ctx,
                                                JSValueConst val1)
{
    return JS_ToCStringLenUTF16(ctx, NULL, val1);
}
JS_EXTERN void JS_FreeCString(JSContext *ctx, const char *ptr);
JS_EXTERN void JS_FreeCStringRT(JSRuntime *rt, const char *ptr);
JS_EXTERN void JS_FreeCStringUTF16(JSContext *ctx, const uint16_t *ptr);
JS_EXTERN void JS_FreeCStringRT_UTF16(JSRuntime *rt, const uint16_t *ptr);

JS_EXTERN JSValue JS_NewObjectProtoClass(JSContext *ctx, JSValueConst proto,
                                         JSClassID class_id);
JS_EXTERN JSValue JS_NewObjectClass(JSContext *ctx, JSClassID class_id);
JS_EXTERN JSValue JS_NewObjectProto(JSContext *ctx, JSValueConst proto);
JS_EXTERN JSValue JS_NewObject(JSContext *ctx);
// takes ownership of the values
JS_EXTERN JSValue JS_NewObjectFrom(JSContext *ctx, int count,
                                   const JSAtom *props,
                                   const JSValue *values);
// takes ownership of the values
JS_EXTERN JSValue JS_NewObjectFromStr(JSContext *ctx, int count,
                                      const char **props,
                                      const JSValue *values);
JS_EXTERN JSValue JS_ToObject(JSContext *ctx, JSValueConst val);
JS_EXTERN JSValue JS_ToObjectString(JSContext *ctx, JSValueConst val);

JS_EXTERN bool JS_IsFunction(JSContext* ctx, JSValueConst val);
JS_EXTERN bool JS_IsAsyncFunction(JSValueConst val);
JS_EXTERN bool JS_IsConstructor(JSContext* ctx, JSValueConst val);
JS_EXTERN bool JS_SetConstructorBit(JSContext *ctx, JSValueConst func_obj, bool val);

JS_EXTERN bool JS_IsRegExp(JSValueConst val);
JS_EXTERN bool JS_IsMap(JSValueConst val);
JS_EXTERN bool JS_IsSet(JSValueConst val);
JS_EXTERN bool JS_IsWeakRef(JSValueConst val);
JS_EXTERN bool JS_IsWeakSet(JSValueConst val);
JS_EXTERN bool JS_IsWeakMap(JSValueConst val);
JS_EXTERN bool JS_IsDataView(JSValueConst val);

JS_EXTERN JSValue JS_NewArray(JSContext *ctx);
// takes ownership of the values
JS_EXTERN JSValue JS_NewArrayFrom(JSContext *ctx, int count,
                                  const JSValue *values);
// reader beware: JS_IsArray used to "punch" through proxies and check
// if the target object is an array but it no longer does; use JS_IsProxy
// and JS_GetProxyTarget instead, and remember that the target itself can
// also be a proxy, ad infinitum
JS_EXTERN bool JS_IsArray(JSValueConst val);

JS_EXTERN bool JS_IsProxy(JSValueConst val);
JS_EXTERN JSValue JS_GetProxyTarget(JSContext *ctx, JSValueConst proxy);
JS_EXTERN JSValue JS_GetProxyHandler(JSContext *ctx, JSValueConst proxy);
JS_EXTERN JSValue JS_NewProxy(JSContext *ctx, JSValueConst target,
                              JSValueConst handler);

JS_EXTERN JSValue JS_NewDate(JSContext *ctx, double epoch_ms);
JS_EXTERN bool JS_IsDate(JSValueConst v);

JS_EXTERN JSValue JS_GetProperty(JSContext *ctx, JSValueConst this_obj, JSAtom prop);
JS_EXTERN JSValue JS_GetPropertyUint32(JSContext *ctx, JSValueConst this_obj,
                                       uint32_t idx);
JS_EXTERN JSValue JS_GetPropertyInt64(JSContext *ctx, JSValueConst this_obj,
                                      int64_t idx);
JS_EXTERN JSValue JS_GetPropertyStr(JSContext *ctx, JSValueConst this_obj,
                                    const char *prop);

JS_EXTERN int JS_SetProperty(JSContext *ctx, JSValueConst this_obj,
                             JSAtom prop, JSValue val);
JS_EXTERN int JS_SetPropertyUint32(JSContext *ctx, JSValueConst this_obj,
                                   uint32_t idx, JSValue val);
JS_EXTERN int JS_SetPropertyInt64(JSContext *ctx, JSValueConst this_obj,
                                  int64_t idx, JSValue val);
JS_EXTERN int JS_SetPropertyStr(JSContext *ctx, JSValueConst this_obj,
                                const char *prop, JSValue val);
JS_EXTERN int JS_HasProperty(JSContext *ctx, JSValueConst this_obj, JSAtom prop);
JS_EXTERN int JS_IsExtensible(JSContext *ctx, JSValueConst obj);
JS_EXTERN int JS_PreventExtensions(JSContext *ctx, JSValueConst obj);
JS_EXTERN int JS_DeleteProperty(JSContext *ctx, JSValueConst obj, JSAtom prop, int flags);
JS_EXTERN int JS_SetPrototype(JSContext *ctx, JSValueConst obj, JSValueConst proto_val);
JS_EXTERN JSValue JS_GetPrototype(JSContext *ctx, JSValueConst val);
JS_EXTERN int JS_GetLength(JSContext *ctx, JSValueConst obj, int64_t *pres);
JS_EXTERN int JS_SetLength(JSContext *ctx, JSValueConst obj, int64_t len);
JS_EXTERN int JS_SealObject(JSContext *ctx, JSValueConst obj);
JS_EXTERN int JS_FreezeObject(JSContext *ctx, JSValueConst obj);

#define JS_GPN_STRING_MASK  (1 << 0)
#define JS_GPN_SYMBOL_MASK  (1 << 1)
#define JS_GPN_PRIVATE_MASK (1 << 2)
/* only include the enumerable properties */
#define JS_GPN_ENUM_ONLY    (1 << 4)
/* set theJSPropertyEnum.is_enumerable field */
#define JS_GPN_SET_ENUM     (1 << 5)

JS_EXTERN int JS_GetOwnPropertyNames(JSContext *ctx, JSPropertyEnum **ptab,
                                     uint32_t *plen, JSValueConst obj,
                                     int flags);
JS_EXTERN int JS_GetOwnProperty(JSContext *ctx, JSPropertyDescriptor *desc,
                                JSValueConst obj, JSAtom prop);
JS_EXTERN void JS_FreePropertyEnum(JSContext *ctx, JSPropertyEnum *tab,
                                   uint32_t len);

JS_EXTERN JSValue JS_Call(JSContext *ctx, JSValueConst func_obj,
                          JSValueConst this_obj, int argc, JSValueConst *argv);
JS_EXTERN JSValue JS_Invoke(JSContext *ctx, JSValueConst this_val, JSAtom atom,
                            int argc, JSValueConst *argv);
JS_EXTERN JSValue JS_CallConstructor(JSContext *ctx, JSValueConst func_obj,
                                     int argc, JSValueConst *argv);
JS_EXTERN JSValue JS_CallConstructor2(JSContext *ctx, JSValueConst func_obj,
                                      JSValueConst new_target,
                                      int argc, JSValueConst *argv);
/* Try to detect if the input is a module. Returns true if parsing the input
 * as a module produces no syntax errors. It's a naive approach that is not
 * wholly infallible: non-strict classic scripts may _parse_ okay as a module
 * but not _execute_ as one (different runtime semantics.) Use with caution.
 * |input| can be either ASCII or UTF-8 encoded source code.
 * Returns false if QuickJS was built with -DQJS_DISABLE_PARSER.
 */
JS_EXTERN bool JS_DetectModule(const char *input, size_t input_len);
/* 'input' must be zero terminated i.e. input[input_len] = '\0'. */
JS_EXTERN JSValue JS_Eval(JSContext *ctx, const char *input, size_t input_len,
                          const char *filename, int eval_flags);
JS_EXTERN JSValue JS_Eval2(JSContext *ctx, const char *input, size_t input_len,
                           JSEvalOptions *options);
JS_EXTERN JSValue JS_EvalThis(JSContext *ctx, JSValueConst this_obj,
                              const char *input, size_t input_len,
                              const char *filename, int eval_flags);
JS_EXTERN JSValue JS_EvalThis2(JSContext *ctx, JSValueConst this_obj,
                              const char *input, size_t input_len,
                              JSEvalOptions *options);
JS_EXTERN JSValue JS_GetGlobalObject(JSContext *ctx);
JS_EXTERN int JS_IsInstanceOf(JSContext *ctx, JSValueConst val, JSValueConst obj);
JS_EXTERN int JS_DefineProperty(JSContext *ctx, JSValueConst this_obj,
                                JSAtom prop, JSValueConst val,
                                JSValueConst getter, JSValueConst setter,
                                int flags);
JS_EXTERN int JS_DefinePropertyValue(JSContext *ctx, JSValueConst this_obj,
                                     JSAtom prop, JSValue val, int flags);
JS_EXTERN int JS_DefinePropertyValueUint32(JSContext *ctx, JSValueConst this_obj,
                                           uint32_t idx, JSValue val, int flags);
JS_EXTERN int JS_DefinePropertyValueStr(JSContext *ctx, JSValueConst this_obj,
                                        const char *prop, JSValue val, int flags);
JS_EXTERN int JS_DefinePropertyGetSet(JSContext *ctx, JSValueConst this_obj,
                                      JSAtom prop, JSValue getter, JSValue setter,
                                      int flags);
/* Only supported for custom classes, returns 0 on success < 0 otherwise. */
JS_EXTERN int JS_SetOpaque(JSValueConst obj, void *opaque);
JS_EXTERN void *JS_GetOpaque(JSValueConst obj, JSClassID class_id);
JS_EXTERN void *JS_GetOpaque2(JSContext *ctx, JSValueConst obj, JSClassID class_id);
JS_EXTERN void *JS_GetAnyOpaque(JSValueConst obj, JSClassID *class_id);

/* 'buf' must be zero terminated i.e. buf[buf_len] = '\0'. */
JS_EXTERN JSValue JS_ParseJSON(JSContext *ctx, const char *buf, size_t buf_len,
                               const char *filename);
JS_EXTERN JSValue JS_JSONStringify(JSContext *ctx, JSValueConst obj,
                                   JSValueConst replacer, JSValueConst space0);

typedef void JSFreeArrayBufferDataFunc(JSRuntime *rt, void *opaque, void *ptr);
JS_EXTERN JSValue JS_NewArrayBuffer(JSContext *ctx, uint8_t *buf, size_t len,
                                    JSFreeArrayBufferDataFunc *free_func, void *opaque,
                                    bool is_shared);
JS_EXTERN JSValue JS_NewArrayBufferCopy(JSContext *ctx, const uint8_t *buf, size_t len);
JS_EXTERN void JS_DetachArrayBuffer(JSContext *ctx, JSValueConst obj);
JS_EXTERN uint8_t *JS_GetArrayBuffer(JSContext *ctx, size_t *psize, JSValueConst obj);
JS_EXTERN bool JS_IsArrayBuffer(JSValueConst obj);
// returns true or false if obj is an ArrayBuffer, -1 otherwise
JS_EXTERN int JS_IsImmutableArrayBuffer(JSValueConst obj);
// returns 0 if obj is an ArrayBuffer, -1 otherwise
JS_EXTERN int JS_SetImmutableArrayBuffer(JSValueConst obj, bool immutable);
JS_EXTERN uint8_t *JS_GetUint8Array(JSContext *ctx, size_t *psize, JSValueConst obj);

typedef enum JSTypedArrayEnum {
    JS_TYPED_ARRAY_UINT8C = 0,
    JS_TYPED_ARRAY_INT8,
    JS_TYPED_ARRAY_UINT8,
    JS_TYPED_ARRAY_INT16,
    JS_TYPED_ARRAY_UINT16,
    JS_TYPED_ARRAY_INT32,
    JS_TYPED_ARRAY_UINT32,
    JS_TYPED_ARRAY_BIG_INT64,
    JS_TYPED_ARRAY_BIG_UINT64,
    JS_TYPED_ARRAY_FLOAT16,
    JS_TYPED_ARRAY_FLOAT32,
    JS_TYPED_ARRAY_FLOAT64,
} JSTypedArrayEnum;

JS_EXTERN JSValue JS_NewTypedArray(JSContext *ctx, int argc, JSValueConst *argv,
                                   JSTypedArrayEnum array_type);
JS_EXTERN JSValue JS_GetTypedArrayBuffer(JSContext *ctx, JSValueConst obj,
                                         size_t *pbyte_offset,
                                         size_t *pbyte_length,
                                         size_t *pbytes_per_element);
JS_EXTERN JSValue JS_NewUint8Array(JSContext *ctx, uint8_t *buf, size_t len,
                                   JSFreeArrayBufferDataFunc *free_func, void *opaque,
                                   bool is_shared);
/* returns -1 if not a typed array otherwise return a JSTypedArrayEnum value */
JS_EXTERN int JS_GetTypedArrayType(JSValueConst obj);
JS_EXTERN JSValue JS_NewUint8ArrayCopy(JSContext *ctx, const uint8_t *buf, size_t len);
typedef struct {
    void *(*sab_alloc)(void *opaque, size_t size);
    void (*sab_free)(void *opaque, void *ptr);
    void (*sab_dup)(void *opaque, void *ptr);
    void *sab_opaque;
} JSSharedArrayBufferFunctions;
JS_EXTERN void JS_SetSharedArrayBufferFunctions(JSRuntime *rt, const JSSharedArrayBufferFunctions *sf);

typedef enum JSPromiseStateEnum {
    // argument to JS_PromiseState() was not in fact a promise
    JS_PROMISE_NOT_A_PROMISE = -1,
    JS_PROMISE_PENDING       =  0,
    JS_PROMISE_FULFILLED,
    JS_PROMISE_REJECTED,
} JSPromiseStateEnum;

JS_EXTERN JSValue JS_NewPromiseCapability(JSContext *ctx, JSValue *resolving_funcs);
JS_EXTERN JSPromiseStateEnum JS_PromiseState(JSContext *ctx,
                                             JSValueConst promise);
JS_EXTERN JSValue JS_PromiseResult(JSContext *ctx, JSValueConst promise);
JS_EXTERN bool JS_IsPromise(JSValueConst val);
JS_EXTERN JSValue JS_NewSettledPromise(JSContext *ctx, bool is_reject, JSValueConst value);

JS_EXTERN JSValue JS_NewSymbol(JSContext *ctx, const char *description, bool is_global);

typedef enum JSPromiseHookType {
    JS_PROMISE_HOOK_INIT,     // emitted when a new promise is created
    JS_PROMISE_HOOK_BEFORE,   // runs right before promise.then is invoked
    JS_PROMISE_HOOK_AFTER,    // runs right after promise.then is invoked
    JS_PROMISE_HOOK_RESOLVE,  // not emitted for rejected promises
} JSPromiseHookType;

// parent_promise is only passed in when type == JS_PROMISE_HOOK_INIT and
// is then either a promise object or JS_UNDEFINED if the new promise does
// not have a parent promise; only promises created with promise.then have
// a parent promise
typedef void JSPromiseHook(JSContext *ctx, JSPromiseHookType type,
                           JSValueConst promise, JSValueConst parent_promise,
                           void *opaque);
JS_EXTERN void JS_SetPromiseHook(JSRuntime *rt, JSPromiseHook promise_hook,
                                 void *opaque);

/* is_handled = true means that the rejection is handled */
typedef void JSHostPromiseRejectionTracker(JSContext *ctx, JSValueConst promise,
                                           JSValueConst reason,
                                           bool is_handled, void *opaque);
JS_EXTERN void JS_SetHostPromiseRejectionTracker(JSRuntime *rt, JSHostPromiseRejectionTracker *cb, void *opaque);

/* return != 0 if the JS code needs to be interrupted */
typedef int JSInterruptHandler(JSRuntime *rt, void *opaque);
JS_EXTERN void JS_SetInterruptHandler(JSRuntime *rt, JSInterruptHandler *cb, void *opaque);
/* if can_block is true, Atomics.wait() can be used */
JS_EXTERN void JS_SetCanBlock(JSRuntime *rt, bool can_block);
/* set the [IsHTMLDDA] internal slot */
JS_EXTERN void JS_SetIsHTMLDDA(JSContext *ctx, JSValueConst obj);

typedef struct JSModuleDef JSModuleDef;

/* return the module specifier (allocated with js_malloc()) or NULL if
   exception */
typedef char *JSModuleNormalizeFunc(JSContext *ctx,
                                    const char *module_base_name,
                                    const char *module_name, void *opaque);
typedef char *JSModuleNormalizeFunc2(JSContext *ctx,
                                     const char *module_base_name,
                                     const char *module_name,
                                     JSValueConst attributes,
                                     void *opaque);
typedef JSModuleDef *JSModuleLoaderFunc(JSContext *ctx,
                                        const char *module_name, void *opaque);

/* module loader with import attributes support */
typedef JSModuleDef *JSModuleLoaderFunc2(JSContext *ctx,
                                         const char *module_name, void *opaque,
                                         JSValueConst attributes);

/* return -1 if exception, 0 if OK */
typedef int JSModuleCheckSupportedImportAttributes(JSContext *ctx, void *opaque,
                                                   JSValueConst attributes);

/* module_normalize = NULL is allowed and invokes the default module
   filename normalizer */
JS_EXTERN void JS_SetModuleLoaderFunc(JSRuntime *rt,
                                      JSModuleNormalizeFunc *module_normalize,
                                      JSModuleLoaderFunc *module_loader, void *opaque);

/* same as JS_SetModuleLoaderFunc but with import attributes support */
JS_EXTERN void JS_SetModuleLoaderFunc2(JSRuntime *rt,
                                       JSModuleNormalizeFunc *module_normalize,
                                       JSModuleLoaderFunc2 *module_loader,
                                       JSModuleCheckSupportedImportAttributes *module_check_attrs,
                                       void *opaque);

/* Set an attributes-aware module normalizer. Call after JS_SetModuleLoaderFunc2. */
JS_EXTERN void JS_SetModuleNormalizeFunc2(JSRuntime *rt,
                                          JSModuleNormalizeFunc2 *module_normalize);

/* return the import.meta object of a module */
JS_EXTERN JSValue JS_GetImportMeta(JSContext *ctx, JSModuleDef *m);
JS_EXTERN JSAtom JS_GetModuleName(JSContext *ctx, JSModuleDef *m);
JS_EXTERN JSValue JS_GetModuleNamespace(JSContext *ctx, JSModuleDef *m);

/* associate a JSValue to a C module */
JS_EXTERN int JS_SetModulePrivateValue(JSContext *ctx, JSModuleDef *m, JSValue val);
JS_EXTERN JSValue JS_GetModulePrivateValue(JSContext *ctx, JSModuleDef *m);

/* JS Job support */

typedef JSValue JSJobFunc(JSContext *ctx, int argc, JSValueConst *argv);
JS_EXTERN int JS_EnqueueJob(JSContext *ctx, JSJobFunc *job_func,
                            int argc, JSValueConst *argv);

JS_EXTERN bool JS_IsJobPending(JSRuntime *rt);
JS_EXTERN JSContext *JS_GetPendingJobContext(JSRuntime *rt);
JS_EXTERN int JS_ExecutePendingJob(JSRuntime *rt, JSContext **pctx);

/* Structure to retrieve (de)serialized SharedArrayBuffer objects. */
typedef struct JSSABTab {
    uint8_t **tab;
    size_t len;
} JSSABTab;

/* Object Writer/Reader (currently only used to handle precompiled code) */
#define JS_WRITE_OBJ_BYTECODE  (1 << 0) /* allow function/module */
#define JS_WRITE_OBJ_BSWAP     (0)      /* byte swapped output (obsolete, handled transparently) */
#define JS_WRITE_OBJ_SAB       (1 << 2) /* allow SharedArrayBuffer */
#define JS_WRITE_OBJ_REFERENCE (1 << 3) /* allow object references to encode arbitrary object graph */
#define JS_WRITE_OBJ_STRIP_SOURCE  (1 << 4) /* do not write source code information */
#define JS_WRITE_OBJ_STRIP_DEBUG   (1 << 5) /* do not write debug information */
JS_EXTERN uint8_t *JS_WriteObject(JSContext *ctx, size_t *psize, JSValueConst obj, int flags);
JS_EXTERN uint8_t *JS_WriteObject2(JSContext *ctx, size_t *psize, JSValueConst obj,
                                   int flags, JSSABTab *psab_tab);

/* WARNING: only enable JS_READ_OBJ_BYTECODE on input from a trusted
   writer. The bytecode format is not designed to resist a hostile
   producer; loading adversarial bytecode can lead to memory corruption. */
#define JS_READ_OBJ_BYTECODE  (1 << 0) /* allow function/module */
#define JS_READ_OBJ_ROM_DATA  (0)      /* avoid duplicating 'buf' data (obsolete, broken by ICs) */
/* WARNING: serialized SharedArrayBuffers carry a literal host pointer in
   the blob; only enable JS_READ_OBJ_SAB on input produced by a trusted
   writer in the same process (e.g. another Worker on the same runtime). */
#define JS_READ_OBJ_SAB       (1 << 2) /* allow SharedArrayBuffer */
#define JS_READ_OBJ_REFERENCE (1 << 3) /* allow object references */
JS_EXTERN JSValue JS_ReadObject(JSContext *ctx, const uint8_t *buf, size_t buf_len, int flags);
JS_EXTERN JSValue JS_ReadObject2(JSContext *ctx, const uint8_t *buf, size_t buf_len,
                                 int flags, JSSABTab *psab_tab);
/* instantiate and evaluate a bytecode function. Only used when
   reading a script or module with JS_ReadObject() */
JS_EXTERN JSValue JS_EvalFunction(JSContext *ctx, JSValue fun_obj);
/* load the dependencies of the module 'obj'. Useful when JS_ReadObject()
   returns a module. */
JS_EXTERN int JS_ResolveModule(JSContext *ctx, JSValueConst obj);

/* only exported for os.Worker() */
JS_EXTERN JSAtom JS_GetScriptOrModuleName(JSContext *ctx, int n_stack_levels);
/* only exported for os.Worker() */
JS_EXTERN JSValue JS_LoadModule(JSContext *ctx, const char *basename,
                                const char *filename);

/* C function definition */
typedef enum JSCFunctionEnum {  /* XXX: should rename for namespace isolation */
    JS_CFUNC_generic,
    JS_CFUNC_generic_magic,
    JS_CFUNC_constructor,
    JS_CFUNC_constructor_magic,
    JS_CFUNC_constructor_or_func,
    JS_CFUNC_constructor_or_func_magic,
    JS_CFUNC_f_f,
    JS_CFUNC_f_f_f,
    JS_CFUNC_getter,
    JS_CFUNC_setter,
    JS_CFUNC_getter_magic,
    JS_CFUNC_setter_magic,
    JS_CFUNC_iterator_next,
} JSCFunctionEnum;

typedef union JSCFunctionType {
    JSCFunction *generic;
    JSValue (*generic_magic)(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic);
    JSCFunction *constructor;
    JSValue (*constructor_magic)(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv, int magic);
    JSCFunction *constructor_or_func;
    double (*f_f)(double);
    double (*f_f_f)(double, double);
    JSValue (*getter)(JSContext *ctx, JSValueConst this_val);
    JSValue (*setter)(JSContext *ctx, JSValueConst this_val, JSValueConst val);
    JSValue (*getter_magic)(JSContext *ctx, JSValueConst this_val, int magic);
    JSValue (*setter_magic)(JSContext *ctx, JSValueConst this_val, JSValueConst val, int magic);
    JSValue (*iterator_next)(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv, int *pdone, int magic);
} JSCFunctionType;

JS_EXTERN JSValue JS_NewCFunction2(JSContext *ctx, JSCFunction *func,
                                   const char *name,
                                   int length, JSCFunctionEnum cproto, int magic);
JS_EXTERN JSValue JS_NewCFunction3(JSContext *ctx, JSCFunction *func,
                                   const char *name,
                                   int length, JSCFunctionEnum cproto, int magic,
                                   JSValueConst proto_val, int n_fields);
JS_EXTERN JSValue JS_NewCFunctionData(JSContext *ctx, JSCFunctionData *func,
                                      int length, int magic, int data_len,
                                      JSValueConst *data);
JS_EXTERN JSValue JS_NewCFunctionData2(JSContext *ctx, JSCFunctionData *func,
                                       const char *name,
                                       int length, int magic, int data_len,
                                       JSValueConst *data);
typedef void JSCClosureFinalizerFunc(void*);
JS_EXTERN JSValue JS_NewCClosure(JSContext *ctx, JSCClosure *func,
                                 const char *name,
                                 JSCClosureFinalizerFunc *opaque_finalize,
                                 int length, int magic, void *opaque);

static inline JSValue JS_NewCFunction(JSContext *ctx, JSCFunction *func,
                                      const char *name, int length)
{
    return JS_NewCFunction2(ctx, func, name, length, JS_CFUNC_generic, 0);
}

static inline JSValue JS_NewCFunctionMagic(JSContext *ctx, JSCFunctionMagic *func,
                                           const char *name, int length,
                                           JSCFunctionEnum cproto, int magic)
{
    /* Used to squelch a -Wcast-function-type warning. */
    JSCFunctionType ft;
    ft.generic_magic = func;
    return JS_NewCFunction2(ctx, ft.generic, name, length, cproto, magic);
}
JS_EXTERN int JS_SetConstructor(JSContext *ctx, JSValueConst func_obj,
                                JSValueConst proto);

/* C property definition */

typedef struct JSCFunctionListEntry {
    const char *name;       /* pure ASCII or UTF-8 encoded */
    uint8_t prop_flags;
    uint8_t def_type;
    int16_t magic;
    union {
        struct {
            uint8_t length; /* XXX: should move outside union */
            uint8_t cproto; /* XXX: should move outside union */
            JSCFunctionType cfunc;
        } func;
        struct {
            JSCFunctionType get;
            JSCFunctionType set;
        } getset;
        struct {
            const char *name;
            int base;
        } alias;
        struct {
            const struct JSCFunctionListEntry *tab;
            int len;
        } prop_list;
        const char *str;    /* pure ASCII or UTF-8 encoded */
        int32_t i32;
        int64_t i64;
        uint64_t u64;
        double f64;
    } u;
} JSCFunctionListEntry;

#define JS_DEF_CFUNC          0
#define JS_DEF_CGETSET        1
#define JS_DEF_CGETSET_MAGIC  2
#define JS_DEF_PROP_STRING    3
#define JS_DEF_PROP_INT32     4
#define JS_DEF_PROP_INT64     5
#define JS_DEF_PROP_DOUBLE    6
#define JS_DEF_PROP_UNDEFINED 7
#define JS_DEF_OBJECT         8
#define JS_DEF_ALIAS          9
#define JS_DEF_PROP_SYMBOL   10
#define JS_DEF_PROP_BOOL     11

/* Note: c++ does not like nested designators */
#define JS_CFUNC_DEF(name, length, func1) { name, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, JS_DEF_CFUNC, 0, { .func = { length, JS_CFUNC_generic, { .generic = func1 } } } }
#define JS_CFUNC_DEF2(name, length, func1, prop_flags) { name, prop_flags, JS_DEF_CFUNC, 0, { .func = { length, JS_CFUNC_generic, { .generic = func1 } } } }
#define JS_CFUNC_MAGIC_DEF(name, length, func1, magic) { name, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, JS_DEF_CFUNC, magic, { .func = { length, JS_CFUNC_generic_magic, { .generic_magic = func1 } } } }
#define JS_CFUNC_SPECIAL_DEF(name, length, cproto, func1) { name, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, JS_DEF_CFUNC, 0, { .func = { length, JS_CFUNC_ ## cproto, { .cproto = func1 } } } }
#define JS_ITERATOR_NEXT_DEF(name, length, func1, magic) { name, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, JS_DEF_CFUNC, magic, { .func = { length, JS_CFUNC_iterator_next, { .iterator_next = func1 } } } }
#define JS_CGETSET_DEF(name, fgetter, fsetter) { name, JS_PROP_CONFIGURABLE, JS_DEF_CGETSET, 0, { .getset = { .get = { .getter = fgetter }, .set = { .setter = fsetter } } } }
#define JS_CGETSET_DEF2(name, fgetter, fsetter, prop_flags) { name, prop_flags, JS_DEF_CGETSET, 0, { .getset = { .get = { .getter = fgetter }, .set = { .setter = fsetter } } } }
#define JS_CGETSET_MAGIC_DEF(name, fgetter, fsetter, magic) { name, JS_PROP_CONFIGURABLE, JS_DEF_CGETSET_MAGIC, magic, { .getset = { .get = { .getter_magic = fgetter }, .set = { .setter_magic = fsetter } } } }
#define JS_PROP_STRING_DEF(name, cstr, prop_flags) { name, prop_flags, JS_DEF_PROP_STRING, 0, { .str = cstr } }
#define JS_PROP_INT32_DEF(name, val, prop_flags) { name, prop_flags, JS_DEF_PROP_INT32, 0, { .i32 = val } }
#define JS_PROP_INT64_DEF(name, val, prop_flags) { name, prop_flags, JS_DEF_PROP_INT64, 0, { .i64 = val } }
#define JS_PROP_DOUBLE_DEF(name, val, prop_flags) { name, prop_flags, JS_DEF_PROP_DOUBLE, 0, { .f64 = val } }
#define JS_PROP_U2D_DEF(name, val, prop_flags) { name, prop_flags, JS_DEF_PROP_DOUBLE, 0, { .u64 = val } }
#define JS_PROP_UNDEFINED_DEF(name, prop_flags) { name, prop_flags, JS_DEF_PROP_UNDEFINED, 0, { .i32 = 0 } }
#define JS_PROP_SYMBOL_DEF(name, val, prop_flags) { name, prop_flags, JS_DEF_PROP_SYMBOL, 0, { .i32 = val } }
#define JS_PROP_BOOL_DEF(name, val, prop_flags) { name, prop_flags, JS_DEF_PROP_BOOL, 0, { .i32 = val } }
#define JS_OBJECT_DEF(name, tab, len, prop_flags) { name, prop_flags, JS_DEF_OBJECT, 0, { .prop_list = { tab, len } } }
#define JS_ALIAS_DEF(name, from) { name, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, JS_DEF_ALIAS, 0, { .alias = { from, -1 } } }
#define JS_ALIAS_BASE_DEF(name, from, base) { name, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, JS_DEF_ALIAS, 0, { .alias = { from, base } } }

JS_EXTERN int JS_SetPropertyFunctionList(JSContext *ctx, JSValueConst obj,
                                          const JSCFunctionListEntry *tab,
                                          int len);

/* C module definition */

typedef int JSModuleInitFunc(JSContext *ctx, JSModuleDef *m);

JS_EXTERN JSModuleDef *JS_NewCModule(JSContext *ctx, const char *name_str,
                                     JSModuleInitFunc *func);
/* can only be called before the module is instantiated */
JS_EXTERN int JS_AddModuleExport(JSContext *ctx, JSModuleDef *m, const char *name_str);
JS_EXTERN int JS_AddModuleExportList(JSContext *ctx, JSModuleDef *m,
                                      const JSCFunctionListEntry *tab, int len);
/* can only be called after the module is instantiated */
JS_EXTERN int JS_SetModuleExport(JSContext *ctx, JSModuleDef *m, const char *export_name,
                                 JSValue val);
JS_EXTERN int JS_SetModuleExportList(JSContext *ctx, JSModuleDef *m,
                                     const JSCFunctionListEntry *tab, int len);

/* Version */

#define QJS_VERSION_MAJOR 0
#define QJS_VERSION_MINOR 15
#define QJS_VERSION_PATCH 1
#define QJS_VERSION_SUFFIX ""

JS_EXTERN const char* JS_GetVersion(void);

/* Integration point for quickjs-libc.c, not for public use. */
JS_EXTERN uintptr_t js_std_cmd(int cmd, ...);

#ifdef __cplusplus
} /* extern "C" { */
#endif

#endif /* QUICKJS_H */
