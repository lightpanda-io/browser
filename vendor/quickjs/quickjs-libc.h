/*
 * QuickJS C library
 *
 * Copyright (c) 2017-2018 Fabrice Bellard
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
#ifndef QUICKJS_LIBC_H
#define QUICKJS_LIBC_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "quickjs.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef uint8_t *JSLoadFileFunc(JSContext *ctx, size_t *pbuf_len,
                                const char *filename);

JS_LIBC_EXTERN JSModuleDef *js_init_module_std(JSContext *ctx,
                                               const char *module_name);
JS_LIBC_EXTERN JSModuleDef *js_init_module_os(JSContext *ctx,
                                              const char *module_name);
JS_LIBC_EXTERN JSModuleDef *js_init_module_bjson(JSContext *ctx,
                                                 const char *module_name);
JS_LIBC_EXTERN void js_std_add_helpers(JSContext *ctx, int argc, char **argv);
JS_LIBC_EXTERN int js_std_loop(JSContext *ctx);
JS_LIBC_EXTERN int js_std_loop_once(JSContext *ctx);
JS_LIBC_EXTERN int js_std_poll_io(JSContext *ctx, int timeout_ms);
JS_LIBC_EXTERN JSValue js_std_await(JSContext *ctx, JSValue obj);
JS_LIBC_EXTERN void js_std_init_handlers(JSRuntime *rt);
JS_LIBC_EXTERN void js_std_free_handlers(JSRuntime *rt);
JS_LIBC_EXTERN void js_std_dump_error(JSContext *ctx);
JS_LIBC_EXTERN uint8_t *js_load_file(JSContext *ctx, size_t *pbuf_len,
                                     const char *filename);
JS_LIBC_EXTERN int js_module_set_import_meta(JSContext *ctx, JSValueConst func_val,
                                             bool use_realpath, bool is_main);
JS_LIBC_EXTERN JSModuleDef *js_module_loader(JSContext *ctx,
                                             const char *module_name, void *opaque,
                                             JSValueConst attributes);
// like js_module_loader but does not load .so objects and the file reader
// is pluggable; js_module_loader is implemented in terms of js_module_load
JS_LIBC_EXTERN JSModuleDef *js_module_load(JSContext *ctx, const char *module_name,
                                           void *opaque, JSValueConst attributes,
                                           JSLoadFileFunc *load_file);
JS_LIBC_EXTERN int js_module_check_attributes(JSContext *ctx, void *opaque,
                                              JSValueConst attributes);
JS_LIBC_EXTERN void js_std_eval_binary(JSContext *ctx, const uint8_t *buf,
                                       size_t buf_len, int flags);
JS_LIBC_EXTERN void js_std_promise_rejection_tracker(JSContext *ctx,
                                                     JSValueConst promise,
                                                     JSValueConst reason,
                                                     bool is_handled,
                                                     void *opaque);
// Defaults to JS_NewRuntime, no-op if compiled without worker support.
// Call before creating the first worker thread.
JS_LIBC_EXTERN void js_std_set_worker_new_runtime_func(JSRuntime *(*func)(void));
// Defaults to JS_NewContext, no-op if compiled without worker support.
// Call before creating the first worker thread.
JS_LIBC_EXTERN void js_std_set_worker_new_context_func(JSContext *(*func)(JSRuntime *rt));

#ifdef __cplusplus
} /* extern "C" { */
#endif

#endif /* QUICKJS_LIBC_H */
