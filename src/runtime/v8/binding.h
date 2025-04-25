#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

typedef uintptr_t usize;
typedef struct Data Data;
typedef struct ArrayBuffer ArrayBuffer;
typedef struct ArrayBufferAllocator ArrayBufferAllocator;
typedef struct CreateParams CreateParams;
typedef struct Isolate Isolate;
typedef struct StackTrace StackTrace;
typedef struct StackFrame StackFrame;
typedef struct FixedArray FixedArray;
typedef struct Module Module;
typedef struct FunctionTemplate FunctionTemplate;
typedef struct Message Message;
typedef struct Context Context;
// Internally, all Value types have a base InternalAddress struct.
typedef uintptr_t InternalAddress;
// Super type.
typedef Data Value;
typedef Value Object;
typedef Value String;
typedef Value Function;
typedef Value Number;
typedef Value Primitive;
typedef Value Integer;
typedef Value BigInt;
typedef Value Array;
typedef Value Uint8Array;
typedef Value ArrayBufferView;
typedef Value External;
typedef Value Symbol;
typedef Value Boolean;
typedef Value Promise;
typedef Value Name;
typedef Value PromiseResolver;
typedef enum CompileOptions {
    kNoCompileOptions = 0,
    kConsumeCodeCache = 1,
    kEagerCompile = 2,
} CompileOptions;
typedef enum NoCacheReason {
    kNoCacheNoReason = 0,
    kNoCacheBecauseCachingDisabled,
    kNoCacheBecauseNoResource,
    kNoCacheBecauseInlineScript,
    kNoCacheBecauseModule,
    kNoCacheBecauseStreamingSource,
    kNoCacheBecauseInspector,
    kNoCacheBecauseScriptTooSmall,
    kNoCacheBecauseCacheTooCold,
    kNoCacheBecauseV8Extension,
    kNoCacheBecauseExtensionModule,
    kNoCacheBecausePacScript,
    kNoCacheBecauseInDocumentWrite,
    kNoCacheBecauseResourceWithNoCacheHandler,
    kNoCacheBecauseDeferredProduceCodeCache
} NoCacheReason;
typedef enum PromiseRejectEvent {
    kPromiseRejectWithNoHandler = 0,
    kPromiseHandlerAddedAfterReject = 1,
    kPromiseRejectAfterResolved = 2,
    kPromiseResolveAfterResolved = 3,
} PromiseRejectEvent;
typedef struct PromiseRejectMessage PromiseRejectMessage;
typedef void (*PromiseRejectCallback)(PromiseRejectMessage);
typedef enum MessageErrorLevel {
    kMessageLog = (1 << 0),
    kMessageDebug = (1 << 1),
    kMessageInfo = (1 << 2),
    kMessageError = (1 << 3),
    kMessageWarning = (1 << 4),
    kMessageAll = kMessageLog | kMessageDebug | kMessageInfo | kMessageError |
                  kMessageWarning,
} MessageErrorLevel;
typedef void (*MessageCallback)(const Message* message, const Value* data);
typedef usize UniquePtr;
typedef struct SharedPtr {
    usize a;
    usize b;
} SharedPtr;
typedef uintptr_t IntAddress; // v8::internal::Address

typedef struct MaybeU32 {
    bool has_value;
    uint32_t value;
} MaybeU32;
typedef struct MaybeI32 {
    bool has_value;
    int32_t value;
} MaybeI32;
typedef struct MaybeF64 {
    bool has_value;
    double value;
} MaybeF64;
typedef struct MaybeBool {
    bool has_value;
    bool value;
} MaybeBool;
typedef enum PropertyAttribute {
    /** None. **/
    None = 0,
    /** ReadOnly, i.e., not writable. **/
    ReadOnly = 1 << 0,
    /** DontEnum, i.e., not enumerable. **/
    DontEnum = 1 << 1,
    /** DontDelete, i.e., not configurable. **/
    DontDelete = 1 << 2
} PropertyAttribute;

// Platform
typedef struct Platform Platform;
Platform* v8__Platform__NewDefaultPlatform(int thread_pool_size, int idle_task_support);
void v8__Platform__DELETE(Platform* platform);
bool v8__Platform__PumpMessageLoop(Platform* platform, Isolate* isolate, bool wait_for_work);

// Root
const Primitive* v8__Undefined(Isolate* isolate);
const Primitive* v8__Null(Isolate* isolate);
const Boolean* v8__True(Isolate* isolate);
const Boolean* v8__False(Isolate* isolate);
const Uint8Array* v8__Uint8Array__New(
    const ArrayBuffer* buf,
    size_t byte_offset,
    size_t length);

// V8
void v8__V8__InitializePlatform(Platform* platform);
void v8__V8__Initialize();
bool v8__V8__InitializeICU();
int v8__V8__Dispose();
void v8__V8__DisposePlatform();
const char* v8__V8__GetVersion();

// Microtask
typedef enum MicrotasksPolicy { kExplicit, kScoped, kAuto } MicrotasksPolicy;

// Isolate
Isolate* v8__Isolate__New(CreateParams* params);
void v8__Isolate__Enter(Isolate* isolate);
void v8__Isolate__Exit(Isolate* isolate);
void v8__Isolate__Dispose(Isolate* isolate);
Context* v8__Isolate__GetCurrentContext(Isolate* isolate);
const Value* v8__Isolate__ThrowException(
    Isolate* isolate,
    const Value* exception);
void v8__Isolate__SetPromiseRejectCallback(
    Isolate* isolate,
    PromiseRejectCallback callback);
MicrotasksPolicy v8__Isolate__GetMicrotasksPolicy(const Isolate* self);
void v8__Isolate__SetMicrotasksPolicy(
    Isolate* self,
    MicrotasksPolicy policy);
void v8__Isolate__PerformMicrotaskCheckpoint(Isolate* self);
bool v8__Isolate__AddMessageListener(
    Isolate* self,
    MessageCallback callback);
bool v8__Isolate__AddMessageListenerWithErrorLevel(
    Isolate* self,
    MessageCallback callback,
    int message_levels,
    const Value* data);
void v8__Isolate__SetCaptureStackTraceForUncaughtExceptions(
    Isolate* isolate,
    bool capture,
    int frame_limit);
void v8__Isolate__TerminateExecution(Isolate* self);
bool v8__Isolate__IsExecutionTerminating(Isolate* self);
void v8__Isolate__CancelTerminateExecution(Isolate* self);
void v8__Isolate__LowMemoryNotification(Isolate* self);
typedef struct HeapStatistics {
    size_t total_heap_size;
    size_t total_heap_size_executable;
    size_t total_physical_size;
    size_t total_available_size;
    size_t used_heap_size;
    size_t heap_size_limit;
    size_t malloced_memory;
    size_t external_memory;
    size_t peak_malloced_memory;
    bool does_zap_garbage;
    size_t number_of_native_contexts;
    size_t number_of_detached_contexts;
    size_t total_global_handles_size;
    size_t used_global_handles_size;
} HeapStatistics;
void v8__Isolate__GetHeapStatistics(
    Isolate* self,
    HeapStatistics* stats);
usize v8__HeapStatistics__SIZEOF();
void* v8__Isolate__GetData(Isolate* self, int idx);
void v8__Isolate__SetData(Isolate* self, int idx, void* val);

typedef struct StartupData {
    const char* data;
    int raw_size;
} StartupData;

typedef struct ResourceConstraints {
    usize code_range_size_;
    usize max_old_generation_size_;
    usize max_young_generation_size_;
    usize initial_old_generation_size_;
    usize initial_young_generation_size_;
    uint32_t* stack_limit_;
} ResourceConstraints;

typedef struct CreateParams {
    void* code_event_handler; // JitCodeEventHandler
    ResourceConstraints constraints;
    StartupData* snapshot_blob;
    void* counter_lookup_callback;
    void* create_histogram_callback; // CreateHistogramCallback
    void* add_histogram_sample_callback; // AddHistogramSampleCallback
    ArrayBufferAllocator* array_buffer_allocator;
    SharedPtr array_buffer_allocator_shared;
    const intptr_t* external_references;
    bool allow_atomics_wait;
    bool only_terminate_in_safe_scope;
    int embedder_wrapper_type_index;
    int embedder_wrapper_object_index;
    void* fatal_error_callback;
    void* oom_error_callback;
} CreateParams;
usize v8__Isolate__CreateParams__SIZEOF();
void v8__Isolate__CreateParams__CONSTRUCT(CreateParams* buf);

// FixedArray
int v8__FixedArray__Length(const FixedArray* self);
const Data* v8__FixedArray__Get(
    const FixedArray* self,
    const Context* ctx,
    int idx);

// ArrayBuffer
typedef void (*PromiseRejectCallback)(PromiseRejectMessage);
typedef void (*BackingStoreDeleterCallback)(void* data, size_t len, void* deleter_data);
typedef struct BackingStore BackingStore;
ArrayBufferAllocator* v8__ArrayBuffer__Allocator__NewDefaultAllocator();
void v8__ArrayBuffer__Allocator__DELETE(ArrayBufferAllocator* self);
BackingStore* v8__ArrayBuffer__NewBackingStore(
    Isolate* isolate,
    size_t byte_len);
BackingStore* v8__ArrayBuffer__NewBackingStore2(
    void* data,
    size_t byte_len,
    BackingStoreDeleterCallback deleter,
    void* deleter_data);
void* v8__BackingStore__Data(const BackingStore* self);
size_t v8__BackingStore__ByteLength(const BackingStore* self);
bool v8__BackingStore__IsShared(const BackingStore* self);
SharedPtr v8__BackingStore__TO_SHARED_PTR(BackingStore* unique_ptr);
void std__shared_ptr__v8__BackingStore__reset(SharedPtr* self);
BackingStore* std__shared_ptr__v8__BackingStore__get(const SharedPtr* self);
long std__shared_ptr__v8__BackingStore__use_count(const SharedPtr* self);
const ArrayBuffer* v8__ArrayBuffer__New(Isolate* isolate, size_t byte_len);
const ArrayBuffer* v8__ArrayBuffer__New2(Isolate* isolate, const SharedPtr* backing_store);
size_t v8__ArrayBuffer__ByteLength(const ArrayBuffer* self);
SharedPtr v8__ArrayBuffer__GetBackingStore(const ArrayBuffer* self);

// ArrayBufferView
const ArrayBuffer* v8__ArrayBufferView__Buffer(const ArrayBufferView* self);

// HandleScope
typedef struct HandleScope {
    // internal vars.
    Isolate* isolate_;
    InternalAddress* prev_next_;
    InternalAddress* prev_limit_;
} HandleScope;
void v8__HandleScope__CONSTRUCT(HandleScope* buf, Isolate* isolate);
void v8__HandleScope__DESTRUCT(HandleScope* scope);

// Message
const String* v8__Message__Get(const Message* self);
const String* v8__Message__GetSourceLine(const Message* self, const Context* context);
const Value* v8__Message__GetScriptResourceName(const Message* self);
int v8__Message__GetLineNumber(const Message* self, const Context* context);
int v8__Message__GetStartColumn(const Message* self);
int v8__Message__GetEndColumn(const Message* self);
const StackTrace* v8__Message__GetStackTrace(const Message* self);

// TryCatch
typedef struct TryCatch {
    void* isolate_;
    struct TryCatch* next_;
    void* exception_;
    void* message_obj_;
    IntAddress js_stack_comparable_address_;
    usize flags;
} TryCatch;
usize v8__TryCatch__SIZEOF();
void v8__TryCatch__CONSTRUCT(TryCatch* buf, Isolate* isolate);
void v8__TryCatch__DESTRUCT(TryCatch* self);
const Value* v8__TryCatch__Exception(const TryCatch* self);
const Message* v8__TryCatch__Message(const TryCatch* self);
bool v8__TryCatch__HasCaught(const TryCatch* self);
const Value* v8__TryCatch__StackTrace(const TryCatch* self, const Context* context);
bool v8__TryCatch__IsVerbose(const TryCatch* self);
void v8__TryCatch__SetVerbose(
    TryCatch* self,
    bool value);
const Value* v8__TryCatch__ReThrow(TryCatch* self);

// StackTrace
int v8__StackTrace__GetFrameCount(const StackTrace* self);
const StackFrame* v8__StackTrace__GetFrame(
    const StackTrace* self,
    Isolate* isolate,
    uint32_t idx);
const StackTrace* v8__StackTrace__CurrentStackTrace__STATIC(Isolate* isolate, int frame_limit);
const String* v8__StackTrace__CurrentScriptNameOrSourceURL__STATIC(Isolate* isolate);

// StackFrame
int v8__StackFrame__GetLineNumber(const StackFrame* self);
int v8__StackFrame__GetColumn(const StackFrame* self);
int v8__StackFrame__GetScriptId(const StackFrame* self);
const String* v8__StackFrame__GetScriptName(const StackFrame* self);
const String* v8__StackFrame__GetScriptNameOrSourceURL(const StackFrame* self);
const String* v8__StackFrame__GetFunctionName(const StackFrame* self);
bool v8__StackFrame__IsEval(const StackFrame* self);
bool v8__StackFrame__IsConstructor(const StackFrame* self);
bool v8__StackFrame__IsWasm(const StackFrame* self);
bool v8__StackFrame__IsUserJavaScript(const StackFrame* self);

// Context
typedef struct Context Context;
typedef struct ObjectTemplate ObjectTemplate;
Context* v8__Context__New(Isolate* isolate, const ObjectTemplate* global_tmpl, const Value* global_obj);
void v8__Context__Enter(const Context* context);
void v8__Context__Exit(const Context* context);
Isolate* v8__Context__GetIsolate(const Context* context);
const Object* v8__Context__Global(const Context* self);
const Value* v8__Context__GetEmbedderData(
    const Context* self,
    int idx);
void v8__Context__SetEmbedderData(
    const Context* self,
    int idx,
    const Value* val);
int v8__Context__DebugContextId(const Context* self);

// Boolean
const Boolean* v8__Boolean__New(
    Isolate* isolate,
    bool value);

// String
typedef enum NewStringType {
    /**
     * Create a new string, always allocating new storage memory.
     */
    kNormal,

    /**
     * Acts as a hint that the string should be created in the
     * old generation heap space and be deduplicated if an identical string
     * already exists.
     */
    kInternalized
} NewStringType;
typedef enum WriteOptions {
    NO_OPTIONS = 0,
    HINT_MANY_WRITES_EXPECTED = 1,
    NO_NULL_TERMINATION = 2,
    PRESERVE_ONE_BYTE_NULL = 4,
    // Used by WriteUtf8 to replace orphan surrogate code units with the
    // unicode replacement character. Needs to be set to guarantee valid UTF-8
    // output.
    REPLACE_INVALID_UTF8 = 8
} WriteOptions;
String* v8__String__NewFromUtf8(Isolate* isolate, const char* data, NewStringType type, int length);
size_t v8__String__WriteUtf8(const String* str, Isolate* isolate, const char* buf, size_t len, WriteOptions options);
int v8__String__Utf8Length(const String* str, Isolate* isolate);

// Value
String* v8__Value__TypeOf(
    const Value* self,
    Isolate* isolate);
String* v8__Value__ToString(
    const Value* self,
    const Context* ctx);
const String* v8__Value__ToDetailString(
    const Value* self,
    const Context* ctx);
bool v8__Value__BooleanValue(
    const Value* self,
    Isolate* isolate);
void v8__Value__Uint32Value(
    const Value* self,
    const Context* ctx,
    MaybeU32* out);
void v8__Value__Int32Value(
    const Value* self,
    const Context* ctx,
    MaybeI32* out);
void v8__Value__NumberValue(
    const Value* self,
    const Context* context,
    MaybeF64* out);
bool v8__Value__IsFunction(const Value* self);
bool v8__Value__IsAsyncFunction(const Value* self);
bool v8__Value__IsObject(const Value* self);
bool v8__Value__IsString(const Value* self);
bool v8__Value__IsArray(const Value* self);
bool v8__Value__IsTypedArray(const Value* self);
bool v8__Value__IsUint8ClampedArray(const Value* self);
bool v8__Value__IsInt8Array(const Value* self);
bool v8__Value__IsUint16Array(const Value* self);
bool v8__Value__IsInt16Array(const Value* self);
bool v8__Value__IsUint32Array(const Value* self);
bool v8__Value__IsInt32Array(const Value* self);
bool v8__Value__IsFloat32Array(const Value* self);
bool v8__Value__IsFloat64Array(const Value* self);
bool v8__Value__IsArrayBuffer(const Value* self);
bool v8__Value__IsArrayBufferView(const Value* self);
bool v8__Value__IsUint8Array(const Value* self);
bool v8__Value__IsExternal(const Value* self);
bool v8__Value__IsTrue(const Value* self);
bool v8__Value__IsFalse(const Value* self);
bool v8__Value__IsUndefined(const Value* self);
bool v8__Value__IsNull(const Value* self);
bool v8__Value__IsNullOrUndefined(const Value* self);
bool v8__Value__IsNativeError(const Value* self);
bool v8__Value__IsBigInt(const Value* self);
bool v8__Value__IsBigIntObject(const Value* self);
void v8__Value__InstanceOf(
    const Value* self,
    const Context* ctx,
    const Object* object,
    MaybeBool* out);

// Promise
typedef enum PromiseState { kPending, kFulfilled, kRejected } PromiseState;
const PromiseResolver* v8__Promise__Resolver__New(
    const Context* ctx);
const Promise* v8__Promise__Resolver__GetPromise(
    const PromiseResolver* self);
void v8__Promise__Resolver__Resolve(
    const PromiseResolver* self,
    const Context* ctx,
    const Value* value,
    MaybeBool* out);
void v8__Promise__Resolver__Reject(
    const PromiseResolver* self,
    const Context* ctx,
    const Value* value,
    MaybeBool* out);
const Promise* v8__Promise__Catch(
    const Promise* self,
    const Context* ctx,
    const Function* handler);
const Promise* v8__Promise__Then(
    const Promise* self,
    const Context* ctx,
    const Function* handler);
const Promise* v8__Promise__Then2(
    const Promise* self,
    const Context* ctx,
    const Function* on_fulfilled,
    const Function* on_rejected);
PromiseState v8__Promise__State(const Promise* self);
void v8__Promise__MarkAsHandled(const Promise* self);
const Value* v8__Promise__Result(const Promise* self);

// Array
const Array* v8__Array__New(
    Isolate* isolate,
    int length);
const Array* v8__Array__New2(
    Isolate* isolate,
    const Value* const elements[],
    size_t length);
uint32_t v8__Array__Length(const Array* self);

// Object
const Object* v8__Object__New(Isolate* isolate);
const String* v8__Object__GetConstructorName(const Object* self);
int v8__Object__InternalFieldCount(
    const Object* self);
const Data* v8__Object__GetInternalField(
    const Object* self,
    int index);
void v8__Object__SetInternalField(
    const Object* self,
    int index,
    const Value* value);
const Value* v8__Object__Get(
    const Object* self,
    const Context* ctx,
    const Value* key);
const Value* v8__Object__GetIndex(
    const Object* self,
    const Context* ctx,
    uint32_t idx);
void v8__Object__Set(
    const Object* self,
    const Context* ctx,
    const Value* key,
    const Value* value,
    MaybeBool* out);
void v8__Object__Delete(
    const Object* self,
    const Context* ctx,
    const Value* key,
    MaybeBool* out);
void v8__Object__SetAtIndex(
    const Object* self,
    const Context* ctx,
    uint32_t idx,
    const Value* value,
    MaybeBool* out);
void v8__Object__DefineOwnProperty(
    const Object* self,
    const Context* ctx,
    const Name* key,
    const Value* value,
    PropertyAttribute attr,
    MaybeBool* out);
Isolate* v8__Object__GetIsolate(const Object* self);
const Context* v8__Object__GetCreationContext(const Object* self);
int v8__Object__GetIdentityHash(const Object* self);
void v8__Object__Has(
    const Object* self,
    const Context* ctx,
    const Value* key,
    MaybeBool* out);
void v8__Object__HasIndex(
    const Object* self,
    const Context* ctx,
    uint32_t idx,
    MaybeBool* out);
const Array* v8__Object__GetOwnPropertyNames(
    const Object* self,
    const Context* ctx);
const Array* v8__Object__GetPropertyNames(
    const Object* self,
    const Context* ctx);
const Value* v8__Object__GetPrototype(const Object* self);
void v8__Object__SetPrototype(
    const Object* self,
    const Context* ctx,
    const Object* prototype,
    MaybeBool* out);
void v8__Object__SetAlignedPointerInInternalField(
    const Object* self,
    int idx,
    void* ptr);

// Exception
const Value* v8__Exception__Error(const String* message);
const Value* v8__Exception__TypeError(const String* message);
const Value* v8__Exception__SyntaxError(const String* message);
const Value* v8__Exception__ReferenceError(const String* message);
const Value* v8__Exception__RangeError(const String* message);
const StackTrace* v8__Exception__GetStackTrace(const Value* exception);
const Message* v8__Exception__CreateMessage(
    Isolate* isolate,
    const Value* exception);

// Number
const Number* v8__Number__New(
    Isolate* isolate,
    double value);

// Integer
const Integer* v8__Integer__New(
    Isolate* isolate,
    int32_t value);
const Integer* v8__Integer__NewFromUnsigned(
    Isolate* isolate,
    uint32_t value);
int64_t v8__Integer__Value(const Integer* self);

// BigInt
const BigInt* v8__BigInt__New(
    Isolate* iso,
    int64_t val);
const BigInt* v8__BigInt__NewFromUnsigned(
    Isolate* iso,
    uint64_t val);
uint64_t v8__BigInt__Uint64Value(
    const BigInt* self,
    bool* lossless);
int64_t v8__BigInt__Int64Value(
    const BigInt* self,
    bool* lossless);

// Template
typedef struct Template Template;
void v8__Template__Set(
    const Template* self,
    const Name* key,
    const Data* value,
    PropertyAttribute attr);
void v8__Template__SetAccessorProperty__DEFAULT(
    const Template* self,
    const Name* key,
    const FunctionTemplate* getter);

typedef struct PropertyCallbackInfo PropertyCallbackInfo;
typedef void (*AccessorNameGetterCallback)(const Name*, const PropertyCallbackInfo*);
typedef void (*AccessorNameSetterCallback)(const Name*, const Value*, const PropertyCallbackInfo*);
void v8__Template__SetNativeDataProperty__DEFAULT(
    const Template* self,
    const Name* key,
    const AccessorNameGetterCallback* getter);
void v8__Template__SetNativeDataProperty__DEFAULT2(
    const Template* self,
    const Name* key,
    const AccessorNameGetterCallback* getter,
    const AccessorNameSetterCallback* setter);

typedef void (*AccessorNameGetterCallback)(const Name*, const PropertyCallbackInfo*);
typedef void (*AccessorNameSetterCallback)(const Name*, const Value*, const PropertyCallbackInfo*);

// FunctionCallbackInfo
typedef struct FunctionCallbackInfo FunctionCallbackInfo;
typedef struct ReturnValue {
    uintptr_t addr;
} ReturnValue;
Isolate* v8__FunctionCallbackInfo__GetIsolate(
    const FunctionCallbackInfo* self);
int v8__FunctionCallbackInfo__Length(
    const FunctionCallbackInfo* self);
const Value* v8__FunctionCallbackInfo__INDEX(
    const FunctionCallbackInfo* self, int i);
void v8__FunctionCallbackInfo__GetReturnValue(
    const FunctionCallbackInfo* self,
    ReturnValue* res);
const Object* v8__FunctionCallbackInfo__This(
    const FunctionCallbackInfo* self);
const Value* v8__FunctionCallbackInfo__Data(
    const FunctionCallbackInfo* self);

// PropertyCallbackInfo
Isolate* v8__PropertyCallbackInfo__GetIsolate(
    const PropertyCallbackInfo* self);
void v8__PropertyCallbackInfo__GetReturnValue(
    const PropertyCallbackInfo* self,
    ReturnValue* res);
const Object* v8__PropertyCallbackInfo__This(
    const PropertyCallbackInfo* self);
const Value* v8__PropertyCallbackInfo__Data(
    const PropertyCallbackInfo* self);

// PromiseRejectMessage
struct PromiseRejectMessage {
    uintptr_t promise;
    PromiseRejectEvent event;
    uintptr_t value;
};
PromiseRejectEvent v8__PromiseRejectMessage__GetEvent(
    const PromiseRejectMessage* self);
const Promise* v8__PromiseRejectMessage__GetPromise(
    const PromiseRejectMessage* self);
const Value* v8__PromiseRejectMessage__GetValue(
    const PromiseRejectMessage* self);
usize v8__PromiseRejectMessage__SIZEOF();

// ReturnValue
void v8__ReturnValue__Set(
    const ReturnValue self,
    const Value* value);
const Value* v8__ReturnValue__Get(
    const ReturnValue self);

// FunctionTemplate
typedef void (*FunctionCallback)(const FunctionCallbackInfo*);
const FunctionTemplate* v8__FunctionTemplate__New__DEFAULT(
    Isolate* isolate);
const FunctionTemplate* v8__FunctionTemplate__New__DEFAULT2(
    Isolate* isolate,
    FunctionCallback callback_or_null);
const FunctionTemplate* v8__FunctionTemplate__New__DEFAULT3(
    Isolate* isolate,
    FunctionCallback callback_or_null,
    const Value* data);
const ObjectTemplate* v8__FunctionTemplate__InstanceTemplate(
    const FunctionTemplate* self);
const ObjectTemplate* v8__FunctionTemplate__PrototypeTemplate(
    const FunctionTemplate* self);
void v8__FunctionTemplate__Inherit(
    const FunctionTemplate* self,
    const FunctionTemplate* parent);
void v8__FunctionTemplate__SetPrototypeProviderTemplate(
    const FunctionTemplate* self,
    const FunctionTemplate* prototype_provider);
const Function* v8__FunctionTemplate__GetFunction(
    const FunctionTemplate* self, const Context* context);
void v8__FunctionTemplate__SetClassName(
    const FunctionTemplate* self,
    const String* name);
void v8__FunctionTemplate__ReadOnlyPrototype(
    const FunctionTemplate* self);

// Function
const Function* v8__Function__New__DEFAULT(
    const Context* ctx,
    FunctionCallback callback);
const Function* v8__Function__New__DEFAULT2(
    const Context* ctx,
    FunctionCallback callback,
    const Value* data);
const Value* v8__Function__Call(
    const Function* self,
    const Context* context,
    const Value* recv,
    int argc,
    const Value* const argv[]);
const Object* v8__Function__NewInstance(
    const Function* self,
    const Context* context,
    int argc,
    const Value* const argv[]);
const Value* v8__Function__GetName(const Function* self);
void v8__Function__SetName(const Function* self, const String* name);

// External
const External* v8__External__New(
    Isolate* isolate,
    void* value);
void* v8__External__Value(
    const External* self);

// Symbol
const Symbol* v8__Symbol__GetAsyncIterator(Isolate* isolate);
const Symbol* v8__Symbol__GetHasInstance(Isolate* isolate);
const Symbol* v8__Symbol__GetIsConcatSpreadable(Isolate* isolate);
const Symbol* v8__Symbol__GetIterator(Isolate* isolate);
const Symbol* v8__Symbol__GetMatch(Isolate* isolate);
const Symbol* v8__Symbol__GetReplace(Isolate* isolate);
const Symbol* v8__Symbol__GetSearch(Isolate* isolate);
const Symbol* v8__Symbol__GetSplit(Isolate* isolate);
const Symbol* v8__Symbol__GetToPrimitive(Isolate* isolate);
const Symbol* v8__Symbol__GetToStringTag(Isolate* isolate);
const Symbol* v8__Symbol__GetUnscopables(Isolate* isolate);

// Persistent
typedef struct Persistent {
    uintptr_t data_ptr;
} Persistent;
void v8__Persistent__New(
    Isolate* isolate,
    const Data* data,
    Persistent* out);
void v8__Persistent__Reset(
    Persistent* self);
void v8__Persistent__SetWeak(
    Persistent* self);
typedef struct WeakCallbackInfo WeakCallbackInfo;
typedef void (*WeakCallback)(const WeakCallbackInfo*);
typedef enum WeakCallbackType {
    kParameter,
    kInternalFields,
    kFinalizer
} WeakCallbackType;
void v8__Persistent__SetWeakFinalizer(
    Persistent* self,
    void* finalizer_ctx,
    WeakCallback finalizer_cb,
    WeakCallbackType type);

// WeakCallbackInfo
Isolate* v8__WeakCallbackInfo__GetIsolate(const WeakCallbackInfo* self);
void* v8__WeakCallbackInfo__GetParameter(const WeakCallbackInfo* self);
void* v8__WeakCallbackInfo__GetInternalField(
    const WeakCallbackInfo* self,
    int idx);

// ObjectTemplate
typedef struct ObjectTemplate ObjectTemplate;
ObjectTemplate* v8__ObjectTemplate__New__DEFAULT(
    Isolate* isolate);
ObjectTemplate* v8__ObjectTemplate__New(
    Isolate* isolate, const FunctionTemplate* templ);
Object* v8__ObjectTemplate__NewInstance(
    const ObjectTemplate* self, const Context* ctx);
void v8__ObjectTemplate__SetInternalFieldCount(
    const ObjectTemplate* self,
    int value);
void v8__ObjectTemplate__SetAccessorProperty__DEFAULT(
    const ObjectTemplate* self,
    const Name* key,
    const FunctionTemplate* getter);
void v8__ObjectTemplate__SetAccessorProperty__DEFAULT2(
    const ObjectTemplate* self,
    const Name* key,
    const FunctionTemplate* getter,
    const FunctionTemplate* setter);
void v8__ObjectTemplate__SetNativeDataProperty__DEFAULT(
    const ObjectTemplate* self,
    const Name* key,
    AccessorNameGetterCallback getter);
void v8__ObjectTemplate__SetNativeDataProperty__DEFAULT2(
    const ObjectTemplate* self,
    const Name* key,
    AccessorNameGetterCallback getter,
    AccessorNameSetterCallback setter);

typedef enum PropertyHandlerFlags {
       kAllCanRead = 1,
       kNonMasking = 1 << 1,
       kOnlyInterceptStrings = 1 << 2,
} PropertyHandlerFlags;

typedef struct PropertyDescriptor {} PropertyDescriptor;
typedef void (*IndexedPropertyGetterCallback)(uint32_t, const PropertyCallbackInfo*);
typedef void (*IndexedPropertySetterCallback)(uint32_t, const Value*, const PropertyCallbackInfo*);
typedef void (*IndexedPropertyQueryCallback)(uint32_t, const PropertyCallbackInfo*);
typedef void (*IndexedPropertyDeleterCallback)(uint32_t, const PropertyCallbackInfo*);
typedef void (*IndexedPropertyEnumeratorCallback)(const PropertyCallbackInfo*);
typedef void (*IndexedPropertyDefinerCallback)(uint32_t, PropertyDescriptor* desc, const PropertyCallbackInfo*);
typedef void (*IndexedPropertyDescriptorCallback)(uint32_t, const PropertyCallbackInfo*);
typedef struct IndexedPropertyHandlerConfiguration {
    IndexedPropertyGetterCallback getter;
    IndexedPropertySetterCallback setter;
    IndexedPropertyQueryCallback query;
    IndexedPropertyDeleterCallback deleter;
    IndexedPropertyEnumeratorCallback enumerator;
    IndexedPropertyDefinerCallback definer;
    IndexedPropertyDescriptorCallback descriptor;
    const Value* data;
    PropertyHandlerFlags flags;
} IndexedPropertyHandlerConfiguration;
void v8__ObjectTemplate__SetIndexedHandler(
    const ObjectTemplate* self,
    const IndexedPropertyHandlerConfiguration* configuration);

typedef void (*NamedPropertyGetterCallback)(const Name*, const PropertyCallbackInfo*);
typedef void (*NamedPropertySetterCallback)(const Name*, const Value*, const PropertyCallbackInfo*);
typedef void (*NamedPropertyQueryCallback)(const Name*, const PropertyCallbackInfo*);
typedef void (*NamedPropertyDeleterCallback)(const Name*, const PropertyCallbackInfo*);
typedef void (*NamedPropertyEnumeratorCallback)(const PropertyCallbackInfo*);
typedef void (*NamedPropertyDefinerCallback)(const Name*, PropertyDescriptor* desc, const PropertyCallbackInfo*);
typedef void (*NamedPropertyDescriptorCallback)(const Name*, const PropertyCallbackInfo*);
typedef struct NamedPropertyHandlerConfiguration {
    NamedPropertyGetterCallback getter;
    NamedPropertySetterCallback setter;
    NamedPropertyQueryCallback query;
    NamedPropertyDeleterCallback deleter;
    NamedPropertyEnumeratorCallback enumerator;
    NamedPropertyDefinerCallback definer;
    NamedPropertyDescriptorCallback descriptor;
    const Value* data;
    PropertyHandlerFlags flags;
} NamedPropertyHandlerConfiguration;
void v8__ObjectTemplate__SetNamedHandler(
    const ObjectTemplate* self,
    const NamedPropertyHandlerConfiguration* configuration);

// ScriptOrigin
typedef struct ScriptOriginOptions {
    const int flags_;
} ScriptOriginOptions;
typedef struct ScriptOrigin {
    Value* resource_name_;
    int resource_line_offset_;
    int resource_column_offset_;
    ScriptOriginOptions options_;
    int script_id_;
    Value* source_map_url_;
    void* host_defined_options_;
} ScriptOrigin;
void v8__ScriptOrigin__CONSTRUCT(ScriptOrigin* buf, const Value* resource_name);
void v8__ScriptOrigin__CONSTRUCT2(
    ScriptOrigin* buf,
    const Value* resource_name,
    int resource_line_offset,
    int resource_column_offset,
    bool resource_is_shared_cross_origin,
    int script_id,
    const Value* source_map_url,
    bool resource_is_opaque,
    bool is_wasm,
    bool is_module,
    const Data* host_defined_options
);

// ScriptCompiler
typedef struct ScriptCompilerSource {
    String* source_string;

    // Origin information
    Value* resource_name;
    int resource_line_offset;
    int resource_column_offset;
    ScriptOriginOptions resource_options;
    Value* source_map_url;
    Data* host_defined_options;

    // Cached data from previous compilation (if a kConsume*Cache flag is
    // set), or hold newly generated cache data (kProduce*Cache flags) are
    // set when calling a compile method.
    UniquePtr cached_data;
    UniquePtr consume_cache_task;
} ScriptCompilerSource;
typedef enum BufferPolicy {
    BufferNotOwned,
    BufferOwned
} BufferPolicy;
typedef struct ScriptCompilerCachedData {
    const uint8_t* data;
    int length;
    bool rejected;
    BufferPolicy buffer_policy;
} ScriptCompilerCachedData;
size_t v8__ScriptCompiler__Source__SIZEOF();
void v8__ScriptCompiler__Source__CONSTRUCT(
    const String* src,
    ScriptCompilerCachedData* cached_data,
    ScriptCompilerSource* out);
void v8__ScriptCompiler__Source__CONSTRUCT2(
    const String* src,
    const ScriptOrigin* origin,
    ScriptCompilerCachedData* cached_data,
    ScriptCompilerSource* out);
void v8__ScriptCompiler__Source__DESTRUCT(ScriptCompilerSource* self);
size_t v8__ScriptCompiler__CachedData__SIZEOF();
ScriptCompilerCachedData* v8__ScriptCompiler__CachedData__NEW(
    const uint8_t* data,
    int length);
void v8__ScriptCompiler__CachedData__DELETE(ScriptCompilerCachedData* self);
const Module* v8__ScriptCompiler__CompileModule(
    Isolate* isolate,
    ScriptCompilerSource* source,
    CompileOptions options,
    NoCacheReason reason);

// Script
typedef struct Script Script;
Script* v8__Script__Compile(const Context* context, const String* src, const ScriptOrigin* origin);
Value* v8__Script__Run(const Script* script, const Context* context);

// Module
typedef enum ModuleStatus {
    kUninstantiated,
    kInstantiating,
    kInstantiated,
    kEvaluating,
    kEvaluated,
    kErrored
} ModuleStatus;
ModuleStatus v8__Module__GetStatus(const Module* self);
const Value* v8__Module__GetException(const Module* self);
const FixedArray* v8__Module__GetModuleRequests(const Module* self);
typedef const Module* (*ResolveModuleCallback)(
    const Context* ctx, const String* spec,
    const FixedArray* import_assertions, const Module* referrer);
void v8__Module__InstantiateModule(
    const Module* self,
    const Context* ctx,
    ResolveModuleCallback cb,
    MaybeBool* out);
const Value* v8__Module__Evaluate(const Module* self, const Context* ctx);
int v8__Module__GetIdentityHash(const Module* self);
int v8__Module__ScriptId(const Module* self);

// ModuleRequest
typedef Data ModuleRequest;
const String* v8__ModuleRequest__GetSpecifier(const ModuleRequest* self);
int v8__ModuleRequest__GetSourceOffset(const ModuleRequest* self);

// JSON
const Value* v8__JSON__Parse(
    const Context* ctx,
    const String* json);
const String* v8__JSON__Stringify(
    const Context* ctx,
    const Value* val,
    const String* gap);

// Misc.
void v8__base__SetDcheckFunction(void (*func)(const char*, int, const char*));

// Utils

typedef struct {
    const char *ptr;
    uint64_t len;
} CZigString;

// Inspector
// ---------

typedef enum ClientTrustLevel {
  kUntrusted,
  kFullyTrusted,
} ClientTrustLevel;

typedef struct StringView StringView;

// InspectorChannel

typedef struct InspectorChannel InspectorChannel;
typedef struct InspectorChannelImpl {
  void* data;
} InspectorChannelImpl;
InspectorChannelImpl *v8_inspector__Channel__IMPL__CREATE(Isolate *isolate);
void v8_inspector__Channel__IMPL__DELETE(InspectorChannelImpl *self);
void v8_inspector__Channel__IMPL__SET_DATA(InspectorChannelImpl* self, void *data);

void v8_inspector__Channel__IMPL__sendResponse(
    InspectorChannelImpl *self, void *data,
    int callId, char *message, size_t length);
void v8_inspector__Channel__IMPL__sendNotification(
    InspectorChannelImpl *self, void *data,
    char *message, size_t length);
void v8_inspector__Channel__IMPL__flushProtocolNotifications(
    InspectorChannelImpl *self, void *data);

// InspectorClient

typedef struct InspectorClient InspectorClient;
typedef struct InspectorClientImpl {
  void* data;
} InspectorClientImpl;
InspectorClientImpl *v8_inspector__Client__IMPL__CREATE();
void v8_inspector__Client__IMPL__DELETE(InspectorClientImpl *self);
void v8_inspector__Client__IMPL__SET_DATA(InspectorClientImpl* self, void *data);

int64_t v8_inspector__Client__IMPL__generateUniqueId(InspectorClientImpl *self);
void v8_inspector__Client__IMPL__runMessageLoopOnPause(
    InspectorClientImpl *self, int contextGroupId);
void v8_inspector__Client__IMPL__quitMessageLoopOnPause(
    InspectorClientImpl *self);
void v8_inspector__Client__IMPL__runIfWaitingForDebugger(
    InspectorClientImpl *self, int contextGroupId);
void v8_inspector__Client__IMPL__consoleAPIMessage(
    InspectorClientImpl *self, int contextGroupId, MessageErrorLevel level,
    StringView *message, StringView *url, unsigned lineNumber,
    unsigned columnNumber, StackTrace *StackTrace);
const Context* v8_inspector__Client__IMPL__ensureDefaultContextInGroup(
    InspectorClientImpl* self, void* data, int contextGroupId);
char* v8_inspector__Client__IMPL__valueSubtype(
    InspectorClientImpl* self, Value value);
char* v8_inspector__Client__IMPL__descriptionForValueSubtype(
    InspectorClientImpl* self, Context context, Value value);

// RemoteObject
typedef struct RemoteObject RemoteObject;
typedef struct WebDriverValue WebDriverValue;
typedef struct ObjectPreview ObjectPreview;
typedef struct CustomPreview CustomPreview;

// InspectorSession

typedef struct InspectorSession InspectorSession;
void v8_inspector__Session__DELETE(InspectorSession *self);
void v8_inspector__Session__dispatchProtocolMessage(InspectorSession *session, Isolate *isolate, const char* msg, usize msg_len);
RemoteObject* v8_inspector__Session__wrapObject(
    InspectorSession *session, Isolate *isolate,
    const Context* ctx, const Value* val,
    const char *grpname, usize grpname_len, bool generatepreview);

bool v8_inspector__Session__unwrapObject(
    InspectorSession *session,
    const void* allocator,
    CZigString* out_error,
    CZigString in_objectId,
    Value** out_value,
    Context** out_context,
    CZigString* out_objectGroup
);

// Inspector
typedef struct Inspector Inspector;
Inspector* v8_inspector__Inspector__Create(Isolate* isolate, InspectorClientImpl* client);
void v8_inspector__Inspector__DELETE(Inspector *self);

InspectorSession* v8_inspector__Inspector__Connect(
    Inspector *self, int contextGroupId,
    InspectorChannelImpl *channel,
    ClientTrustLevel level);
void v8_inspector__Inspector__ContextCreated(Inspector *self, const char *name,
                                             usize name_len, const char *origin,
                                             usize origin_len,
                                             const char *auxData, const usize auxData_len,
                                             int contextGroupId,
    const Context* context);

// RemoteObject
void v8_inspector__RemoteObject__DELETE(RemoteObject *self);

// RemoteObject - Type
bool v8_inspector__RemoteObject__getType(RemoteObject* self, const void* allocator, CZigString* out_type);
void v8_inspector__RemoteObject__setType(RemoteObject* self, CZigString type);

// RemoteObject - Subtype
bool v8_inspector__RemoteObject__hasSubtype(RemoteObject* self);
bool v8_inspector__RemoteObject__getSubtype(RemoteObject* self, const void* allocator, CZigString* out_subtype);
void v8_inspector__RemoteObject__setSubtype(RemoteObject* self, CZigString subtype);

// RemoteObject - ClassName
bool v8_inspector__RemoteObject__hasClassName(RemoteObject* self);
bool v8_inspector__RemoteObject__getClassName(RemoteObject* self, const void* allocator, CZigString* out_className);
void v8_inspector__RemoteObject__setClassName(RemoteObject* self, CZigString className);

// RemoteObject - Value
bool v8_inspector__RemoteObject__hasValue(RemoteObject* self);
// Commented as these for now as the type should likely be the existing Value TBD
// v8_inspector::protocol::Value* v8_inspector__RemoteObject__getValue(Rem;eObject* self);
// void v8_inspector__RemoteObject__setValue(RemoteObject* self, v8_inspector::protocol::Value* value);

//RemoteObject - UnserializableValue
bool v8_inspector__RemoteObject__hasUnserializableValue(RemoteObject* self);
bool v8_inspector__RemoteObject__getUnserializableValue(RemoteObject* self, const void* allocator, CZigString* out_unserializableValue);
void v8_inspector__RemoteObject__setUnserializableValue(RemoteObject* self, CZigString unserializableValue);

// RemoteObject - Description
bool v8_inspector__RemoteObject__hasDescription(RemoteObject* self);
bool v8_inspector__RemoteObject__getDescription(RemoteObject* self, const void* allocator, CZigString* out_description);
void v8_inspector__RemoteObject__setDescription(RemoteObject* self, CZigString description);

// RemoteObject - WebDriverValue
bool v8_inspector__RemoteObject__hasWebDriverValue(RemoteObject* self);
WebDriverValue* v8_inspector__RemoteObject__getWebDriverValue(RemoteObject* self);
void v8_inspector__RemoteObject__setWebDriverValue(RemoteObject* self, WebDriverValue* webDriverValue);

// RemoteObject - ObjectId
bool v8_inspector__RemoteObject__hasObjectId(RemoteObject* self);
bool v8_inspector__RemoteObject__getObjectId(RemoteObject* self, const void* allocator, CZigString* out_objectId);
void v8_inspector__RemoteObject__setObjectId(RemoteObject* self, CZigString objectId);

// RemoteObject - Preview
bool v8_inspector__RemoteObject__hasPreview(RemoteObject* self);
const ObjectPreview* v8_inspector__RemoteObject__getPreview(RemoteObject* self);
void v8_inspector__RemoteObject__setPreview(RemoteObject* self, ObjectPreview* preview);

// RemoteObject - CustomPreview
bool v8_inspector__RemoteObject__hasCustomPreview(RemoteObject* self);
const CustomPreview* v8_inspector__RemoteObject__getCustomPreview(RemoteObject* self);
void v8_inspector__RemoteObject__setCustomPreview(RemoteObject* self, CustomPreview* customPreview);
