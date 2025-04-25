// Based on https://github.com/denoland/rusty_v8/blob/main/src/binding.cc

#include <cassert>
#include "include/libplatform/libplatform.h"
#include "include/v8-inspector.h"
#include "include/v8.h"
#include "src/api/api.h"
#include "src/inspector/protocol/Runtime.h"
#include "src/inspector/v8-string-conversions.h"
#include "src/debug/debug-interface.h"

#include "inspector.h"

template <class T, class... Args>
class Wrapper {
    public:
        Wrapper(T* buf, Args... args) : inner_(args...) {}
    private:
        T inner_;
};

template <class T, class... Args>
void construct_in_place(T* buf, Args... args) {
    new (buf) Wrapper<T, Args...>(buf, std::forward<Args>(args)...);
}

template <class T>
inline static T* local_to_ptr(v8::Local<T> local) {
    return *local;
}

template <class T>
inline static const v8::Local<T> ptr_to_local(const T* ptr) {
    static_assert(sizeof(v8::Local<T>) == sizeof(T*), "");
    auto local = *reinterpret_cast<const v8::Local<T>*>(&ptr);
    assert(*local == ptr);
    return local;
}

template <class T>
inline static const v8::MaybeLocal<T> ptr_to_maybe_local(const T* ptr) {
    static_assert(sizeof(v8::MaybeLocal<T>) == sizeof(T*), "");
    return *reinterpret_cast<const v8::MaybeLocal<T>*>(&ptr);
}

template <class T>
inline static T* maybe_local_to_ptr(v8::MaybeLocal<T> local) {
    return *local.FromMaybe(v8::Local<T>());
}

template <class T>
inline static v8::Local<T>* const_ptr_array_to_local_array(
        const T* const ptr_array[]) {
    static_assert(sizeof(v8::Local<T>) == sizeof(T*), "");
    auto mut_ptr_array = const_cast<T**>(ptr_array);
    auto mut_local_array = reinterpret_cast<v8::Local<T>*>(mut_ptr_array);
    return mut_local_array;
}

struct SharedPtr {
    void* a;
    void* b;
};

// The destructor of V is never called.
// P is not allowed to have a destructor.
template <class P>
struct make_pod {
    template <class V>
    inline make_pod(V&& value) : pod_(helper<V>(std::move(value))) {}
    template <class V>
    inline make_pod(const V& value) : pod_(helper<V>(value)) {}
    inline operator P() { return pod_; }

    private:
        P pod_;

    // This helper exists to avoid calling the destructor.
    // Using a union is a C++ trick to achieve this.
    template <class V>
    union helper {
        static_assert(std::is_trivial<P>::value && std::is_standard_layout<P>::value, "type P must a pod type");
        static_assert(sizeof(V) == sizeof(P), "type P must be same size as type V");
        static_assert(alignof(V) == alignof(P), "alignment of type P must be compatible with that of type V");

        inline helper(V&& value) : value_(std::move(value)) {}
        inline helper(const V& value) : value_(value) {}
        inline ~helper() {}

        inline operator P() {
            // Do a memcpy here avoid undefined behavior.
            P result;
            memcpy(&result, this, sizeof result);
            return result;
        }

        private:
            V value_;
    };
};

extern "C" {

// Platform

v8::Platform* v8__Platform__NewDefaultPlatform(
        int thread_pool_size,
        bool idle_task_support) {
    return v8::platform::NewDefaultPlatform(
        thread_pool_size,
        idle_task_support ? v8::platform::IdleTaskSupport::kEnabled : v8::platform::IdleTaskSupport::kDisabled,
        v8::platform::InProcessStackDumping::kDisabled,
        nullptr
    ).release();
}

void v8__Platform__DELETE(v8::Platform* self) { delete self; }

bool v8__Platform__PumpMessageLoop(
        v8::Platform* platform,
        v8::Isolate* isolate,
        bool wait_for_work) {
    return v8::platform::PumpMessageLoop(
        platform, isolate,
        wait_for_work ? v8::platform::MessageLoopBehavior::kWaitForWork : v8::platform::MessageLoopBehavior::kDoNotWait);
}

// Root

const v8::Primitive* v8__Undefined(v8::Isolate* isolate) {
    return local_to_ptr(v8::Undefined(isolate));
}

const v8::Primitive* v8__Null(v8::Isolate* isolate) {
    return local_to_ptr(v8::Null(isolate));
}

const v8::Boolean* v8__True(v8::Isolate* isolate) {
    return local_to_ptr(v8::True(isolate));
}

const v8::Boolean* v8__False(v8::Isolate* isolate) {
    return local_to_ptr(v8::False(isolate));
}

const v8::Uint8Array* v8__Uint8Array__New(
        const v8::ArrayBuffer& buf,
        size_t byte_offset,
        size_t length) {
    return local_to_ptr(
        v8::Uint8Array::New(ptr_to_local(&buf), byte_offset, length)
    );
}

// V8

const char* v8__V8__GetVersion() { return v8::V8::GetVersion(); }

void v8__V8__InitializePlatform(v8::Platform* platform) {
    v8::V8::InitializePlatform(platform);
}

void v8__V8__Initialize() { v8::V8::Initialize(); }

bool v8__V8__InitializeICU() { return v8::V8::InitializeICU(); }

int v8__V8__Dispose() { return v8::V8::Dispose(); }

void v8__V8__DisposePlatform() { v8::V8::DisposePlatform(); }

// Isolate

v8::Isolate* v8__Isolate__New(const v8::Isolate::CreateParams& params) {
    return v8::Isolate::New(params);
}

void v8__Isolate__Dispose(v8::Isolate* isolate) { isolate->Dispose(); }

void v8__Isolate__Enter(v8::Isolate* isolate) { isolate->Enter(); }

void v8__Isolate__Exit(v8::Isolate* isolate) { isolate->Exit(); }

const v8::Context* v8__Isolate__GetCurrentContext(v8::Isolate* isolate) {
    return local_to_ptr(isolate->GetCurrentContext());
}

size_t v8__Isolate__CreateParams__SIZEOF() {
    return sizeof(v8::Isolate::CreateParams);
}

void v8__Isolate__CreateParams__CONSTRUCT(v8::Isolate::CreateParams* buf) {
    // Use in place new constructor otherwise special fields like shared_ptr will attempt to do copy and fail if the buffer had undefined values.
    new (buf) v8::Isolate::CreateParams();
}

const v8::Value* v8__Isolate__ThrowException(
        v8::Isolate* isolate,
        const v8::Value& exception) {
    return local_to_ptr(isolate->ThrowException(ptr_to_local(&exception)));
}

void v8__Isolate__SetPromiseRejectCallback(
        v8::Isolate* isolate,
        v8::PromiseRejectCallback callback) {
    isolate->SetPromiseRejectCallback(callback);
}

v8::MicrotasksPolicy v8__Isolate__GetMicrotasksPolicy(const v8::Isolate* self) {
    return self->GetMicrotasksPolicy();
}

void v8__Isolate__SetMicrotasksPolicy(
        v8::Isolate* self,
        v8::MicrotasksPolicy policy) {
    self->SetMicrotasksPolicy(policy);
}

void v8__Isolate__PerformMicrotaskCheckpoint(v8::Isolate* self) {
    self->PerformMicrotaskCheckpoint();
}

bool v8__Isolate__AddMessageListener(
        v8::Isolate* self,
        v8::MessageCallback callback) {
    return self->AddMessageListener(callback);
}

bool v8__Isolate__AddMessageListenerWithErrorLevel(
        v8::Isolate* self,
        v8::MessageCallback callback,
        int message_levels,
        const v8::Value& data) {
    return self->AddMessageListenerWithErrorLevel(callback, message_levels, ptr_to_local(&data));
}

void v8__Isolate__SetCaptureStackTraceForUncaughtExceptions(
        v8::Isolate* isolate,
        bool capture,
        int frame_limit) {
    isolate->SetCaptureStackTraceForUncaughtExceptions(capture, frame_limit);
}

void v8__Isolate__TerminateExecution(v8::Isolate* self) {
    self->TerminateExecution();
}

bool v8__Isolate__IsExecutionTerminating(v8::Isolate* self) {
    return self->IsExecutionTerminating();
}

void v8__Isolate__CancelTerminateExecution(v8::Isolate* self) {
    self->CancelTerminateExecution();
}

void v8__Isolate__LowMemoryNotification(v8::Isolate* self) {
    self->LowMemoryNotification();
}

void v8__Isolate__GetHeapStatistics(
        v8::Isolate* self,
        v8::HeapStatistics* stats) {
    self->GetHeapStatistics(stats);
}

void* v8__Isolate__GetData(v8::Isolate* self, int idx) {
    return self->GetData(idx);
}

void v8__Isolate__SetData(v8::Isolate* self, int idx, void* val) {
    self->SetData(idx, val);
}

size_t v8__HeapStatistics__SIZEOF() {
    return sizeof(v8::HeapStatistics);
}

// ArrayBuffer

v8::ArrayBuffer::Allocator* v8__ArrayBuffer__Allocator__NewDefaultAllocator() {
    return v8::ArrayBuffer::Allocator::NewDefaultAllocator();
}

void v8__ArrayBuffer__Allocator__DELETE(v8::ArrayBuffer::Allocator* self) { delete self; }

v8::BackingStore* v8__ArrayBuffer__NewBackingStore(
        v8::Isolate* isolate,
        size_t byte_len) {
    std::unique_ptr<v8::BackingStore> store = v8::ArrayBuffer::NewBackingStore(isolate, byte_len);
    return store.release();
}

v8::BackingStore* v8__ArrayBuffer__NewBackingStore2(
        void* data,
        size_t byte_len,
        v8::BackingStoreDeleterCallback deleter,
        void* deleter_data) {
    std::unique_ptr<v8::BackingStore> store = v8::ArrayBuffer::NewBackingStore(data, byte_len, deleter, deleter_data);
    return store.release();
}

void* v8__BackingStore__Data(const v8::BackingStore& self) { return self.Data(); }

size_t v8__BackingStore__ByteLength(const v8::BackingStore& self) { return self.ByteLength(); }

bool v8__BackingStore__IsShared(const v8::BackingStore& self) { return self.IsShared(); }

SharedPtr v8__BackingStore__TO_SHARED_PTR(v8::BackingStore* unique_ptr) {
    return make_pod<SharedPtr>(std::shared_ptr<v8::BackingStore>(unique_ptr));
}

void std__shared_ptr__v8__BackingStore__reset(std::shared_ptr<v8::BackingStore>* self) { self->reset(); }

v8::BackingStore* std__shared_ptr__v8__BackingStore__get(const std::shared_ptr<v8::BackingStore>& self) { return self.get(); }

long std__shared_ptr__v8__BackingStore__use_count(const std::shared_ptr<v8::BackingStore>& self) { return self.use_count(); }

const v8::ArrayBuffer* v8__ArrayBuffer__New(
        v8::Isolate* isolate, size_t byte_len) {
    return local_to_ptr(v8::ArrayBuffer::New(isolate, byte_len));
}

const v8::ArrayBuffer* v8__ArrayBuffer__New2(
        v8::Isolate* isolate,
        const std::shared_ptr<v8::BackingStore>& backing_store) {
    return local_to_ptr(v8::ArrayBuffer::New(isolate, backing_store));
}

size_t v8__ArrayBuffer__ByteLength(const v8::ArrayBuffer& self) { return self.ByteLength(); }

SharedPtr v8__ArrayBuffer__GetBackingStore(const v8::ArrayBuffer& self) {
    return make_pod<SharedPtr>(ptr_to_local(&self)->GetBackingStore());
}

// ArrayBufferView

const v8::ArrayBuffer* v8__ArrayBufferView__Buffer(const v8::ArrayBufferView& self) {
    return local_to_ptr(ptr_to_local(&self)->Buffer());
}

// HandleScope

void v8__HandleScope__CONSTRUCT(v8::HandleScope* buf, v8::Isolate* isolate) {
    // We can't do in place new, since new is overloaded for HandleScope.
    // Use in place construct instead.
    construct_in_place<v8::HandleScope>(buf, isolate);
}

void v8__HandleScope__DESTRUCT(v8::HandleScope* scope) { scope->~HandleScope(); }

// Context

v8::Context* v8__Context__New(
        v8::Isolate* isolate,
        const v8::ObjectTemplate* global_tmpl,
        const v8::Value* global_obj) {
    return local_to_ptr(
        v8::Context::New(isolate, nullptr, ptr_to_maybe_local(global_tmpl), ptr_to_maybe_local(global_obj))
    );
}

void v8__Context__Enter(const v8::Context& context) { ptr_to_local(&context)->Enter(); }

void v8__Context__Exit(const v8::Context& context) { ptr_to_local(&context)->Exit(); }

v8::Isolate* v8__Context__GetIsolate(const v8::Context& self) {
       return ptr_to_local(&self)->GetIsolate();
}

const v8::Object* v8__Context__Global(
        const v8::Context& self) {
    return local_to_ptr(ptr_to_local(&self)->Global());
}

const v8::Value* v8__Context__GetEmbedderData(
        const v8::Context& self,
        int idx) {
    return local_to_ptr(ptr_to_local(&self)->GetEmbedderData(idx));
}

void v8__Context__SetEmbedderData(
        const v8::Context& self,
        int idx,
        const v8::Value& val) {
    ptr_to_local(&self)->SetEmbedderData(idx, ptr_to_local(&val));
}

int v8__Context__DebugContextId(const v8::Context& self) {
    return v8::debug::GetContextId(ptr_to_local(&self));
}

// ScriptOrigin

void v8__ScriptOrigin__CONSTRUCT(
        v8::ScriptOrigin* buf,
        const v8::Value& resource_name) {
    new (buf) v8::ScriptOrigin(ptr_to_local(&resource_name));
}

void v8__ScriptOrigin__CONSTRUCT2(
        v8::ScriptOrigin* buf,
        const v8::Value& resource_name,
        int resource_line_offset,
        int resource_column_offset,
        bool resource_is_shared_cross_origin,
        int script_id,
        const v8::Value& source_map_url,
        bool resource_is_opaque,
        bool is_wasm,
        bool is_module,
        const v8::Data& host_defined_options) {
    new (buf) v8::ScriptOrigin(
        ptr_to_local(&resource_name),
        resource_line_offset, resource_column_offset, resource_is_shared_cross_origin, script_id,
        ptr_to_local(&source_map_url), resource_is_opaque, is_wasm, is_module, ptr_to_local(&host_defined_options)
    );
}

// Script

v8::Script* v8__Script__Compile(
        const v8::Context& context,
        const v8::String& src,
        const v8::ScriptOrigin& origin) {
    return maybe_local_to_ptr(
        v8::Script::Compile(ptr_to_local(&context), ptr_to_local(&src), const_cast<v8::ScriptOrigin*>(&origin))
    );
}

v8::Value* v8__Script__Run(
        const v8::Script& script,
        const v8::Context& context) {
    return maybe_local_to_ptr(ptr_to_local(&script)->Run(ptr_to_local(&context)));
}

// ScriptCompiler

size_t v8__ScriptCompiler__Source__SIZEOF() {
    return sizeof(v8::ScriptCompiler::Source);
}

void v8__ScriptCompiler__Source__CONSTRUCT(
        const v8::String& src,
        v8::ScriptCompiler::CachedData* cached_data,
        v8::ScriptCompiler::Source* out) {
    new (out) v8::ScriptCompiler::Source(ptr_to_local(&src), cached_data);
}

void v8__ScriptCompiler__Source__CONSTRUCT2(
        const v8::String& src,
        const v8::ScriptOrigin* origin,
        v8::ScriptCompiler::CachedData* cached_data,
        v8::ScriptCompiler::Source* out) {
    new (out) v8::ScriptCompiler::Source(ptr_to_local(&src), *origin, cached_data);
}

void v8__ScriptCompiler__Source__DESTRUCT(v8::ScriptCompiler::Source* self) {
    self->~Source();
}

size_t v8__ScriptCompiler__CachedData__SIZEOF() {
    return sizeof(v8::ScriptCompiler::CachedData);
}

v8::ScriptCompiler::CachedData* v8__ScriptCompiler__CachedData__NEW(
        const uint8_t* data,
        int length) {
    return new v8::ScriptCompiler::CachedData(
        data, length, v8::ScriptCompiler::CachedData::BufferNotOwned
    );
}

void v8__ScriptCompiler__CachedData__DELETE(v8::ScriptCompiler::CachedData* self) {
    delete self;
}

const v8::Module* v8__ScriptCompiler__CompileModule(
        v8::Isolate* isolate,
        v8::ScriptCompiler::Source* source,
        v8::ScriptCompiler::CompileOptions options,
        v8::ScriptCompiler::NoCacheReason reason) {
    v8::MaybeLocal<v8::Module> maybe_local = v8::ScriptCompiler::CompileModule(isolate, source, options, reason);
    return maybe_local_to_ptr(maybe_local);
}

// Module

v8::Module::Status v8__Module__GetStatus(const v8::Module& self) {
    return self.GetStatus();
}

const v8::Value* v8__Module__GetException(const v8::Module& self) {
    return local_to_ptr(self.GetException());
}

const v8::FixedArray* v8__Module__GetModuleRequests(const v8::Module& self) {
    return local_to_ptr(self.GetModuleRequests());
}

void v8__Module__InstantiateModule(
        const v8::Module& self,
        const v8::Context& ctx,
        v8::Module::ResolveModuleCallback cb,
        v8::Maybe<bool>* out) {
    *out = ptr_to_local(&self)->InstantiateModule(ptr_to_local(&ctx), cb);
}

const v8::Value* v8__Module__Evaluate(
        const v8::Module& self,
        const v8::Context& ctx) {
    return maybe_local_to_ptr(ptr_to_local(&self)->Evaluate(ptr_to_local(&ctx)));
}

int v8__Module__GetIdentityHash(const v8::Module& self) {
    return self.GetIdentityHash();
}

int v8__Module__ScriptId(const v8::Module& self) {
    return self.ScriptId();
}

// ModuleRequest

const v8::String* v8__ModuleRequest__GetSpecifier(const v8::ModuleRequest& self) {
    return local_to_ptr(self.GetSpecifier());
}

int v8__ModuleRequest__GetSourceOffset(const v8::ModuleRequest& self) {
    return self.GetSourceOffset();
}

// FixedArray

int v8__FixedArray__Length(const v8::FixedArray& self) {
    return self.Length();
}

const v8::Data* v8__FixedArray__Get(
        const v8::FixedArray& self,
        const v8::Context& ctx,
        int idx) {
    return local_to_ptr(ptr_to_local(&self)->Get(ptr_to_local(&ctx), idx));
}

// String

v8::String* v8__String__NewFromUtf8(
        v8::Isolate* isolate,
        const char* data,
        v8::NewStringType type,
        int length) {
    return maybe_local_to_ptr(
        v8::String::NewFromUtf8(isolate, data, type, length)
    );
}

size_t v8__String__WriteUtf8(
        const v8::String& str,
        v8::Isolate* isolate,
        char* buffer,
        size_t length,
        int options) {
    return str.WriteUtf8V2(isolate, buffer, length, options);
}

int v8__String__Utf8Length(const v8::String& self, v8::Isolate* isolate) {
    return self.Utf8LengthV2(isolate);
}

// Boolean

const v8::Boolean* v8__Boolean__New(
        v8::Isolate* isolate,
        bool value) {
    return local_to_ptr(v8::Boolean::New(isolate, value));
}

// Number

const v8::Number* v8__Number__New(
        v8::Isolate* isolate,
        double value) {
    return *v8::Number::New(isolate, value);
}

// Integer

const v8::Integer* v8__Integer__New(
        v8::Isolate* isolate,
        int32_t value) {
    return *v8::Integer::New(isolate, value);
}

const v8::Integer* v8__Integer__NewFromUnsigned(
        v8::Isolate* isolate,
        uint32_t value) {
    return *v8::Integer::NewFromUnsigned(isolate, value);
}

int64_t v8__Integer__Value(const v8::Integer& self) { return self.Value(); }

// BigInt

const v8::BigInt* v8__BigInt__New(
        v8::Isolate* iso,
        int64_t val) {
    return local_to_ptr(v8::BigInt::New(iso, val));
}

const v8::BigInt* v8__BigInt__NewFromUnsigned(
        v8::Isolate* iso,
        uint64_t val) {
    return local_to_ptr(v8::BigInt::NewFromUnsigned(iso, val));
}

uint64_t v8__BigInt__Uint64Value(
        const v8::BigInt& self,
        bool* lossless) {
    return ptr_to_local(&self)->Uint64Value(lossless);
}

int64_t v8__BigInt__Int64Value(
        const v8::BigInt& self,
        bool* lossless) {
    return ptr_to_local(&self)->Int64Value(lossless);
}

// Promise

const v8::Promise::Resolver* v8__Promise__Resolver__New(
        const v8::Context& ctx) {
    return maybe_local_to_ptr(
        v8::Promise::Resolver::New(ptr_to_local(&ctx))
    );
}

const v8::Promise* v8__Promise__Resolver__GetPromise(
        const v8::Promise::Resolver& self) {
    return local_to_ptr(ptr_to_local(&self)->GetPromise());
}

void v8__Promise__Resolver__Resolve(
        const v8::Promise::Resolver& self,
        const v8::Context& ctx,
        const v8::Value& value,
        v8::Maybe<bool>* out) {
    *out = ptr_to_local(&self)->Resolve(
        ptr_to_local(&ctx), ptr_to_local(&value)
    );
}

void v8__Promise__Resolver__Reject(
        const v8::Promise::Resolver& self,
        const v8::Context& ctx,
        const v8::Value& value,
        v8::Maybe<bool>* out) {
    *out = ptr_to_local(&self)->Reject(
        ptr_to_local(&ctx),
        ptr_to_local(&value)
    );
}

const v8::Promise* v8__Promise__Catch(
        const v8::Promise& self,
        const v8::Context& ctx,
        const v8::Function& handler) {
    return maybe_local_to_ptr(
        ptr_to_local(&self)->Catch(ptr_to_local(&ctx), ptr_to_local(&handler))
    );
}

const v8::Promise* v8__Promise__Then(
        const v8::Promise& self,
        const v8::Context& ctx,
        const v8::Function& handler) {
    return maybe_local_to_ptr(
        ptr_to_local(&self)->Then(ptr_to_local(&ctx), ptr_to_local(&handler))
    );
}

const v8::Promise* v8__Promise__Then2(
        const v8::Promise& self,
        const v8::Context& ctx,
        const v8::Function& on_fulfilled,
        const v8::Function& on_rejected) {
    return maybe_local_to_ptr(
        ptr_to_local(&self)->Then(
            ptr_to_local(&ctx),
            ptr_to_local(&on_fulfilled),
            ptr_to_local(&on_rejected)
        )
    );
}

v8::Promise::PromiseState v8__Promise__State(const v8::Promise& self) {
    return ptr_to_local(&self)->State();
}

void v8__Promise__MarkAsHandled(const v8::Promise& self) {
    ptr_to_local(&self)->MarkAsHandled();
}

const v8::Value* v8__Promise__Result(const v8::Promise& self) {
    return local_to_ptr(ptr_to_local(&self)->Result());
}

// Value

const v8::String* v8__Value__TypeOf(
        v8::Value& self,
        v8::Isolate* isolate) {
    return local_to_ptr(self.TypeOf(isolate));
}

const v8::String* v8__Value__ToString(
        const v8::Value& self,
        const v8::Context& ctx) {
    return maybe_local_to_ptr(self.ToString(ptr_to_local(&ctx)));
}

const v8::String* v8__Value__ToDetailString(
        const v8::Value& self,
        const v8::Context& ctx) {
    return maybe_local_to_ptr(self.ToDetailString(ptr_to_local(&ctx)));
}

bool v8__Value__BooleanValue(
        const v8::Value& self,
        v8::Isolate* isolate) {
    return self.BooleanValue(isolate);
}

void v8__Value__Uint32Value(
        const v8::Value& self,
        const v8::Context& ctx,
        v8::Maybe<uint32_t>* out) {
    *out = self.Uint32Value(ptr_to_local(&ctx));
}

void v8__Value__Int32Value(
        const v8::Value& self,
        const v8::Context& ctx,
        v8::Maybe<int32_t>* out) {
    *out = self.Int32Value(ptr_to_local(&ctx));
}

void v8__Value__NumberValue(
        const v8::Value& self,
        const v8::Context& ctx,
        v8::Maybe<double>* out) {
    *out = self.NumberValue(ptr_to_local(&ctx));
}

bool v8__Value__IsFunction(const v8::Value& self) { return self.IsFunction(); }

bool v8__Value__IsAsyncFunction(const v8::Value& self) { return self.IsAsyncFunction(); }

bool v8__Value__IsObject(const v8::Value& self) { return self.IsObject(); }

bool v8__Value__IsString(const v8::Value& self) { return self.IsString(); }

bool v8__Value__IsArray(const v8::Value& self) { return self.IsArray(); }

bool v8__Value__IsTypedArray(const v8::Value& self) { return self.IsTypedArray(); }

bool v8__Value__IsUint8Array(const v8::Value& self) { return self.IsUint8Array(); }

bool v8__Value__IsUint8ClampedArray(const v8::Value& self) { return self.IsUint8ClampedArray(); }

bool v8__Value__IsInt8Array(const v8::Value& self) { return self.IsInt8Array(); }

bool v8__Value__IsUint16Array(const v8::Value& self) { return self.IsUint16Array(); }

bool v8__Value__IsInt16Array(const v8::Value& self) { return self.IsInt16Array(); }

bool v8__Value__IsUint32Array(const v8::Value& self) { return self.IsUint32Array(); }

bool v8__Value__IsInt32Array(const v8::Value& self) { return self.IsInt32Array(); }

bool v8__Value__IsFloat32Array(const v8::Value& self) { return self.IsFloat32Array(); }

bool v8__Value__IsFloat64Array(const v8::Value& self) { return self.IsFloat64Array(); }

bool v8__Value__IsArrayBuffer(const v8::Value& self) { return self.IsArrayBuffer(); }

bool v8__Value__IsArrayBufferView(const v8::Value& self) { return self.IsArrayBufferView(); }

bool v8__Value__IsExternal(const v8::Value& self) { return self.IsExternal(); }

bool v8__Value__IsTrue(const v8::Value& self) { return self.IsTrue(); }

bool v8__Value__IsFalse(const v8::Value& self) { return self.IsFalse(); }

bool v8__Value__IsUndefined(const v8::Value& self) { return self.IsUndefined(); }

bool v8__Value__IsNull(const v8::Value& self) { return self.IsNull(); }

bool v8__Value__IsNullOrUndefined(const v8::Value& self) { return self.IsNullOrUndefined(); }

bool v8__Value__IsNativeError(const v8::Value& self) { return self.IsNativeError(); }

bool v8__Value__IsBigInt(const v8::Value& self) {
    return self.IsBigInt();
}

bool v8__Value__IsBigIntObject(const v8::Value& self) {
    return self.IsBigIntObject();
}

void v8__Value__InstanceOf(
        const v8::Value& self,
        const v8::Context& ctx,
        const v8::Object& object,
        v8::Maybe<bool>* out) {
    *out = ptr_to_local(&self)->InstanceOf(ptr_to_local(&ctx), ptr_to_local(&object));
}

// Template

void v8__Template__Set(
        const v8::Template& self,
        const v8::Name& key,
        const v8::Data& value,
        v8::PropertyAttribute attr) {
    ptr_to_local(&self)->Set(ptr_to_local(&key), ptr_to_local(&value), attr);
}

void v8__Template__SetAccessorProperty__DEFAULT(
        const v8::Template& self,
        const v8::Name& key,
        const v8::FunctionTemplate& getter) {
    ptr_to_local(&self)->SetAccessorProperty(ptr_to_local(&key), ptr_to_local(&getter));
}

// ObjectTemplate

const v8::ObjectTemplate* v8__ObjectTemplate__New__DEFAULT(
        v8::Isolate* isolate) {
    return local_to_ptr(v8::ObjectTemplate::New(isolate));
}

const v8::ObjectTemplate* v8__ObjectTemplate__New(
        v8::Isolate* isolate, const v8::FunctionTemplate& constructor) {
    return local_to_ptr(v8::ObjectTemplate::New(isolate, ptr_to_local(&constructor)));
}

const v8::Object* v8__ObjectTemplate__NewInstance(
        const v8::ObjectTemplate& self, const v8::Context& ctx) {
    return maybe_local_to_ptr(
        ptr_to_local(&self)->NewInstance(ptr_to_local(&ctx))
    );
}

void v8__ObjectTemplate__SetInternalFieldCount(
        const v8::ObjectTemplate& self,
        int value) {
    ptr_to_local(&self)->SetInternalFieldCount(value);
}

void v8__ObjectTemplate__SetIndexedHandler(
        const v8::ObjectTemplate& self,
        const v8::IndexedPropertyHandlerConfiguration& configuration) {
    ptr_to_local(&self)->SetHandler(configuration);
}

void v8__ObjectTemplate__SetNamedHandler(
        const v8::ObjectTemplate& self,
        const v8::NamedPropertyHandlerConfiguration& configuration) {
    ptr_to_local(&self)->SetHandler(configuration);
}

void v8__ObjectTemplate__SetAccessorProperty__DEFAULT(
        const v8::ObjectTemplate& self,
        const v8::Name& key,
        const v8::FunctionTemplate& getter) {
    ptr_to_local(&self)->SetAccessorProperty(ptr_to_local(&key), ptr_to_local(&getter));
}

void v8__ObjectTemplate__SetAccessorProperty__DEFAULT2(
        const v8::ObjectTemplate& self,
        const v8::Name& key,
        const v8::FunctionTemplate& getter,
        const v8::FunctionTemplate& setter) {
    ptr_to_local(&self)->SetAccessorProperty(ptr_to_local(&key), ptr_to_local(&getter), ptr_to_local(&setter));
}

void v8__ObjectTemplate__SetNativeDataProperty__DEFAULT(
        const v8::ObjectTemplate& self,
        const v8::Name& key,
        const v8::AccessorNameGetterCallback getter) {
    ptr_to_local(&self)->SetNativeDataProperty(ptr_to_local(&key), getter);
}

void v8__ObjectTemplate__SetNativeDataProperty__DEFAULT2(
        const v8::ObjectTemplate& self,
        const v8::Name& key,
        const v8::AccessorNameGetterCallback getter,
        const v8::AccessorNameSetterCallback setter) {
    ptr_to_local(&self)->SetNativeDataProperty(ptr_to_local(&key), getter, setter);
}

// Array

const v8::Array* v8__Array__New(
        v8::Isolate* isolate,
        int length) {
    return local_to_ptr(v8::Array::New(isolate, length));
}

const v8::Array* v8__Array__New2(
        v8::Isolate* isolate,
        const v8::Value* const elements[],
        size_t length) {
    return local_to_ptr(
        v8::Array::New(isolate, const_ptr_array_to_local_array(elements), length)
    );
}

uint32_t v8__Array__Length(const v8::Array& self) { return self.Length(); }

// Object

const v8::Object* v8__Object__New(
        v8::Isolate* isolate) {
    return local_to_ptr(v8::Object::New(isolate));
}

const v8::String* v8__Object__GetConstructorName(
        const v8::Object& self) {
  return local_to_ptr(ptr_to_local(&self)->GetConstructorName());
}

void v8__Object__SetInternalField(
        const v8::Object& self,
        int index,
        const v8::Value& value) {
    ptr_to_local(&self)->SetInternalField(index, ptr_to_local(&value));
}

const v8::Data* v8__Object__GetInternalField(
        const v8::Object& self,
        int index) {
    return local_to_ptr(ptr_to_local(&self)->GetInternalField(index));
}

int v8__Object__InternalFieldCount(
        const v8::Object& self) {
    return ptr_to_local(&self)->InternalFieldCount();
}

const v8::Value* v8__Object__Get(
        const v8::Object& self,
        const v8::Context& ctx,
        const v8::Value& key) {
    return maybe_local_to_ptr(
        ptr_to_local(&self)->Get(ptr_to_local(&ctx), ptr_to_local(&key))
    );
}

const v8::Value* v8__Object__GetIndex(
        const v8::Object& self,
        const v8::Context& ctx,
        uint32_t idx) {
    return maybe_local_to_ptr(
        ptr_to_local(&self)->Get(ptr_to_local(&ctx), idx)
    );
}

void v8__Object__Set(
        const v8::Object& self,
        const v8::Context& ctx,
        const v8::Value& key,
        const v8::Value& value,
        v8::Maybe<bool>* out) {
    *out = ptr_to_local(&self)->Set(
        ptr_to_local(&ctx),
        ptr_to_local(&key),
        ptr_to_local(&value)
    );
}

void v8__Object__Delete(
        const v8::Object& self,
        const v8::Context& ctx,
        const v8::Value& key,
        v8::Maybe<bool>* out) {
    *out = ptr_to_local(&self)->Delete(
        ptr_to_local(&ctx),
        ptr_to_local(&key)
    );
}

void v8__Object__SetAtIndex(
        const v8::Object& self,
        const v8::Context& ctx,
        uint32_t idx,
        const v8::Value& value,
        v8::Maybe<bool>* out) {
    *out = ptr_to_local(&self)->Set(
        ptr_to_local(&ctx),
        idx,
        ptr_to_local(&value)
    );
}

void v8__Object__DefineOwnProperty(
        const v8::Object& self,
        const v8::Context& ctx,
        const v8::Name& key,
        const v8::Value& value,
        v8::PropertyAttribute attr,
        v8::Maybe<bool>* out) {
    *out = ptr_to_local(&self)->DefineOwnProperty(
        ptr_to_local(&ctx),
        ptr_to_local(&key),
        ptr_to_local(&value),
        attr
    );
}

v8::Isolate* v8__Object__GetIsolate(const v8::Object& self) {
    return ptr_to_local(&self)->GetIsolate();
}

const v8::Context* v8__Object__GetCreationContext(const v8::Object& self) {
    return maybe_local_to_ptr(ptr_to_local(&self)->GetCreationContext());
}

int v8__Object__GetIdentityHash(const v8::Object& self) {
    return ptr_to_local(&self)->GetIdentityHash();
}

void v8__Object__Has(
        const v8::Object& self,
        const v8::Context& ctx,
        const v8::Value& key,
        v8::Maybe<bool>* out) {
    *out = ptr_to_local(&self)->Has(
        ptr_to_local(&ctx), ptr_to_local(&key)
    );
}

void v8__Object__HasIndex(
        const v8::Object& self,
        const v8::Context& ctx,
        uint32_t idx,
        v8::Maybe<bool>* out) {
    *out = ptr_to_local(&self)->Has(ptr_to_local(&ctx), idx);
}

const v8::Array* v8__Object__GetOwnPropertyNames(
        const v8::Object* self,
        const v8::Context* ctx) {
    return maybe_local_to_ptr(
        ptr_to_local(self)->GetOwnPropertyNames(ptr_to_local(ctx))
    );
}

const v8::Array* v8__Object__GetPropertyNames(
        const v8::Object* self,
        const v8::Context* ctx) {
    return maybe_local_to_ptr(
        ptr_to_local(self)->GetPropertyNames(ptr_to_local(ctx))
    );
}

const v8::Value* v8__Object__GetPrototype(
       const v8::Object& self) {
  return local_to_ptr(ptr_to_local(&self)->GetPrototype());
}

void v8__Object__SetPrototype(
        const v8::Object& self,
        const v8::Context& ctx,
        const v8::Object& prototype,
        v8::Maybe<bool>* out) {
  *out = ptr_to_local(&self)->SetPrototype(ptr_to_local(&ctx), ptr_to_local(&prototype));
}

void v8__Object__SetAlignedPointerInInternalField(
        const v8::Object* self,
        int idx,
        void* ptr) {
    ptr_to_local(self)->SetAlignedPointerInInternalField(idx, ptr);
}

// FunctionCallbackInfo

v8::Isolate* v8__FunctionCallbackInfo__GetIsolate(
        const v8::FunctionCallbackInfo<v8::Value>& self) {
    return self.GetIsolate();
}

int v8__FunctionCallbackInfo__Length(
        const v8::FunctionCallbackInfo<v8::Value>& self) {
    return self.Length();
}

const v8::Value* v8__FunctionCallbackInfo__INDEX(
        const v8::FunctionCallbackInfo<v8::Value>& self, int i) {
    return local_to_ptr(self[i]);
}

void v8__FunctionCallbackInfo__GetReturnValue(
        const v8::FunctionCallbackInfo<v8::Value>& self,
        v8::ReturnValue<v8::Value>* out) {
    // Can't return incomplete type to C so copy to res pointer.
    *out = self.GetReturnValue();
}

const v8::Object* v8__FunctionCallbackInfo__This(
        const v8::FunctionCallbackInfo<v8::Value>& self) {
    return local_to_ptr(self.This());
}

const v8::Value* v8__FunctionCallbackInfo__Data(
        const v8::FunctionCallbackInfo<v8::Value>& self) {
    return local_to_ptr(self.Data());
}

// PropertyCallbackInfo

v8::Isolate* v8__PropertyCallbackInfo__GetIsolate(
        const v8::PropertyCallbackInfo<v8::Value>& self) {
    return self.GetIsolate();
}

void v8__PropertyCallbackInfo__GetReturnValue(
        const v8::PropertyCallbackInfo<v8::Value>& self,
        v8::ReturnValue<v8::Value>* out) {
    *out = self.GetReturnValue();
}

const v8::Object* v8__PropertyCallbackInfo__This(
        const v8::PropertyCallbackInfo<v8::Value>& self) {
    return local_to_ptr(self.This());
}

const v8::Value* v8__PropertyCallbackInfo__Data(
        const v8::PropertyCallbackInfo<v8::Value>& self) {
    return local_to_ptr(self.Data());
}

// PromiseRejectMessage

v8::PromiseRejectEvent v8__PromiseRejectMessage__GetEvent(const v8::PromiseRejectMessage& self) {
    return self.GetEvent();
}

const v8::Promise* v8__PromiseRejectMessage__GetPromise(const v8::PromiseRejectMessage& self) {
    return local_to_ptr(self.GetPromise());
}

const v8::Value* v8__PromiseRejectMessage__GetValue(const v8::PromiseRejectMessage& self) {
    return local_to_ptr(self.GetValue());
}

size_t v8__PromiseRejectMessage__SIZEOF() {
    return sizeof(v8::PromiseRejectMessage);
}

// ReturnValue

void v8__ReturnValue__Set(
        v8::ReturnValue<v8::Value> self,
        const v8::Value& value) {
    self.Set(ptr_to_local(&value));
}

const v8::Value* v8__ReturnValue__Get(
        v8::ReturnValue<v8::Value> self) {
    return local_to_ptr(self.Get());
}

// FunctionTemplate

const v8::FunctionTemplate* v8__FunctionTemplate__New__DEFAULT(
        v8::Isolate* isolate) {
    return local_to_ptr(v8::FunctionTemplate::New(isolate));
}

const v8::FunctionTemplate* v8__FunctionTemplate__New__DEFAULT2(
        v8::Isolate* isolate,
        v8::FunctionCallback callback_or_null) {
    return local_to_ptr(v8::FunctionTemplate::New(isolate, callback_or_null));
}

const v8::FunctionTemplate* v8__FunctionTemplate__New__DEFAULT3(
        v8::Isolate* isolate,
        v8::FunctionCallback callback_or_null,
        const v8::Value& data) {
    return local_to_ptr(v8::FunctionTemplate::New(isolate, callback_or_null, ptr_to_local(&data)));
}

const v8::ObjectTemplate* v8__FunctionTemplate__InstanceTemplate(
        const v8::FunctionTemplate& self) {
    return local_to_ptr(ptr_to_local(&self)->InstanceTemplate());
}

const v8::ObjectTemplate* v8__FunctionTemplate__PrototypeTemplate(
        const v8::FunctionTemplate& self) {
    return local_to_ptr(ptr_to_local(&self)->PrototypeTemplate());
}

void v8__FunctionTemplate__Inherit(
        const v8::FunctionTemplate& self,
        const v8::FunctionTemplate& parent) {
    ptr_to_local(&self)->Inherit(ptr_to_local(&parent));
}

void v8__FunctionTemplate__SetPrototypeProviderTemplate(
        const v8::FunctionTemplate& self,
        const v8::FunctionTemplate& prototype_provider) {
    ptr_to_local(&self)->SetPrototypeProviderTemplate(ptr_to_local(&prototype_provider));
}

const v8::Function* v8__FunctionTemplate__GetFunction(
        const v8::FunctionTemplate& self, const v8::Context& context) {
    return maybe_local_to_ptr(
        ptr_to_local(&self)->GetFunction(ptr_to_local(&context))
    );
}

void v8__FunctionTemplate__SetClassName(
        const v8::FunctionTemplate& self,
        const v8::String& name) {
    ptr_to_local(&self)->SetClassName(ptr_to_local(&name));
}

void v8__FunctionTemplate__ReadOnlyPrototype(
        const v8::FunctionTemplate& self) {
    ptr_to_local(&self)->ReadOnlyPrototype();
}

// Function

const v8::Function* v8__Function__New__DEFAULT(
        const v8::Context& ctx,
        v8::FunctionCallback callback) {
    return maybe_local_to_ptr(
        v8::Function::New(ptr_to_local(&ctx), callback)
    );
}

const v8::Function* v8__Function__New__DEFAULT2(
        const v8::Context& ctx,
        v8::FunctionCallback callback,
        const v8::Value& data) {
    return maybe_local_to_ptr(
        v8::Function::New(ptr_to_local(&ctx), callback, ptr_to_local(&data))
    );
}

const v8::Value* v8__Function__Call(
        const v8::Function& self,
        const v8::Context& context,
        const v8::Value& recv,
        int argc,
        const v8::Value* const argv[]) {
    return maybe_local_to_ptr(
        ptr_to_local(&self)->Call(
            ptr_to_local(&context),
            ptr_to_local(&recv),
            argc, const_ptr_array_to_local_array(argv)
        )
    );
}

const v8::Object* v8__Function__NewInstance(
        const v8::Function& self,
        const v8::Context& context,
        int argc,
        const v8::Value* const argv[]) {
    return maybe_local_to_ptr(
        ptr_to_local(&self)->NewInstance(
            ptr_to_local(&context),
            argc,
            const_ptr_array_to_local_array(argv)
        )
    );
}

const v8::Value* v8__Function__GetName(const v8::Function& self) {
    return local_to_ptr(self.GetName());
}

void v8__Function__SetName(
        const v8::Function& self,
        const v8::String& name) {
    return ptr_to_local(&self)->SetName(ptr_to_local(&name));
}

// External

const v8::External* v8__External__New(
        v8::Isolate* isolate,
        void* value) {
    return local_to_ptr(v8::External::New(isolate, value));
}

void* v8__External__Value(const v8::External& self) { return self.Value(); }

// Symbol well-known

const v8::Symbol* v8__Symbol__GetAsyncIterator(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetAsyncIterator(isolate));
}
const v8::Symbol* v8__Symbol__GetHasInstance(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetHasInstance(isolate));
}
const v8::Symbol* v8__Symbol__GetIsConcatSpreadable(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetIsConcatSpreadable(isolate));
}
const v8::Symbol* v8__Symbol__GetIterator(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetIterator(isolate));
}
const v8::Symbol* v8__Symbol__GetMatch(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetMatch(isolate));
}
const v8::Symbol* v8__Symbol__GetReplace(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetReplace(isolate));
}
const v8::Symbol* v8__Symbol__GetSearch(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetSearch(isolate));
}
const v8::Symbol* v8__Symbol__GetSplit(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetSplit(isolate));
}
const v8::Symbol* v8__Symbol__GetToPrimitive(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetToPrimitive(isolate));
}
const v8::Symbol* v8__Symbol__GetToStringTag(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetToStringTag(isolate));
}
const v8::Symbol* v8__Symbol__GetUnscopables(v8::Isolate* isolate) {
    return local_to_ptr(v8::Symbol::GetUnscopables(isolate));
}

// Persistent

void v8__Persistent__New(
        v8::Isolate* isolate,
        // Allow passing in a data pointer which includes values, templates, context, and more.
        const v8::Data& data,
        v8::Persistent<v8::Data>* out) {
    new (out) v8::Persistent<v8::Data>(isolate, ptr_to_local(&data));
}

void v8__Persistent__Reset(v8::Persistent<v8::Data>* self) {
    // v8::Persistent by default uses NonCopyablePersistentTraits which will create a bad copy if we accept v8::Persistent<v8::Data> as the arg.
    // Instead we operate on its pointer.
    self->Reset();
}

void v8__Persistent__SetWeak(v8::Persistent<v8::Data>* self) {
    self->SetWeak();
}

void v8__Persistent__SetWeakFinalizer(
        v8::Persistent<v8::Data>* self,
        void* finalizer_ctx,
        v8::WeakCallbackInfo<void>::Callback finalizer_cb,
        v8::WeakCallbackType type) {
    self->SetWeak(finalizer_ctx, finalizer_cb, type);
}

// WeakCallbackInfo

v8::Isolate* v8__WeakCallbackInfo__GetIsolate(
        const v8::WeakCallbackInfo<void>& self) {
    return self.GetIsolate();
}

void* v8__WeakCallbackInfo__GetParameter(
        const v8::WeakCallbackInfo<void>& self) {
    return self.GetParameter();
}

void* v8__WeakCallbackInfo__GetInternalField(
        const v8::WeakCallbackInfo<void>& self,
        int idx) {
    return self.GetInternalField(idx);
}

// Exception

const v8::Value* v8__Exception__Error(const v8::String& message) {
    return local_to_ptr(v8::Exception::Error(ptr_to_local(&message)));
}

const v8::Value* v8__Exception__TypeError(const v8::String& message) {
    return local_to_ptr(v8::Exception::TypeError(ptr_to_local(&message)));
}

const v8::Value* v8__Exception__SyntaxError(const v8::String& message) {
    return local_to_ptr(v8::Exception::SyntaxError(ptr_to_local(&message)));
}

const v8::Value* v8__Exception__ReferenceError(const v8::String& message) {
    return local_to_ptr(v8::Exception::ReferenceError(ptr_to_local(&message)));
}

const v8::Value* v8__Exception__RangeError(const v8::String& message) {
    return local_to_ptr(v8::Exception::RangeError(ptr_to_local(&message)));
}

const v8::StackTrace* v8__Exception__GetStackTrace(const v8::Value& exception) {
    return local_to_ptr(v8::Exception::GetStackTrace(ptr_to_local(&exception)));
}

const v8::Message* v8__Exception__CreateMessage(
        v8::Isolate* isolate,
        const v8::Value& exception) {
    return local_to_ptr(v8::Exception::CreateMessage(isolate, ptr_to_local(&exception)));
}

// TryCatch

size_t v8__TryCatch__SIZEOF() {
    return sizeof(v8::TryCatch);
}

void v8__TryCatch__CONSTRUCT(
        v8::TryCatch* buf, v8::Isolate* isolate) {
    construct_in_place<v8::TryCatch>(buf, isolate);
}

void v8__TryCatch__DESTRUCT(v8::TryCatch* self) { self->~TryCatch(); }

const v8::Value* v8__TryCatch__Exception(const v8::TryCatch& self) {
    return local_to_ptr(self.Exception());
}

const v8::Message* v8__TryCatch__Message(const v8::TryCatch& self) {
    return local_to_ptr(self.Message());
}

bool v8__TryCatch__HasCaught(const v8::TryCatch& self) {
    return self.HasCaught();
}

const v8::Value* v8__TryCatch__StackTrace(
        const v8::TryCatch& self,
        const v8::Context& context) {
    return maybe_local_to_ptr(self.StackTrace(ptr_to_local(&context)));
}

bool v8__TryCatch__IsVerbose(const v8::TryCatch& self) { return self.IsVerbose(); }

void v8__TryCatch__SetVerbose(
        v8::TryCatch* self,
        bool value) {
    self->SetVerbose(value);
}

const v8::Value* v8__TryCatch__ReThrow(v8::TryCatch* self) {
    return local_to_ptr(self->ReThrow());
}

// Message

const v8::String* v8__Message__Get(const v8::Message& self) {
    return local_to_ptr(self.Get());
}

const v8::String* v8__Message__GetSourceLine(
        const v8::Message& self,
        const v8::Context& context) {
    return maybe_local_to_ptr(self.GetSourceLine(ptr_to_local(&context)));
}

const v8::Value* v8__Message__GetScriptResourceName(const v8::Message& self) {
    return local_to_ptr(self.GetScriptResourceName());
}

int v8__Message__GetLineNumber(
        const v8::Message& self,
        const v8::Context& context) {
    v8::Maybe<int> maybe = self.GetLineNumber(ptr_to_local(&context));
    return maybe.FromMaybe(-1);
}

int v8__Message__GetStartColumn(const v8::Message& self) { return self.GetStartColumn(); }

int v8__Message__GetEndColumn(const v8::Message& self) { return self.GetEndColumn(); }

const v8::StackTrace* v8__Message__GetStackTrace(const v8::Message& self) { return local_to_ptr(self.GetStackTrace()); }

// StackTrace

int v8__StackTrace__GetFrameCount(const v8::StackTrace& self) { return self.GetFrameCount(); }

const v8::StackFrame* v8__StackTrace__GetFrame(
        const v8::StackTrace& self,
        v8::Isolate* isolate,
        uint32_t idx) {
    return local_to_ptr(self.GetFrame(isolate, idx));
}

const v8::StackTrace* v8__StackTrace__CurrentStackTrace__STATIC(
        v8::Isolate* isolate,
        int frame_limit) {
    return local_to_ptr(v8::StackTrace::CurrentStackTrace(isolate, frame_limit));
}

const v8::String* v8__StackTrace__CurrentScriptNameOrSourceURL__STATIC(v8::Isolate* isolate) {
    return local_to_ptr(v8::StackTrace::CurrentScriptNameOrSourceURL(isolate));
}

// StackFrame

int v8__StackFrame__GetLineNumber(const v8::StackFrame& self) { return self.GetLineNumber(); }

int v8__StackFrame__GetColumn(const v8::StackFrame& self) { return self.GetColumn(); }

int v8__StackFrame__GetScriptId(const v8::StackFrame& self) { return self.GetScriptId(); }

const v8::String* v8__StackFrame__GetScriptName(const v8::StackFrame& self) {
    return local_to_ptr(self.GetScriptName());
}

const v8::String* v8__StackFrame__GetScriptNameOrSourceURL(const v8::StackFrame& self) {
    return local_to_ptr(self.GetScriptNameOrSourceURL());
}

const v8::String* v8__StackFrame__GetFunctionName(const v8::StackFrame& self) {
    return local_to_ptr(self.GetFunctionName());
}

bool v8__StackFrame__IsEval(const v8::StackFrame& self) { return self.IsEval(); }

bool v8__StackFrame__IsConstructor(const v8::StackFrame& self) { return self.IsConstructor(); }

bool v8__StackFrame__IsWasm(const v8::StackFrame& self) { return self.IsWasm(); }

bool v8__StackFrame__IsUserJavaScript(const v8::StackFrame& self) { return self.IsUserJavaScript(); }

// JSON

const v8::Value* v8__JSON__Parse(
        const v8::Context& ctx,
        const v8::String& json) {
    return maybe_local_to_ptr(
        v8::JSON::Parse(ptr_to_local(&ctx), ptr_to_local(&json)));
}

const v8::String* v8__JSON__Stringify(
        const v8::Context& ctx,
        const v8::Value& val,
        const v8::String& gap) {
    return maybe_local_to_ptr(
        v8::JSON::Stringify(ptr_to_local(&ctx), ptr_to_local(&val), ptr_to_local(&gap)));
}

// Misc.

void v8__base__SetDcheckFunction(void (*func)(const char*, int, const char*)) {
    v8::base::SetDcheckFunction(func);
}

// Inspector
// ---------

// v8 inspector is not really documented and not easy.
// Sources:
// - https://v8.dev/docs/inspector
// - C++ doc https://v8.github.io/api/head/namespacev8__inspector.html
// - Rusty (Deno) bindings https://github.com/denoland/rusty_v8/blob/main/src/binding.cc
// - https://github.com/ahmadov/v8_inspector_example
// - https://web.archive.org/web/20210918052901/http://hyperandroid.com/2020/02/12/v8-inspector-from-an-embedder-standpoint

// Utils

extern "C" typedef struct {
    const char *ptr;
    uint64_t len;
} CZigString;

/// Header for Zig
/// Allocates `bytes` bytes of memory using the allocator.
/// @param allocator: A Zig std.mem.Allocator
/// @param bytes: The number of bytes to allocate
/// @returns A pointer to the allocated memory, null if allocation failed
char* zigAlloc(const void* allocator, uint64_t bytes);

static inline v8_inspector::StringView toStringView(const char *str, size_t length) {
    auto* stringView = reinterpret_cast<const uint8_t*>(str);
    return { stringView, length };
}
/// Overload for safety in case the function is called with a string literal
static inline v8_inspector::StringView toStringView(const char *str) {
    size_t length = strlen(str);
    auto* stringView = reinterpret_cast<const uint8_t*>(str);
    return { stringView, length };
}
static inline v8_inspector::StringView toStringView(const std::string &str) {
    return toStringView(str.c_str(), str.length());
}

static inline std::string fromStringView(v8::Isolate* isolate, const v8_inspector::StringView stringView) {
  int length = static_cast<int>(stringView.length());
  v8::Local<v8::String> message = (
        stringView.is8Bit()
          ? v8::String::NewFromOneByte(isolate, reinterpret_cast<const uint8_t*>(stringView.characters8()), v8::NewStringType::kNormal, length)
          : v8::String::NewFromTwoByte(isolate, reinterpret_cast<const uint16_t*>(stringView.characters16()), v8::NewStringType::kNormal, length)
      ).ToLocalChecked();
  v8::String::Utf8Value result(isolate, message);
  return *result;
}

/// Allocates a string as utf8 on the allocator without \0 terminator, for use in Zig.
/// The strings pointer and length should therefore be returned together
/// @param input: The string contents to allocate
/// @param allocator: A Zig std.mem.Allocator
/// @param output: Points to the now allocated string on the heap (without sentinel \0), NULL if view was null, invalid if allocation failed
/// @returns false if allocation errored
bool allocString(const v8_inspector::StringView& input, const void* allocator, CZigString& output) {
    output.ptr = nullptr;
    output.len = 0;
    if (input.characters8() == nullptr) {
        return true;
    }

    std::string utf8_str;
    if (input.is8Bit()) {
        output.len = input.length();
    } else {
        utf8_str = v8_inspector::UTF16ToUTF8(reinterpret_cast<const char16_t*>(input.characters16()), input.length());
        output.len = utf8_str.length();
    }

    char* heap_str = zigAlloc(allocator, output.len);
    if (heap_str == nullptr) {
        return false;
    }

    if (input.is8Bit()) {
        memcpy(heap_str, input.characters8(), output.len);
    } else {
        memcpy(heap_str, utf8_str.c_str(), output.len);
    }
    output.ptr = heap_str;
    return true;
}


// Inspector

v8_inspector::V8Inspector *v8_inspector__Inspector__Create(
    v8::Isolate* isolate, v8_inspector__Client__IMPL *client) {
  std::unique_ptr<v8_inspector::V8Inspector> u =
    v8_inspector::V8Inspector::create(isolate, client);
  return u.release();
}
void v8_inspector__Inspector__DELETE(v8_inspector::V8Inspector* self) {
  delete self;
}
v8_inspector::V8InspectorSession *v8_inspector__Inspector__Connect(
    v8_inspector::V8Inspector *self, int contextGroupId,
    v8_inspector__Channel__IMPL *channel,
    v8_inspector::V8Inspector::ClientTrustLevel client_trust_level) {
  auto state = v8_inspector::StringView();
  std::unique_ptr<v8_inspector::V8InspectorSession> u =
      self->connect(contextGroupId, channel, state, client_trust_level);
  return u.release();
}
void v8_inspector__Inspector__ContextCreated(v8_inspector::V8Inspector *self,
                                             const char *name, int name_len,
                                             const char *origin, int origin_len,
                                             const char *auxData, int auxData_len,
                                             int contextGroupId,
                                             const v8::Context &ctx) {
  // create context info
  std::string name_str;
  name_str.assign(name, name_len);
  v8_inspector::StringView name_view(toStringView(name_str));
  auto context = ptr_to_local(&ctx);
  v8_inspector::V8ContextInfo info(context, contextGroupId, name_view);

  // add origin to context info
  std::string origin_str;
  origin_str.assign(origin, origin_len);
  info.origin = toStringView(origin_str);

  // add auxData to context info
  std::string auxData_str;
  auxData_str.assign(auxData, auxData_len);
  info.auxData = toStringView(auxData_str);

  // call contextCreated
  self->contextCreated(info);
}

// InspectorSession

void v8_inspector__Session__DELETE(v8_inspector::V8InspectorSession* self) {
  delete self;
}

void v8_inspector__Session__dispatchProtocolMessage(
    v8_inspector::V8InspectorSession *session, v8::Isolate *isolate,
    const char *msg, int msg_len) {
  auto str_view = toStringView(msg, msg_len);
  session->dispatchProtocolMessage(str_view);
}

v8_inspector::protocol::Runtime::RemoteObject* v8_inspector__Session__wrapObject(
    v8_inspector::V8InspectorSession *session, v8::Isolate *isolate,
    const v8::Context* ctx, const v8::Value* val,
    const char *grpname, int grpname_len, bool generatepreview) {
  auto sv_grpname = toStringView(grpname, grpname_len);
  auto remote_object = session->wrapObject(ptr_to_local(ctx), ptr_to_local(val), sv_grpname, generatepreview);
  return static_cast<v8_inspector::protocol::Runtime::RemoteObject*>(remote_object.release());
}

bool v8_inspector__Session__unwrapObject(
    v8_inspector::V8InspectorSession *session,
    const void *allocator,
    CZigString &out_error,
    CZigString in_objectId,
    v8::Local<v8::Value> &out_value,
    v8::Local<v8::Context> &out_context,
    CZigString &out_objectGroup
) {
  auto objectId = toStringView(in_objectId.ptr, in_objectId.len);
  auto error = v8_inspector::StringBuffer::create({});
  auto objectGroup = v8_inspector::StringBuffer::create({});

  // [out optional ] std::unique_ptr<StringBuffer>* error,
  // [in  required ] StringView                     objectId,
  // [out required ] v8::Local<v8::Value>         * value
  // [out required ] v8::Local<v8::Context>       * context
  // [out optional ] std::unique_ptr<StringBuffer>* objectGroup
  bool result = session->unwrapObject(&error, objectId, &out_value, &out_context, &objectGroup);
  if (!result) {
    allocString(error->string(), allocator, out_error);
    return false;
  }
  return allocString(objectGroup->string(), allocator, out_objectGroup);
}

// RemoteObject

// To prevent extra allocations on every call a single default value is reused everytime.
// It is expected that the precense of a value is checked before calling get* methods.
const v8_inspector::String16 DEFAULT_STRING = {"default"};

void v8_inspector__RemoteObject__DELETE(v8_inspector::protocol::Runtime::RemoteObject* self) {
  delete self;
}

// RemoteObject - Type
bool v8_inspector__RemoteObject__getType(v8_inspector::protocol::Runtime::RemoteObject* self, const void* allocator, CZigString &out_type) {
  auto str = self->getType();
  return allocString(toStringView(str), allocator, out_type);
}
void v8_inspector__RemoteObject__setType(v8_inspector::protocol::Runtime::RemoteObject* self, CZigString type) {
  self->setType(v8_inspector::String16::fromUTF8(type.ptr, type.len));
}

// RemoteObject - Subtype
bool v8_inspector__RemoteObject__hasSubtype(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->hasSubtype();
}
bool v8_inspector__RemoteObject__getSubtype(v8_inspector::protocol::Runtime::RemoteObject* self, const void* allocator, CZigString &subtype) {
  auto str = self->getSubtype(DEFAULT_STRING);
  return allocString(toStringView(str), allocator, subtype);
}
void v8_inspector__RemoteObject__setSubtype(v8_inspector::protocol::Runtime::RemoteObject* self, CZigString subtype) {
  self->setSubtype(v8_inspector::String16::fromUTF8(subtype.ptr, subtype.len));
}

// RemoteObject - ClassName
bool v8_inspector__RemoteObject__hasClassName(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->hasClassName();
}
bool v8_inspector__RemoteObject__getClassName(v8_inspector::protocol::Runtime::RemoteObject* self, const void* allocator, CZigString &className) {
  auto str = self->getClassName(DEFAULT_STRING);
  return allocString(toStringView(str), allocator, className);
}
void v8_inspector__RemoteObject__setClassName(v8_inspector::protocol::Runtime::RemoteObject* self, CZigString className) {
  self->setClassName(v8_inspector::String16::fromUTF8(className.ptr, className.len));
}

// RemoteObject - Value
bool v8_inspector__RemoteObject__hasValue(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->hasValue();
}
v8_inspector::protocol::Value* v8_inspector__RemoteObject__getValue(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->getValue(nullptr);
}
void v8_inspector__RemoteObject__setValue(v8_inspector::protocol::Runtime::RemoteObject* self, v8_inspector::protocol::Value* value) {
  self->setValue(std::unique_ptr<v8_inspector::protocol::Value>(value));
}

// RemoteObject - UnserializableValue
bool v8_inspector__RemoteObject__hasUnserializableValue(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->hasUnserializableValue();
}
bool v8_inspector__RemoteObject__getUnserializableValue(v8_inspector::protocol::Runtime::RemoteObject* self, const void* allocator, CZigString &unserializableValue) {
  auto str = self->getUnserializableValue(DEFAULT_STRING);
  return allocString(toStringView(str), allocator, unserializableValue);
}
void v8_inspector__RemoteObject__setUnserializableValue(v8_inspector::protocol::Runtime::RemoteObject* self, CZigString unserializableValue) {
  self->setUnserializableValue(v8_inspector::String16::fromUTF8(unserializableValue.ptr, unserializableValue.len));
}

// RemoteObject - Description
bool v8_inspector__RemoteObject__hasDescription(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->hasDescription();
}
bool v8_inspector__RemoteObject__getDescription(v8_inspector::protocol::Runtime::RemoteObject* self, const void* allocator, CZigString &description) {
  auto str = self->getDescription(DEFAULT_STRING);
  return allocString(toStringView(str), allocator, description);
}
void v8_inspector__RemoteObject__setDescription(v8_inspector::protocol::Runtime::RemoteObject* self, CZigString description) {
  self->setDescription(v8_inspector::String16::fromUTF8(description.ptr, description.len));
}

// RemoteObject - ObjectId
bool v8_inspector__RemoteObject__hasObjectId(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->hasObjectId();
}

bool v8_inspector__RemoteObject__getObjectId(v8_inspector::protocol::Runtime::RemoteObject* self, const void* allocator, CZigString &objectId) {
  auto str = self->getObjectId(DEFAULT_STRING);
  return allocString(toStringView(str), allocator, objectId);
}
  void v8_inspector__RemoteObject__setObjectId(v8_inspector::protocol::Runtime::RemoteObject* self, CZigString objectId) {
  self->setObjectId(v8_inspector::String16::fromUTF8(objectId.ptr, objectId.len));
}

// RemoteObject - Preview
bool v8_inspector__RemoteObject__hasPreview(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->hasPreview();
}
const v8_inspector::protocol::Runtime::ObjectPreview* v8_inspector__RemoteObject__getPreview(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->getPreview(nullptr);
}
void v8_inspector__RemoteObject__setPreview(v8_inspector::protocol::Runtime::RemoteObject* self, v8_inspector::protocol::Runtime::ObjectPreview* preview) {
  self->setPreview(std::unique_ptr<v8_inspector::protocol::Runtime::ObjectPreview>(preview));
}

// RemoteObject - CustomPreview
bool v8_inspector__RemoteObject__hasCustomPreview(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->hasCustomPreview();
}
const v8_inspector::protocol::Runtime::CustomPreview* v8_inspector__RemoteObject__getCustomPreview(v8_inspector::protocol::Runtime::RemoteObject* self) {
  return self->getCustomPreview(nullptr);
}
void v8_inspector__RemoteObject__setCustomPreview(v8_inspector::protocol::Runtime::RemoteObject* self, v8_inspector::protocol::Runtime::CustomPreview* customPreview) {
  self->setCustomPreview(std::unique_ptr<v8_inspector::protocol::Runtime::CustomPreview>(customPreview));
}

// InspectorChannel

v8_inspector__Channel__IMPL * v8_inspector__Channel__IMPL__CREATE(v8::Isolate *isolate) {
  auto channel = new v8_inspector__Channel__IMPL();
  channel->isolate = isolate;
  return channel;
}
void v8_inspector__Channel__IMPL__DELETE(v8_inspector__Channel__IMPL *self) {
  delete self;
}
void v8_inspector__Channel__IMPL__SET_DATA(v8_inspector__Channel__IMPL *self, void *data) {
  self->data = data;
}

// declaration of functions implementations
// NOTE: zig project should provide those implementations with C-ABI functions
void v8_inspector__Channel__IMPL__sendResponse(
    v8_inspector__Channel__IMPL* self, void* data,
    int callId, const char* message, size_t length);
void v8_inspector__Channel__IMPL__sendNotification(
    v8_inspector__Channel__IMPL* self, void *data,
    const char* msg, size_t length);
void v8_inspector__Channel__IMPL__flushProtocolNotifications(
    v8_inspector__Channel__IMPL* self, void *data);

// c++ implementation (just wrappers around the C/zig functions)
} // extern "C"
void v8_inspector__Channel__IMPL::sendResponse(
    int callId, std::unique_ptr<v8_inspector::StringBuffer> message) {
  const std::string resp = fromStringView(this->isolate, message->string());
  return v8_inspector__Channel__IMPL__sendResponse(this, this->data, callId, resp.c_str(), resp.length());
}
void v8_inspector__Channel__IMPL::sendNotification(
    std::unique_ptr<v8_inspector::StringBuffer> message) {
  const std::string notif = fromStringView(this->isolate, message->string());
   return v8_inspector__Channel__IMPL__sendNotification(this, this->data, notif.c_str(), notif.length());
}
void v8_inspector__Channel__IMPL::flushProtocolNotifications() {
  return v8_inspector__Channel__IMPL__flushProtocolNotifications(this, this->data);
}

extern "C" {

// wrappers for the public API Interface
// NOTE: not sure it's useful to expose those
void v8_inspector__Channel__sendResponse(
    v8_inspector::V8Inspector::Channel* self, int callId,
    v8_inspector::StringBuffer* message) {
  self->sendResponse(
      callId,
      static_cast<std::unique_ptr<v8_inspector::StringBuffer>>(message));
}
void v8_inspector__Channel__sendNotification(
    v8_inspector::V8Inspector::Channel* self,
    v8_inspector::StringBuffer* message) {
  self->sendNotification(
      static_cast<std::unique_ptr<v8_inspector::StringBuffer>>(message));
}
void v8_inspector__Channel__flushProtocolNotifications(
    v8_inspector::V8Inspector::Channel* self) {
  self->flushProtocolNotifications();
}

// InspectorClient

v8_inspector__Client__IMPL *v8_inspector__Client__IMPL__CREATE() {
  return new v8_inspector__Client__IMPL();
}
void v8_inspector__Client__IMPL__DELETE(v8_inspector__Client__IMPL *self) {
  delete self;
}
void v8_inspector__Client__IMPL__SET_DATA(v8_inspector__Client__IMPL *self, void *data) {
  self->data = data;
}

// declaration of functions implementations
// NOTE: zig project should provide those implementations with C-like functions
int64_t v8_inspector__Client__IMPL__generateUniqueId(v8_inspector__Client__IMPL* self, void* data);
void v8_inspector__Client__IMPL__runMessageLoopOnPause(
    v8_inspector__Client__IMPL *self,
    void* data, int contextGroupId);
void v8_inspector__Client__IMPL__quitMessageLoopOnPause(v8_inspector__Client__IMPL* self, void* data);
void v8_inspector__Client__IMPL__runIfWaitingForDebugger(
    v8_inspector__Client__IMPL* self, void* data, int contextGroupId);
void v8_inspector__Client__IMPL__consoleAPIMessage(
    v8_inspector__Client__IMPL* self, void* data, int contextGroupId,
    v8::Isolate::MessageErrorLevel level,
    const v8_inspector::StringView &message,
    const v8_inspector::StringView &url, unsigned lineNumber,
    unsigned columnNumber, v8_inspector::V8StackTrace *stackTrace);
const v8::Context* v8_inspector__Client__IMPL__ensureDefaultContextInGroup(
    v8_inspector__Client__IMPL* self, void* data, int contextGroupId);
char* v8_inspector__Client__IMPL__valueSubtype(
    v8_inspector__Client__IMPL* self, v8::Local<v8::Value> value);
char* v8_inspector__Client__IMPL__descriptionForValueSubtype(
    v8_inspector__Client__IMPL* self, v8::Local<v8::Context> context, v8::Local<v8::Value> value);

// c++ implementation (just wrappers around the c/zig functions)
} // extern "C"
int64_t v8_inspector__Client__IMPL::generateUniqueId() {
  return v8_inspector__Client__IMPL__generateUniqueId(this, this->data);
}
void v8_inspector__Client__IMPL::runMessageLoopOnPause(int contextGroupId) {
  return v8_inspector__Client__IMPL__runMessageLoopOnPause(this, this->data, contextGroupId);
}
void v8_inspector__Client__IMPL::quitMessageLoopOnPause() {
  return v8_inspector__Client__IMPL__quitMessageLoopOnPause(this, this->data);
}
void v8_inspector__Client__IMPL::runIfWaitingForDebugger(int contextGroupId) {
  return v8_inspector__Client__IMPL__runIfWaitingForDebugger(this, this->data, contextGroupId);
}
void v8_inspector__Client__IMPL::consoleAPIMessage(
    int contextGroupId, v8::Isolate::MessageErrorLevel level,
    const v8_inspector::StringView &message,
    const v8_inspector::StringView &url, unsigned lineNumber,
    unsigned columnNumber, v8_inspector::V8StackTrace *stackTrace) {
  return v8_inspector__Client__IMPL__consoleAPIMessage(
      this, this->data, contextGroupId, level, message, url, lineNumber,
      columnNumber, stackTrace);
}
v8::Local<v8::Context> v8_inspector__Client__IMPL::ensureDefaultContextInGroup(int contextGroupId) {
  return ptr_to_local(v8_inspector__Client__IMPL__ensureDefaultContextInGroup(this, this->data, contextGroupId));
}
std::unique_ptr<v8_inspector::StringBuffer> v8_inspector__Client__IMPL::valueSubtype(v8::Local<v8::Value> value) {
    auto subType = v8_inspector__Client__IMPL__valueSubtype(this, value);
    if (subType == nullptr) {
        return nullptr;
    }
    return v8_inspector::StringBuffer::create(toStringView(subType));
}
std::unique_ptr<v8_inspector::StringBuffer> v8_inspector__Client__IMPL::descriptionForValueSubtype(v8::Local<v8::Context> context, v8::Local<v8::Value> value) {
    auto description = v8_inspector__Client__IMPL__descriptionForValueSubtype(this, context, value);
    if (description == nullptr) {
        return nullptr;
    }
    return v8_inspector::StringBuffer::create(toStringView(description));
}

extern "C" {

// wrappers for the public API Interface
// NOTE: not sure it's useful to expose those
int64_t v8_inspector__Client__generateUniqueId(
    v8_inspector::V8InspectorClient *self) {
  return self->generateUniqueId();
}
void v8_inspector__Client__runMessageLoopOnPause(
    v8_inspector::V8InspectorClient* self, int contextGroupId) {
  self->runMessageLoopOnPause(contextGroupId);
}
void v8_inspector__Client__quitMessageLoopOnPause(
    v8_inspector::V8InspectorClient* self) {
  self->quitMessageLoopOnPause();
}
void v8_inspector__Client__runIfWaitingForDebugger(
    v8_inspector::V8InspectorClient* self, int contextGroupId) {
  self->runIfWaitingForDebugger(contextGroupId);
}
void v8_inspector__Client__consoleAPIMessage(
    v8_inspector::V8InspectorClient* self, int contextGroupId,
    v8::Isolate::MessageErrorLevel level,
    const v8_inspector::StringView& message,
    const v8_inspector::StringView& url, unsigned lineNumber,
    unsigned columnNumber, v8_inspector::V8StackTrace* stackTrace) {
  self->consoleAPIMessage(contextGroupId, level, message, url, lineNumber,
                          columnNumber, stackTrace);
}

} // extern "C"
