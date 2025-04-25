const std = @import("std");
const t = std.testing;

pub const c = @cImport({
    @cInclude("binding.h");
});

pub const PropertyAttribute = struct {
    pub const None = c.None;
    pub const ReadOnly = c.ReadOnly;
    pub const DontEnum = c.DontEnum;
    pub const DontDelete = c.DontDelete;
};

pub const PropertyHandlerFlags = struct {
    pub const None = c.None;
    pub const AllCanRead = c.kAllCanRead;
    pub const NonMasking = c.kNonMasking;
    pub const OnlyInterceptStrings = c.kOnlyInterceptStrings;
};

pub const PromiseRejectEvent = struct {
    pub const kPromiseRejectWithNoHandler = c.kPromiseRejectWithNoHandler;
    pub const kPromiseHandlerAddedAfterReject = c.kPromiseHandlerAddedAfterReject;
    pub const kPromiseRejectAfterResolved = c.kPromiseRejectAfterResolved;
    pub const kPromiseResolveAfterResolved = c.kPromiseResolveAfterResolved;
};

pub const MessageErrorLevel = struct {
    pub const kMessageLog = c.kMessageLog;
    pub const kMessageDebug = c.kMessageDebug;
    pub const kMessageInfo = c.kMessageInfo;
    pub const kMessageError = c.kMessageError;
    pub const kMessageWarning = c.kMessageWarning;
    pub const kMessageAll = c.kMessageAll;
};

/// [V8]
/// Policy for running microtasks:
/// - explicit: microtasks are invoked with the
///     Isolate::PerformMicrotaskCheckpoint() method;
/// - scoped: microtasks invocation is controlled by MicrotasksScope objects;
/// - auto: microtasks are invoked when the script call depth decrements to zero.
pub const MicrotasksPolicy = struct {
    pub const kExplicit = c.kExplicit;
    pub const kScoped = c.kScoped;
    pub const kAuto = c.kAuto;
};

// Currently, user callback functions passed into FunctionTemplate will need to have this declared as a param and then
// converted to FunctionCallbackInfo to get a nicer interface.
pub const C_FunctionCallbackInfo = c.FunctionCallbackInfo;
pub const C_PropertyCallbackInfo = c.PropertyCallbackInfo;
pub const C_WeakCallbackInfo = c.WeakCallbackInfo;
pub const C_PromiseRejectMessage = c.PromiseRejectMessage;

pub const C_Message = c.Message;
pub const C_Value = c.Value;
pub const C_Object = c.Object;
pub const C_Name = c.Name;
pub const C_Context = c.Context;
pub const C_FunctionTemplate = c.FunctionTemplate;
pub const C_Data = c.Data;
pub const C_FixedArray = c.FixedArray;
pub const C_Module = c.Module;
pub const C_InternalAddress = c.InternalAddress;
pub const C_String = c.String;

pub const MessageCallback = c.MessageCallback;
pub const FunctionCallback = c.FunctionCallback;
pub const AccessorNameGetterCallback = c.AccessorNameGetterCallback;
pub const AccessorNameSetterCallback = c.AccessorNameSetterCallback;

pub const IndexedPropertyGetterCallback = c.IndexedPropertyGetterCallback;
pub const IndexedPropertySetterCallback = c.IndexedPropertySetterCallback;
pub const IndexedPropertyQueryCallback = c.IndexedPropertyQueryCallback;
pub const IndexedPropertyDeleterCallback = c.IndexedPropertyDeleterCallback;
pub const IndexedPropertyEnumeratorCallback = c.IndexedPropertyEnumeratorCallback;
pub const IndexedPropertyDefinerCallback = c.IndexedPropertyDefinerCallback;
pub const IndexedPropertyDescriptorCallback = c.IndexedPropertyDescriptorCallback;
pub const IndexedPropertyHandlerConfiguration = struct {
    getter: ?IndexedPropertyGetterCallback = null,
    setter: ?IndexedPropertySetterCallback = null,
    query: ?IndexedPropertyQueryCallback = null,
    deleter: ?IndexedPropertyDeleterCallback = null,
    enumerator: ?IndexedPropertyEnumeratorCallback = null,
    definer: ?IndexedPropertyDefinerCallback = null,
    descriptor: ?IndexedPropertyDescriptorCallback = null,
    flags: c.PropertyHandlerFlags = PropertyHandlerFlags.None,
};

pub const NamedPropertyGetterCallback = c.NamedPropertyGetterCallback;
pub const NamedPropertySetterCallback = c.NamedPropertySetterCallback;
pub const NamedPropertyQueryCallback = c.NamedPropertyQueryCallback;
pub const NamedPropertyDeleterCallback = c.NamedPropertyDeleterCallback;
pub const NamedPropertyEnumeratorCallback = c.NamedPropertyEnumeratorCallback;
pub const NamedPropertyDefinerCallback = c.NamedPropertyDefinerCallback;
pub const NamedPropertyDescriptorCallback = c.NamedPropertyDescriptorCallback;
pub const NamedPropertyHandlerConfiguration = struct {
    getter: ?NamedPropertyGetterCallback = null,
    setter: ?NamedPropertySetterCallback = null,
    query: ?NamedPropertyQueryCallback = null,
    deleter: ?NamedPropertyDeleterCallback = null,
    enumerator: ?NamedPropertyEnumeratorCallback = null,
    definer: ?NamedPropertyDefinerCallback = null,
    descriptor: ?NamedPropertyDescriptorCallback = null,
    flags: c.PropertyHandlerFlags = PropertyHandlerFlags.None,
};

pub const CreateParams = c.CreateParams;

pub const SharedPtr = c.SharedPtr;

const Root = @This();

pub const Platform = struct {
    const Self = @This();

    handle: *c.Platform,

    /// Must be called first before initV8Platform and initV8
    /// Returns a new instance of the default v8::Platform implementation.
    ///
    /// |thread_pool_size| is the number of worker threads to allocate for
    /// background jobs. If a value of zero is passed, a suitable default
    /// based on the current number of processors online will be chosen.
    /// If |idle_task_support| is enabled then the platform will accept idle
    /// tasks (IdleTasksEnabled will return true) and will rely on the embedder
    /// calling v8::platform::RunIdleTasks to process the idle tasks.
    pub fn initDefault(thread_pool_size: u32, idle_task_support: bool) Self {
        return .{
            .handle = c.v8__Platform__NewDefaultPlatform(@as(c_int, @intCast(thread_pool_size)), if (idle_task_support) 1 else 0).?,
        };
    }

    pub fn deinit(self: Self) void {
        c.v8__Platform__DELETE(self.handle);
    }

    /// [V8]
    /// Pumps the message loop for the given isolate.
    ///
    /// The caller has to make sure that this is called from the right thread.
    /// Returns true if a task was executed, and false otherwise. If the call to
    /// PumpMessageLoop is nested within another call to PumpMessageLoop, only
    /// nestable tasks may run. Otherwise, any task may run. Unless requested through
    /// the |behavior| parameter, this call does not block if no task is pending. The
    /// |platform| has to be created using |NewDefaultPlatform|.
    pub fn pumpMessageLoop(self: Self, isolate: Isolate, wait_for_work: bool) bool {
        return c.v8__Platform__PumpMessageLoop(self.handle, isolate.handle, wait_for_work);
    }
};

pub fn getVersion() []const u8 {
    const str = c.v8__V8__GetVersion();
    const idx = std.mem.indexOfSentinel(u8, 0, str);
    return str[0..idx];
}

/// [v8]
/// Sets the v8::Platform to use. This should be invoked before V8 is
/// initialized.
pub fn initV8Platform(platform: Platform) void {
    c.v8__V8__InitializePlatform(platform.handle);
}

/// [v8]
/// Initializes V8. This function needs to be called before the first Isolate
/// is created. It always returns true.
pub fn initV8() void {
    c.v8__V8__Initialize();
}

/// [v8]
/// Initializes the ICU bundled with v8.
pub fn initV8ICU() bool {
    return c.v8__V8__InitializeICU();
}

/// [v8]
/// Releases any resources used by v8 and stops any utility thread
/// that may be running.  Note that disposing v8 is permanent, it
/// cannot be reinitialized.
///
/// It should generally not be necessary to dispose v8 before exiting
/// a process, this should happen automatically.  It is only necessary
/// to use if the process needs the resources taken up by v8.
pub fn deinitV8() bool {
    return c.v8__V8__Dispose() == 1;
}

/// [v8]
/// Clears all references to the v8::Platform. This should be invoked after
/// V8 was disposed.
pub fn deinitV8Platform() void {
    c.v8__V8__DisposePlatform();
}

pub fn idleNotificaiton(hint: c_int) void {
    c.v8__V8__IdleNoticiation(hint);
}

pub fn initCreateParams() c.CreateParams {
    var params: c.CreateParams = undefined;
    c.v8__Isolate__CreateParams__CONSTRUCT(&params);
    return params;
}

pub fn createDefaultArrayBufferAllocator() *c.ArrayBufferAllocator {
    return c.v8__ArrayBuffer__Allocator__NewDefaultAllocator().?;
}

pub fn destroyArrayBufferAllocator(alloc: *c.ArrayBufferAllocator) void {
    c.v8__ArrayBuffer__Allocator__DELETE(alloc);
}

pub const Exception = struct {
    pub fn initError(msg: String) Value {
        return .{
            .handle = c.v8__Exception__Error(msg.handle).?,
        };
    }

    pub fn initTypeError(msg: String) Value {
        return .{
            .handle = c.v8__Exception__TypeError(msg.handle).?,
        };
    }

    pub fn initSyntaxError(msg: String) Value {
        return .{
            .handle = c.v8__Exception__SyntaxError(msg.handle).?,
        };
    }

    pub fn initReferenceError(msg: String) Value {
        return .{
            .handle = c.v8__Exception__ReferenceError(msg.handle).?,
        };
    }

    pub fn initRangeError(msg: String) Value {
        return .{
            .handle = c.v8__Exception__RangeError(msg.handle).?,
        };
    }

    pub fn initMessage(iso: Isolate, exception: Value) Message {
        return .{
            .handle = c.v8__Exception__CreateMessage(iso.handle, exception.handle).?,
        };
    }

    /// [v8]
    /// Returns the original stack trace that was captured at the creation time
    /// of a given exception, or an empty handle if not available.
    pub fn getStackTrace(exception: Value) ?StackTrace {
        if (c.v8__Exception__GetStackTrace(exception.handle)) |handle| {
            return StackTrace{
                .handle = handle,
            };
        } else return null;
    }
};

/// Contains Isolate related methods and convenience methods for creating js values.
pub const Isolate = struct {
    const Self = @This();

    handle: *c.Isolate,

    pub fn init(params: *const c.CreateParams) Self {
        const ptr = @as(*c.CreateParams, @ptrFromInt(@intFromPtr(params)));
        return .{
            .handle = c.v8__Isolate__New(ptr).?,
        };
    }

    /// [V8]
    /// Disposes the isolate.  The isolate must not be entered by any
    /// thread to be disposable.
    pub fn deinit(self: Self) void {
        c.v8__Isolate__Dispose(self.handle);
    }

    /// [V8]
    /// Sets this isolate as the entered one for the current thread.
    /// Saves the previously entered one (if any), so that it can be
    /// restored when exiting.  Re-entering an isolate is allowed.
    /// [Notes]
    /// This is equivalent to initing an Isolate Scope.
    pub fn enter(self: *Self) void {
        c.v8__Isolate__Enter(self.handle);
    }

    /// [V8]
    /// Exits this isolate by restoring the previously entered one in the
    /// current thread.  The isolate may still stay the same, if it was
    /// entered more than once.
    ///
    /// Requires: this == Isolate::GetCurrent().
    /// [Notes]
    /// This is equivalent to deiniting an Isolate Scope.
    pub fn exit(self: *Self) void {
        c.v8__Isolate__Exit(self.handle);
    }

    pub fn getCurrentContext(self: Self) Context {
        return .{
            .handle = c.v8__Isolate__GetCurrentContext(self.handle).?,
        };
    }

    /// It seems stack trace is only captured if the value is wrapped in an Exception.initError.
    pub fn throwException(self: Self, value: anytype) Value {
        return .{
            .handle = c.v8__Isolate__ThrowException(self.handle, getValueHandle(value)).?,
        };
    }

    /// [V8]
    /// Set callback to notify about promise reject with no handler, or
    /// revocation of such a previous notification once the handler is added.
    pub fn setPromiseRejectCallback(self: Self, callback: c.PromiseRejectCallback) void {
        c.v8__Isolate__SetPromiseRejectCallback(self.handle, callback);
    }

    pub fn getMicrotasksPolicy(self: Self) c.MicrotasksPolicy {
        return c.v8__Isolate__GetMicrotasksPolicy(self.handle);
    }

    pub fn setMicrotasksPolicy(self: Self, policy: c.MicrotasksPolicy) void {
        c.v8__Isolate__SetMicrotasksPolicy(self.handle, policy);
    }

    pub fn performMicrotasksCheckpoint(self: Self) void {
        c.v8__Isolate__PerformMicrotaskCheckpoint(self.handle);
    }

    pub fn addMessageListener(self: Self, callback: c.MessageCallback) bool {
        return c.v8__Isolate__AddMessageListener(self.handle, callback);
    }

    pub fn addMessageListenerWithErrorLevel(self: Self, callback: c.MessageCallback, message_levels: c_int, value: Value) bool {
        return c.v8__Isolate__AddMessageListenerWithErrorLevel(self.handle, callback, message_levels, value.handle);
    }

    /// [v8]
    /// Tells V8 to capture current stack trace when uncaught exception occurs
    /// and report it to the message listeners. The option is off by default.
    pub fn setCaptureStackTraceForUncaughtExceptions(self: Self, capture: bool, frame_limit: u32) void {
        c.v8__Isolate__SetCaptureStackTraceForUncaughtExceptions(self.handle, capture, @as(c_int, @intCast(frame_limit)));
    }

    /// This does not terminate the current script immediately. V8 will mark it for termination at a later time. This was intended to end long running loops.
    pub fn terminateExecution(self: Self) void {
        c.v8__Isolate__TerminateExecution(self.handle);
    }

    pub fn isExecutionTerminating(self: Self) bool {
        return c.v8__Isolate__IsExecutionTerminating(self.handle);
    }

    pub fn cancelTerminateExecution(self: Self) void {
        c.v8__Isolate__CancelTerminateExecution(self.handle);
    }

    pub fn lowMemoryNotification(self: Self) void {
        c.v8__Isolate__LowMemoryNotification(self.handle);
    }

    pub fn getHeapStatistics(self: Self) c.HeapStatistics {
        var res: c.HeapStatistics = undefined;
        c.v8__Isolate__GetHeapStatistics(self.handle, &res);
        return res;
    }

    pub fn initNumber(self: Self, val: f64) Number {
        return Number.init(self, val);
    }

    pub fn initNumberBitCastedU64(self: Self, val: u64) Number {
        return Number.initBitCastedU64(self, val);
    }

    pub fn initBoolean(self: Self, val: bool) Boolean {
        return Boolean.init(self, val);
    }

    pub fn initIntegerI32(self: Self, val: i32) Integer {
        return Integer.initI32(self, val);
    }

    pub fn initIntegerU32(self: Self, val: u32) Integer {
        return Integer.initU32(self, val);
    }

    pub fn initBigIntI64(self: Self, val: i64) BigInt {
        return BigInt.initI64(self, val);
    }

    pub fn initBigIntU64(self: Self, val: u64) BigInt {
        return BigInt.initU64(self, val);
    }

    pub fn initStringUtf8(self: Self, val: []const u8) String {
        return String.initUtf8(self, val);
    }

    pub fn initPersistent(self: Self, comptime T: type, val: T) Persistent(T) {
        return Persistent(T).init(self, val);
    }

    pub fn initFunctionTemplateDefault(self: Self) FunctionTemplate {
        return FunctionTemplate.initDefault(self);
    }

    pub fn initFunctionTemplateCallback(self: Self, callback: c.FunctionCallback) FunctionTemplate {
        return FunctionTemplate.initCallback(self, callback);
    }

    pub fn initFunctionTemplateCallbackData(self: Self, callback: c.FunctionCallback, data_value: anytype) FunctionTemplate {
        return FunctionTemplate.initCallbackData(self, callback, data_value);
    }

    pub fn initObjectTemplateDefault(self: Self) ObjectTemplate {
        return ObjectTemplate.initDefault(self);
    }

    pub fn initObjectTemplate(self: Self, constructor: FunctionTemplate) ObjectTemplate {
        return ObjectTemplate.init(self, constructor);
    }

    pub fn initObject(self: Self) Object {
        return Object.init(self);
    }

    pub fn initArray(self: Self, len: u32) Array {
        return Array.init(self, len);
    }

    pub fn initArrayElements(self: Self, elems: []const Value) Array {
        return Array.initElements(self, elems);
    }

    pub fn initUndefined(self: Self) Primitive {
        return Root.initUndefined(self);
    }

    pub fn initNull(self: Self) Primitive {
        return Root.initNull(self);
    }

    pub fn initTrue(self: Self) Boolean {
        return Root.initTrue(self);
    }

    pub fn initFalse(self: Self) Boolean {
        return Root.initFalse(self);
    }

    pub fn initContext(self: Self, global_tmpl: ?ObjectTemplate, global_obj: ?*c.Value) Context {
        return Context.init(self, global_tmpl, global_obj);
    }

    pub fn initExternal(self: Self, val: ?*anyopaque) External {
        return External.init(self, val);
    }

    pub fn setData(self: Self, idx: u32, val: *anyopaque) void {
        return c.v8__Isolate__SetData(self.handle, @as(c_int, @intCast(idx)), val);
    }

    pub fn getData(self: Self, idx: u32) ?*anyopaque {
        return c.v8__Isolate__GetData(self.handle, @as(c_int, @intCast(idx)));
    }
};

pub const HandleScope = struct {
    const Self = @This();

    inner: c.HandleScope,

    /// [Notes]
    /// This starts a new stack frame to record local objects created.
    /// Since deinit depends on the inner pointer being the same, init should construct in place.
    pub fn init(self: *Self, isolate: Isolate) void {
        c.v8__HandleScope__CONSTRUCT(&self.inner, isolate.handle);
    }

    /// [Notes]
    /// This pops the scope frame and allows V8 to mark/free local objects created since HandleScope.init.
    /// In C++ code, this would happen automatically when the HandleScope var leaves the current scope.
    pub fn deinit(self: *Self) void {
        c.v8__HandleScope__DESTRUCT(&self.inner);
    }
};

pub const Context = struct {
    const Self = @This();

    handle: *const c.Context,

    /// [V8]
    /// Creates a new context and returns a handle to the newly allocated
    /// context.
    ///
    /// \param isolate The isolate in which to create the context.
    ///
    /// \param extensions An optional extension configuration containing
    /// the extensions to be installed in the newly created context.
    ///
    /// \param global_template An optional object template from which the
    /// global object for the newly created context will be created.
    ///
    /// \param global_object An optional global object to be reused for
    /// the newly created context. This global object must have been
    /// created by a previous call to Context::New with the same global
    /// template. The state of the global object will be completely reset
    /// and only object identify will remain.
    pub fn init(isolate: Isolate, global_tmpl: ?ObjectTemplate, global_obj: ?*c.Value) Self {
        return .{
            .handle = c.v8__Context__New(isolate.handle, if (global_tmpl != null) global_tmpl.?.handle else null, global_obj).?,
        };
    }

    /// [V8]
    /// Enter this context.  After entering a context, all code compiled
    /// and run is compiled and run in this context.  If another context
    /// is already entered, this old context is saved so it can be
    /// restored when the new context is exited.
    pub fn enter(self: Self) void {
        c.v8__Context__Enter(self.handle);
    }

    /// [V8]
    /// Exit this context.  Exiting the current context restores the
    /// context that was in place when entering the current context.
    pub fn exit(self: Self) void {
        c.v8__Context__Exit(self.handle);
    }

    /// [V8]
    /// Returns the isolate associated with a current context.
    pub fn getIsolate(self: Self) Isolate {
        return Isolate{
            .handle = c.v8__Context__GetIsolate(self.handle).?,
        };
    }

    pub fn getGlobal(self: Self) Object {
        return .{
            .handle = c.v8__Context__Global(self.handle).?,
        };
    }

    pub fn getEmbedderData(self: Self, idx: u32) Value {
        return .{
            .handle = c.v8__Context__GetEmbedderData(self.handle, @as(c_int, @intCast(idx))).?,
        };
    }

    pub fn setEmbedderData(self: Self, idx: u32, val: anytype) void {
        c.v8__Context__SetEmbedderData(self.handle, @as(c_int, @intCast(idx)), getValueHandle(val));
    }

    pub fn debugContextId(self: Self) i32 {
        return c.v8__Context__DebugContextId(self.handle);
    }
};

pub const PropertyCallbackInfo = struct {
    const Self = @This();

    handle: *const c.PropertyCallbackInfo,

    pub fn initFromV8(val: ?*const c.PropertyCallbackInfo) Self {
        return .{
            .handle = val.?,
        };
    }

    pub fn getIsolate(self: Self) Isolate {
        return .{
            .handle = c.v8__PropertyCallbackInfo__GetIsolate(self.handle).?,
        };
    }

    pub fn getReturnValue(self: Self) ReturnValue {
        var res: c.ReturnValue = undefined;
        c.v8__PropertyCallbackInfo__GetReturnValue(self.handle, &res);
        return .{
            .inner = res,
        };
    }

    pub fn getThis(self: Self) Object {
        return .{
            .handle = c.v8__PropertyCallbackInfo__This(self.handle).?,
        };
    }

    pub fn getData(self: Self) Value {
        return .{
            .handle = c.v8__PropertyCallbackInfo__Data(self.handle).?,
        };
    }

    pub fn getExternalValue(self: Self) ?*anyopaque {
        return self.getData().castTo(External).get();
    }
};

pub const WeakCallbackInfo = struct {
    const Self = @This();

    handle: *const c.WeakCallbackInfo,

    pub fn initFromC(val: ?*const c.WeakCallbackInfo) Self {
        return .{
            .handle = val.?,
        };
    }

    pub fn getIsolate(self: Self) Isolate {
        return .{
            .handle = c.v8__WeakCallbackInfo__GetIsolate(self.handle).?,
        };
    }

    pub fn getParameter(self: Self) *anyopaque {
        return c.v8__WeakCallbackInfo__GetParameter(self.handle).?;
    }

    pub fn getInternalField(self: Self, idx: u32) ?*anyopaque {
        return c.v8__WeakCallbackInfo__GetInternalField(self.handle, @as(c_int, @intCast(idx)));
    }
};

pub const PromiseRejectMessage = struct {
    const Self = @This();

    inner: c.PromiseRejectMessage,

    pub fn initFromC(val: c.PromiseRejectMessage) Self {
        return .{
            .inner = val,
        };
    }

    pub fn getEvent(self: Self) c.PromiseRejectEvent {
        return c.v8__PromiseRejectMessage__GetEvent(&self.inner);
    }

    pub fn getPromise(self: Self) Promise {
        return .{
            .handle = c.v8__PromiseRejectMessage__GetPromise(&self.inner).?,
        };
    }

    pub fn getValue(self: Self) Value {
        return .{
            .handle = c.v8__PromiseRejectMessage__GetValue(&self.inner).?,
        };
    }
};

pub const FunctionCallbackInfo = struct {
    const Self = @This();

    handle: *const c.FunctionCallbackInfo,

    pub fn initFromV8(val: ?*const c.FunctionCallbackInfo) Self {
        return .{
            .handle = val.?,
        };
    }

    pub fn length(self: Self) u32 {
        return @as(u32, @intCast(c.v8__FunctionCallbackInfo__Length(self.handle)));
    }

    pub fn getIsolate(self: Self) Isolate {
        return .{
            .handle = c.v8__FunctionCallbackInfo__GetIsolate(self.handle).?,
        };
    }

    pub fn getArg(self: Self, i: u32) Value {
        return .{
            .handle = c.v8__FunctionCallbackInfo__INDEX(self.handle, @as(c_int, @intCast(i))).?,
        };
    }

    pub fn getReturnValue(self: Self) ReturnValue {
        var res: c.ReturnValue = undefined;
        c.v8__FunctionCallbackInfo__GetReturnValue(self.handle, &res);
        return .{
            .inner = res,
        };
    }

    pub fn getThis(self: Self) Object {
        return .{
            .handle = c.v8__FunctionCallbackInfo__This(self.handle).?,
        };
    }

    pub fn getData(self: Self) Value {
        return .{
            .handle = c.v8__FunctionCallbackInfo__Data(self.handle).?,
        };
    }

    pub fn getExternalValue(self: Self) ?*anyopaque {
        return self.getData().castTo(External).get();
    }
};

pub const ReturnValue = struct {
    const Self = @This();

    inner: c.ReturnValue,

    pub fn set(self: Self, value: anytype) void {
        c.v8__ReturnValue__Set(self.inner, getValueHandle(value));
    }

    pub fn setValueHandle(self: Self, ptr: *const c.Value) void {
        c.v8__ReturnValue__Set(self.inner, ptr);
    }

    pub fn get(self: Self) Value {
        return .{
            .handle = c.v8__ReturnValue__Get(self.inner).?,
        };
    }
};

pub const FunctionTemplate = struct {
    const Self = @This();

    handle: *const c.FunctionTemplate,

    pub fn initDefault(isolate: Isolate) Self {
        return .{
            .handle = c.v8__FunctionTemplate__New__DEFAULT(isolate.handle).?,
        };
    }

    pub fn initCallback(isolate: Isolate, callback: c.FunctionCallback) Self {
        return .{
            .handle = c.v8__FunctionTemplate__New__DEFAULT2(isolate.handle, callback).?,
        };
    }

    pub fn initCallbackData(isolate: Isolate, callback: c.FunctionCallback, data_val: anytype) Self {
        return .{
            .handle = c.v8__FunctionTemplate__New__DEFAULT3(isolate.handle, callback, getValueHandle(data_val)).?,
        };
    }

    pub fn inherit(self: Self, parent: FunctionTemplate) void {
        c.v8__FunctionTemplate__Inherit(self.handle, parent.handle);
    }

    pub fn setPrototypeProviderTemplate(self: Self, prototype_provider: FunctionTemplate) void {
        c.v8__FunctionTemplate__SetPrototypeProviderTemplate(self.handle, prototype_provider.handle);
    }

    /// This is typically used to set class fields.
    pub fn getInstanceTemplate(self: Self) ObjectTemplate {
        return .{
            .handle = c.v8__FunctionTemplate__InstanceTemplate(self.handle).?,
        };
    }

    /// This is typically used to set class methods.
    pub fn getPrototypeTemplate(self: Self) ObjectTemplate {
        return .{
            .handle = c.v8__FunctionTemplate__PrototypeTemplate(self.handle).?,
        };
    }

    /// There is only one unique function for a FunctionTemplate in a given context.
    /// The Function can then be used to invoke NewInstance which is equivalent to doing js "new".
    pub fn getFunction(self: Self, ctx: Context) Function {
        return .{
            .handle = c.v8__FunctionTemplate__GetFunction(self.handle, ctx.handle).?,
        };
    }

    /// Sets static property on the template.
    pub fn set(self: Self, key: Name, value: anytype, attr: c.PropertyAttribute) void {
        c.v8__Template__Set(getTemplateHandle(self), key.handle, getDataHandle(value), attr);
    }

    pub fn setClassName(self: Self, name: String) void {
        c.v8__FunctionTemplate__SetClassName(self.handle, name.handle);
    }

    pub fn setReadOnlyPrototype(self: Self) void {
        c.v8__FunctionTemplate__ReadOnlyPrototype(self.handle);
    }
};

pub const Function = struct {
    const Self = @This();

    handle: *const c.Function,

    /// Internally, this will create a temporary FunctionTemplate to get a new Function instance.
    pub fn initDefault(ctx: Context, callback: c.FunctionCallback) Self {
        return .{
            .handle = c.v8__Function__New__DEFAULT(ctx.handle, callback).?,
        };
    }

    pub fn initWithData(ctx: Context, callback: c.FunctionCallback, data_val: anytype) Self {
        return .{
            .handle = c.v8__Function__New__DEFAULT2(ctx.handle, callback, getValueHandle(data_val)).?,
        };
    }

    /// receiver_val is "this" in the function context. This is equivalent to calling fn.apply(receiver, args) in JS.
    /// Returns null if there was an error.
    pub fn call(self: Self, ctx: Context, receiver_val: anytype, args: []const Value) ?Value {
        const c_args = @as(?[*]const ?*c.Value, @ptrCast(args.ptr));
        if (c.v8__Function__Call(self.handle, ctx.handle, getValueHandle(receiver_val), @as(c_int, @intCast(args.len)), c_args)) |ret| {
            return Value{
                .handle = ret,
            };
        } else return null;
    }

    // Equivalent to js "new".
    pub fn initInstance(self: Self, ctx: Context, args: []const Value) ?Object {
        const c_args = @as(?[*]const ?*c.Value, @ptrCast(args.ptr));
        if (c.v8__Function__NewInstance(self.handle, ctx.handle, @as(c_int, @intCast(args.len)), c_args)) |ret| {
            return Object{
                .handle = ret,
            };
        } else return null;
    }

    pub fn toObject(self: Self) Object {
        return .{
            .handle = @as(*const c.Object, @ptrCast(self.handle)),
        };
    }

    pub fn toValue(self: Self) Value {
        return .{
            .handle = self.handle,
        };
    }

    pub fn getName(self: Self) Value {
        return .{
            .handle = c.v8__Function__GetName(self.handle).?,
        };
    }

    pub fn setName(self: Self, name: String) void {
        c.v8__Function__SetName(self.handle, name.handle);
    }
};

pub fn Persistent(comptime T: type) type {
    comptime var handleT: type = undefined;
    comptime {
        for (@typeInfo(T).@"struct".fields) |field| {
            if (!std.mem.eql(u8, field.name, "handle")) {
                continue;
            }
            handleT = field.type;
            break;
        }
    }

    return struct {
        const Self = @This();

        handle: handleT,

        /// A new value is created that references the original value.
        /// A Persistent handle is a pointer just like any other value handles,
        /// but when creating and operating on it, an indirect pointer is used to represent a c.Persistent struct (v8::Persistent<v8::Value> in C++).
        pub fn init(isolate: Isolate, data: T) Self {
            var inner_handle: *c.Data = undefined;
            c.v8__Persistent__New(isolate.handle, getDataHandle(data), @as(*c.Persistent, @ptrCast(&inner_handle)));
            return .{
                .handle = @as(@TypeOf(data.handle), @ptrCast(inner_handle)),
            };
        }

        pub fn deinit(self: *Self) void {
            c.v8__Persistent__Reset(@as(*c.Persistent, @ptrCast(&self.handle)));
        }

        pub fn setWeak(self: *Self) void {
            c.v8__Persistent__SetWeak(@as(*c.Persistent, @ptrCast(&self.handle)));
        }

        /// An external pointer can be set when cb_type is kParameter or kInternalFields.
        /// When cb_type is kInternalFields, the object fields are expected to be set with setAlignedPointerInInternalField.
        /// The pointer value must be a multiple of 2 due to how v8 encodes the pointers.
        pub fn setWeakFinalizer(self: *Self, finalizer_ctx: *anyopaque, cb: c.WeakCallback, cb_type: WeakCallbackType) void {
            c.v8__Persistent__SetWeakFinalizer(@as(*c.Persistent, @ptrCast(&self.handle)), finalizer_ctx, cb, @intFromEnum(cb_type));
        }

        /// Should only be called if you know the underlying type is a v8.Function.
        pub fn castToFunction(self: Self) Function {
            return .{
                .handle = @as(*const c.Function, @ptrCast(self.handle)),
            };
        }

        /// Should only be called if you know the underlying type is a v8.Object.
        pub fn castToObject(self: Self) Object {
            return .{
                .handle = @as(*const c.Object, @ptrCast(self.handle)),
            };
        }

        /// Should only be called if you know the underlying type is a v8.PromiseResolver.
        pub fn castToPromiseResolver(self: Self) PromiseResolver {
            return .{
                .handle = @as(*const c.PromiseResolver, @ptrCast(self.handle)),
            };
        }

        pub fn toValue(self: Self) Value {
            return .{
                .handle = self.handle,
            };
        }
    };
}

/// [V8]
/// kParameter will pass a void* parameter back to the callback, kInternalFields
/// will pass the first two internal fields back to the callback, kFinalizer
/// will pass a void* parameter back, but is invoked before the object is
/// actually collected, so it can be resurrected. In the last case, it is not
/// possible to request a second pass callback.
pub const WeakCallbackType = enum(u32) {
    kParameter = c.kParameter,
    kInternalFields = c.kInternalFields,
    kFinalizer = c.kFinalizer,
};

pub const ObjectTemplate = struct {
    const Self = @This();

    handle: *const c.ObjectTemplate,

    pub fn initDefault(isolate: Isolate) Self {
        return .{
            .handle = c.v8__ObjectTemplate__New__DEFAULT(isolate.handle).?,
        };
    }

    pub fn init(isolate: Isolate, constructor: FunctionTemplate) Self {
        return .{
            .handle = c.v8__ObjectTemplate__New(isolate.handle, constructor.handle).?,
        };
    }

    pub fn initInstance(self: Self, ctx: Context) Object {
        return .{
            .handle = c.v8__ObjectTemplate__NewInstance(self.handle, ctx.handle).?,
        };
    }

    pub fn set(self: Self, key: Name, value: anytype, attr: c.PropertyAttribute) void {
        c.v8__Template__Set(getTemplateHandle(self), key.handle, getDataHandle(value), attr);
    }

    pub fn setInternalFieldCount(self: Self, count: u32) void {
        c.v8__ObjectTemplate__SetInternalFieldCount(self.handle, @as(c_int, @intCast(count)));
    }

    pub fn setIndexedProperty(self: Self, configuration: IndexedPropertyHandlerConfiguration, data: anytype) void {
        const conf = c.IndexedPropertyHandlerConfiguration{
            .getter = configuration.getter orelse null,
            .setter = configuration.setter orelse null,
            .query = configuration.query orelse null,
            .deleter = configuration.deleter orelse null,
            .enumerator = configuration.enumerator orelse null,
            .definer = configuration.definer orelse null,
            .descriptor = configuration.descriptor orelse null,
            .data = if (@typeInfo(@TypeOf(data)) == .null) null else getDataHandle(data),
            .flags = configuration.flags,
        };
        c.v8__ObjectTemplate__SetIndexedHandler(self.handle, &conf);
    }

    pub fn setNamedProperty(self: Self, configuration: NamedPropertyHandlerConfiguration, data: anytype) void {
        const conf = c.NamedPropertyHandlerConfiguration{
            .getter = configuration.getter orelse null,
            .setter = configuration.setter orelse null,
            .query = configuration.query orelse null,
            .deleter = configuration.deleter orelse null,
            .enumerator = configuration.enumerator orelse null,
            .definer = configuration.definer orelse null,
            .descriptor = configuration.descriptor orelse null,
            .data = if (@typeInfo(@TypeOf(data)) == .null) null else getDataHandle(data),
            .flags = configuration.flags,
        };
        c.v8__ObjectTemplate__SetNamedHandler(self.handle, &conf);
    }

    pub fn setNativeGetter(self: Self, key: Name, getter: c.AccessorNameGetterCallback) void {
        c.v8__ObjectTemplate__SetNativeDataProperty__DEFAULT(self.handle, key.handle, getter);
    }

    pub fn setNativeGetterSetter(self: Self, key: Name, getter: c.AccessorNameGetterCallback, setter: c.AccessorNameSetterCallback) void {
        c.v8__ObjectTemplate__SetNativeDataProperty__DEFAULT2(self.handle, key.handle, getter, setter);
    }

    pub fn setAccessorGetter(self: Self, name: Name, getter: FunctionTemplate) void {
        c.v8__ObjectTemplate__SetAccessorProperty__DEFAULT(self.handle, name.handle, getter.handle);
    }

    pub fn setAccessorGetterAndSetter(self: Self, name: Name, getter: FunctionTemplate, setter: FunctionTemplate) void {
        c.v8__ObjectTemplate__SetAccessorProperty__DEFAULT2(self.handle, name.handle, getter.handle, setter.handle);
    }

    pub fn toValue(self: Self) Value {
        return .{
            .handle = self.handle,
        };
    }
};

pub const Array = struct {
    const Self = @This();

    handle: *const c.Array,

    pub fn init(iso: Isolate, len: u32) Self {
        return .{
            .handle = c.v8__Array__New(iso.handle, @as(c_int, @intCast(len))).?,
        };
    }

    pub fn initElements(iso: Isolate, elems: []const Value) Self {
        const c_elems = @as(?[*]const ?*c.Value, @ptrCast(elems.ptr));
        return .{
            .handle = c.v8__Array__New2(iso.handle, c_elems, elems.len).?,
        };
    }

    pub fn length(self: Self) u32 {
        return c.v8__Array__Length(self.handle);
    }

    pub fn castTo(self: Self, comptime T: type) T {
        switch (T) {
            Object => {
                return .{
                    .handle = @as(*const c.Object, @ptrCast(self.handle)),
                };
            },
            else => unreachable,
        }
    }
};

pub const Object = struct {
    const Self = @This();

    handle: *const c.Object,

    pub fn init(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Object__New(isolate.handle).?,
        };
    }

    pub fn getConstructorName(self: Self) !String {
        return String{
            .handle = c.v8__Object__GetConstructorName(self.handle) orelse return error.JsException,
        };
    }

    pub fn setInternalField(self: Self, idx: u32, value: anytype) void {
        c.v8__Object__SetInternalField(self.handle, @as(c_int, @intCast(idx)), getValueHandle(value));
    }

    pub fn getInternalField(self: Self, idx: u32) Value {
        return .{
            .handle = c.v8__Object__GetInternalField(self.handle, @as(c_int, @intCast(idx))).?,
        };
    }

    pub fn internalFieldCount(self: Self) usize {
        return @intCast(c.v8__Object__InternalFieldCount(self.handle));
    }

    pub fn setAlignedPointerInInternalField(self: Self, idx: u32, ptr: ?*anyopaque) void {
        c.v8__Object__SetAlignedPointerInInternalField(self.handle, @as(c_int, @intCast(idx)), ptr);
    }

    // Returns true on success, false on fail.
    pub fn setValue(self: Self, ctx: Context, key: anytype, value: anytype) bool {
        var out: c.MaybeBool = undefined;
        c.v8__Object__Set(self.handle, ctx.handle, getValueHandle(key), getValueHandle(value), &out);
        // Set only returns empty for an error or true.
        return out.has_value;
    }

    // Returns true on success, false on fail.
    pub fn deleteValue(self: Self, ctx: Context, key: anytype) bool {
        var out: c.MaybeBool = undefined;
        c.v8__Object__Delete(self.handle, ctx.handle, getValueHandle(key), &out);
        // Set only returns empty for an error or true.
        return out.has_value;
    }

    pub fn setValueAtIndex(self: Self, ctx: Context, idx: u32, value: anytype) bool {
        var out: c.MaybeBool = undefined;
        c.v8__Object__SetAtIndex(self.handle, ctx.handle, idx, getValueHandle(value), &out);
        // Set only returns empty for an error or true.
        return out.has_value;
    }

    pub fn getValue(self: Self, ctx: Context, key: anytype) !Value {
        if (c.v8__Object__Get(self.handle, ctx.handle, getValueHandle(key))) |handle| {
            return Value{
                .handle = handle,
            };
        } else return error.JsException;
    }

    pub fn getAtIndex(self: Self, ctx: Context, idx: u32) !Value {
        if (c.v8__Object__GetIndex(self.handle, ctx.handle, idx)) |handle| {
            return Value{
                .handle = handle,
            };
        } else return error.JsException;
    }

    pub fn toValue(self: Self) Value {
        return .{
            .handle = self.handle,
        };
    }

    pub fn defineOwnProperty(self: Self, ctx: Context, name: Name, value: anytype, attr: c.PropertyAttribute) ?bool {
        var out: c.MaybeBool = undefined;
        c.v8__Object__DefineOwnProperty(self.handle, ctx.handle, name.handle, getValueHandle(value), attr, &out);
        if (out.has_value) {
            return out.value;
        } else return null;
    }

    pub fn getIsolate(self: Self) Isolate {
        return .{
            .handle = c.v8__Object__GetIsolate(self.handle).?,
        };
    }

    pub fn getCreationContext(self: Self) Context {
        return .{
            .handle = c.v8__Object__GetCreationContext(self.handle).?,
        };
    }

    pub fn getIdentityHash(self: Self) u32 {
        return @as(u32, @bitCast(c.v8__Object__GetIdentityHash(self.handle)));
    }

    pub fn has(self: Self, ctx: Context, key: Value) bool {
        var out: c.MaybeBool = undefined;
        c.v8__Object__Has(self.handle, ctx.handle, key.handle, &out);
        if (out.has_value) {
            return out.value;
        } else return false;
    }

    pub fn hasIndex(self: Self, ctx: Context, idx: u32) bool {
        var out: c.MaybeBool = undefined;
        c.v8__Object__Has(self.handle, ctx.handle, idx, &out);
        if (out.has_value) {
            return out.value;
        } else return false;
    }

    pub fn getOwnPropertyNames(self: Self, ctx: Context) Array {
        return .{
            .handle = c.v8__Object__GetOwnPropertyNames(self.handle, ctx.handle).?,
        };
    }

    pub fn getPropertyNames(self: Self, ctx: Context) Array {
        return .{
            .handle = c.v8__Object__GetPropertyNames(self.handle, ctx.handle).?,
        };
    }

    pub fn getPrototype(self: Self) Value {
        return .{
            .handle = c.v8__Object__GetPrototype(self.handle).?,
        };
    }

    pub fn setPrototype(self: Self, ctx: Context, prototype: Object) bool {
        var out: c.MaybeBool = undefined;
        c.v8__Object__SetPrototype(self.handle, ctx.handle, prototype.handle, &out);
        if (out.has_value) {
            return out.value;
        } else return false;
    }
};

pub const External = struct {
    const Self = @This();

    handle: *const c.External,

    pub fn init(isolate: Isolate, val: ?*anyopaque) Self {
        return .{
            .handle = c.v8__External__New(isolate.handle, val).?,
        };
    }

    pub fn get(self: Self) ?*anyopaque {
        return c.v8__External__Value(self.handle);
    }

    pub fn toValue(self: Self) Value {
        return .{
            .handle = self.handle,
        };
    }
};

pub const Name = struct {
    handle: *const c.Name,
};

pub const Symbol = struct {
    const Self = @This();

    handle: *const c.Symbol,

    pub fn toName(self: Self) Name {
        return .{
            .handle = @as(*const c.Name, @ptrCast(self.handle)),
        };
    }

    // well-known symbols

    pub fn getAsyncIterator(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetAsyncIterator(isolate.handle).?,
        };
    }

    pub fn getHasInstance(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetHasInstance(isolate.handle).?,
        };
    }

    pub fn getIsConcatSpreadable(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetIsConcatSpreadable(isolate.handle).?,
        };
    }

    pub fn getIterator(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetIterator(isolate.handle).?,
        };
    }

    pub fn getMatch(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetMatch(isolate.handle).?,
        };
    }

    pub fn getReplace(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetReplace(isolate.handle).?,
        };
    }

    pub fn getSearch(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetSearch(isolate.handle).?,
        };
    }

    pub fn getSplit(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetSplit(isolate.handle).?,
        };
    }

    pub fn getToPrimitive(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetToPrimitive(isolate.handle).?,
        };
    }

    pub fn getToStringTag(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetToStringTag(isolate.handle).?,
        };
    }

    pub fn getUnscopables(isolate: Isolate) Self {
        return .{
            .handle = c.v8__Symbol__GetUnscopables(isolate.handle).?,
        };
    }
};

pub const Number = struct {
    const Self = @This();

    handle: *const c.Number,

    pub fn init(isolate: Isolate, val: f64) Self {
        return .{
            .handle = c.v8__Number__New(isolate.handle, val).?,
        };
    }

    pub fn initBitCastedI64(isolate: Isolate, val: i64) Self {
        return init(isolate, @as(f64, @bitCast(val)));
    }

    pub fn initBitCastedU64(isolate: Isolate, val: u64) Self {
        return init(isolate, @as(f64, @bitCast(val)));
    }

    pub fn toValue(self: Self) Value {
        return .{
            .handle = self.handle,
        };
    }
};

pub const Integer = struct {
    const Self = @This();

    handle: *const c.Integer,

    pub fn initI32(isolate: Isolate, val: i32) Self {
        return .{
            .handle = c.v8__Integer__New(isolate.handle, val).?,
        };
    }

    pub fn initU32(isolate: Isolate, val: u32) Self {
        return .{
            .handle = c.v8__Integer__NewFromUnsigned(isolate.handle, val).?,
        };
    }

    pub fn getValue(self: Self) u64 {
        return c.v8__Integer__Value(self.handle);
    }

    pub fn getValueU32(self: Self) u32 {
        return @as(u32, @intCast(c.v8__Integer__Value(self.handle)));
    }

    pub fn toValue(self: Self) Value {
        return .{
            .handle = self.handle,
        };
    }
};

pub const BigInt = struct {
    const Self = @This();

    handle: *const c.Integer,

    pub fn initI64(iso: Isolate, val: i64) Self {
        return .{
            .handle = c.v8__BigInt__New(iso.handle, val).?,
        };
    }

    pub fn initU64(iso: Isolate, val: u64) Self {
        return .{
            .handle = c.v8__BigInt__NewFromUnsigned(iso.handle, val).?,
        };
    }

    pub fn getUint64(self: Self) u64 {
        return c.v8__BigInt__Uint64Value(self.handle, null);
    }

    pub fn getInt64(self: Self) i64 {
        return c.v8__BigInt__Int64Value(self.handle, null);
    }
};

pub inline fn getValue(val: anytype) Value {
    return .{
        .handle = getValueHandle(val),
    };
}

inline fn getValueHandle(val: anytype) *const c.Value {
    return @as(*const c.Value, @ptrCast(val.handle));
}

inline fn getTemplateHandle(val: anytype) *const c.Template {
    return @as(*const c.Template, @ptrCast(val.handle));
}

inline fn getDataHandle(val: anytype) *const c.Data {
    return @as(*const c.Data, @ptrCast(val.handle));
}

pub const Message = struct {
    const Self = @This();

    handle: *const c.Message,

    pub fn getMessage(self: Self) String {
        return String{
            .handle = c.v8__Message__Get(self.handle).?,
        };
    }

    pub fn getSourceLine(self: Self, ctx: Context) ?String {
        if (c.v8__Message__GetSourceLine(self.handle, ctx.handle)) |string| {
            return String{
                .handle = string,
            };
        } else return null;
    }

    pub fn getScriptResourceName(self: Self) Value {
        return .{
            .handle = c.v8__Message__GetScriptResourceName(self.handle).?,
        };
    }

    pub fn getLineNumber(self: Self, ctx: Context) ?u32 {
        const res = c.v8__Message__GetLineNumber(self.handle, ctx.handle);
        if (res != -1) {
            return @as(u32, @intCast(res));
        } else return null;
    }

    pub fn getStartColumn(self: Self) ?u32 {
        const res = c.v8__Message__GetStartColumn(self.handle);
        if (res != -1) {
            return @as(u32, @intCast(res));
        } else return null;
    }

    pub fn getEndColumn(self: Self) ?u32 {
        const res = c.v8__Message__GetEndColumn(self.handle);
        if (res != -1) {
            return @as(u32, @intCast(res));
        } else return null;
    }

    /// [v8] Exception stack trace. By default stack traces are not captured for
    ///      uncaught exceptions. SetCaptureStackTraceForUncaughtExceptions allows
    ///      to change this option.
    pub fn getStackTrace(self: Self) ?StackTrace {
        if (c.v8__Message__GetStackTrace(self.handle)) |trace| {
            return StackTrace{
                .handle = trace,
            };
        } else return null;
    }
};

pub const StackTrace = struct {
    const Self = @This();

    handle: *const c.StackTrace,

    pub fn getFrameCount(self: Self) u32 {
        return @as(u32, @intCast(c.v8__StackTrace__GetFrameCount(self.handle)));
    }

    pub fn getFrame(self: Self, iso: Isolate, idx: u32) StackFrame {
        return .{
            .handle = c.v8__StackTrace__GetFrame(self.handle, iso.handle, idx).?,
        };
    }

    pub fn getCurrentStackTrace(iso: Isolate, frame_limit: u32) StackTrace {
        return .{
            .handle = c.v8__StackTrace__CurrentStackTrace__STATIC(iso.handle, @as(c_int, @intCast(frame_limit))).?,
        };
    }

    pub fn getCurrentScriptNameOrSourceUrl(iso: Isolate) String {
        return .{
            .handle = c.v8__StackTrace__CurrentScriptNameOrSourceURL__STATIC(iso.handle).?,
        };
    }
};

pub const StackFrame = struct {
    const Self = @This();

    handle: *const c.StackFrame,

    pub fn getLineNumber(self: Self) u32 {
        return @as(u32, @intCast(c.v8__StackFrame__GetLineNumber(self.handle)));
    }

    pub fn getColumn(self: Self) u32 {
        return @as(u32, @intCast(c.v8__StackFrame__GetColumn(self.handle)));
    }

    pub fn getScriptId(self: Self) u32 {
        return @as(u32, @intCast(c.v8__StackFrame__GetScriptId(self.handle)));
    }

    pub fn getScriptName(self: Self) String {
        return .{
            .handle = c.v8__StackFrame__GetScriptName(self.handle).?,
        };
    }

    pub fn getScriptNameOrSourceUrl(self: Self) String {
        return .{
            .handle = c.v8__StackFrame__GetScriptNameOrSourceURL(self.handle).?,
        };
    }

    pub fn getFunctionName(self: Self) ?String {
        if (c.v8__StackFrame__GetFunctionName(self.handle)) |ptr| {
            return String{
                .handle = ptr,
            };
        } else return null;
    }

    pub fn isEval(self: Self) bool {
        return c.v8__StackFrame__IsEval(self.handle);
    }

    pub fn isConstructor(self: Self) bool {
        return c.v8__StackFrame__IsConstructor(self.handle);
    }

    pub fn isWasm(self: Self) bool {
        return c.v8__StackFrame__IsWasm(self.handle);
    }

    pub fn isUserJavascript(self: Self) bool {
        return c.v8__StackFrame__IsUserJavaScript(self.handle);
    }
};

pub const TryCatch = struct {
    const Self = @This();

    inner: c.TryCatch,

    // TryCatch is wrapped in a v8::Local so have to initialize in place.
    pub fn init(self: *Self, isolate: Isolate) void {
        c.v8__TryCatch__CONSTRUCT(&self.inner, isolate.handle);
    }

    pub fn deinit(self: *Self) void {
        c.v8__TryCatch__DESTRUCT(&self.inner);
    }

    pub fn hasCaught(self: Self) bool {
        return c.v8__TryCatch__HasCaught(&self.inner);
    }

    pub fn getException(self: Self) ?Value {
        if (c.v8__TryCatch__Exception(&self.inner)) |exception| {
            return Value{
                .handle = exception,
            };
        } else return null;
    }

    pub fn getStackTrace(self: Self, ctx: Context) ?Value {
        if (c.v8__TryCatch__StackTrace(&self.inner, ctx.handle)) |value| {
            return Value{
                .handle = value,
            };
        } else return null;
    }

    pub fn getMessage(self: Self) ?Message {
        if (c.v8__TryCatch__Message(&self.inner)) |message| {
            return Message{
                .handle = message,
            };
        } else return null;
    }

    pub fn isVerbose(self: Self) bool {
        return c.v8__TryCatch__IsVerbose(&self.inner);
    }

    pub fn setVerbose(self: *Self, verbose: bool) void {
        c.v8__TryCatch__SetVerbose(&self.inner, verbose);
    }

    pub fn rethrow(self: *Self) Value {
        return .{
            .handle = c.v8__TryCatch__ReThrow(&self.inner).?,
        };
    }
};

pub const ScriptOrigin = struct {
    const Self = @This();

    inner: c.ScriptOrigin,

    pub fn initDefault(resource_name: Value) Self {
        var inner: c.ScriptOrigin = undefined;
        c.v8__ScriptOrigin__CONSTRUCT(&inner, resource_name.handle);
        return .{
            .inner = inner,
        };
    }

    pub fn init(
        resource_name: Value,
        resource_line_offset: i32,
        resource_column_offset: i32,
        resource_is_shared_cross_origin: bool,
        script_id: i32,
        source_map_url: ?Value,
        resource_is_opaque: bool,
        is_wasm: bool,
        is_module: bool,
        host_defined_options: ?Data,
    ) Self {
        var inner: c.ScriptOrigin = undefined;
        c.v8__ScriptOrigin__CONSTRUCT2(
            &inner,
            resource_name.handle,
            resource_line_offset,
            resource_column_offset,
            resource_is_shared_cross_origin,
            script_id,
            if (source_map_url != null) source_map_url.?.handle else null,
            resource_is_opaque,
            is_wasm,
            is_module,
            if (host_defined_options != null) host_defined_options.?.handle else null,
        );
        return .{
            .inner = inner,
        };
    }
};

pub const Boolean = struct {
    const Self = @This();

    handle: *const c.Boolean,

    pub fn init(isolate: Isolate, val: bool) Self {
        return .{
            .handle = c.v8__Boolean__New(isolate.handle, val).?,
        };
    }
};

pub const String = struct {
    const Self = @This();

    handle: *const c.String,

    pub fn initUtf8(isolate: Isolate, str: []const u8) Self {
        return .{
            .handle = c.v8__String__NewFromUtf8(isolate.handle, str.ptr, c.kNormal, @as(c_int, @intCast(str.len))).?,
        };
    }

    pub fn lenUtf8(self: Self, isolate: Isolate) u32 {
        return @as(u32, @intCast(c.v8__String__Utf8Length(self.handle, isolate.handle)));
    }


    pub fn writeUtf8(self: String, isolate: Isolate, buf: []const u8) usize {
        const options = c.NO_NULL_TERMINATION | c.REPLACE_INVALID_UTF8;
        return c.v8__String__WriteUtf8(self.handle, isolate.handle, buf.ptr, buf.len, options);
    }

    pub fn toValue(self: Self) Value {
        return .{
            .handle = self.handle,
        };
    }

    pub fn toName(self: Self) Name {
        return .{
            .handle = @as(*const c.Name, @ptrCast(self.handle)),
        };
    }
};

pub const ScriptCompilerSource = struct {
    const Self = @This();

    inner: c.ScriptCompilerSource,

    pub fn init(self: *Self, src: String, mb_origin: ?ScriptOrigin, cached_data: ?ScriptCompilerCachedData) void {
        const cached_data_ptr = if (cached_data != null) cached_data.?.handle else null;
        if (mb_origin) |origin| {
            c.v8__ScriptCompiler__Source__CONSTRUCT2(src.handle, &origin.inner, cached_data_ptr, &self.inner);
        } else {
            c.v8__ScriptCompiler__Source__CONSTRUCT(src.handle, cached_data_ptr, &self.inner);
        }
    }

    pub fn deinit(self: *Self) void {
        c.v8__ScriptCompiler__Source__DESTRUCT(&self.inner);
    }
};

pub const ScriptCompilerCachedData = struct {
    const Self = @This();

    handle: *c.ScriptCompilerCachedData,

    pub fn init(data: []const u8) Self {
        return .{
            .handle = c.v8__ScriptCompiler__CachedData__NEW(data.ptr, @as(c_int, @intCast(data.len))).?,
        };
    }

    pub fn deinit(self: Self) void {
        c.v8__ScriptCompiler__CachedData__DELETE(self.handle);
    }
};

pub const ScriptCompiler = struct {
    const CompileOptions = enum(u32) {
        kNoCompileOptions = c.kNoCompileOptions,
        kConsumeCodeCache = c.kConsumeCodeCache,
        kEagerCompile = c.kEagerCompile,
    };

    const NoCacheReason = enum(u32) {
        kNoCacheNoReason = c.kNoCacheNoReason,
        kNoCacheBecauseCachingDisabled = c.kNoCacheBecauseCachingDisabled,
        kNoCacheBecauseNoResource = c.kNoCacheBecauseNoResource,
        kNoCacheBecauseInlineScript = c.kNoCacheBecauseInlineScript,
        kNoCacheBecauseModule = c.kNoCacheBecauseModule,
        kNoCacheBecauseStreamingSource = c.kNoCacheBecauseStreamingSource,
        kNoCacheBecauseInspector = c.kNoCacheBecauseInspector,
        kNoCacheBecauseScriptTooSmall = c.kNoCacheBecauseScriptTooSmall,
        kNoCacheBecauseCacheTooCold = c.kNoCacheBecauseCacheTooCold,
        kNoCacheBecauseV8Extension = c.kNoCacheBecauseV8Extension,
        kNoCacheBecauseExtensionModule = c.kNoCacheBecauseExtensionModule,
        kNoCacheBecausePacScript = c.kNoCacheBecausePacScript,
        kNoCacheBecauseInDocumentWrite = c.kNoCacheBecauseInDocumentWrite,
        kNoCacheBecauseResourceWithNoCacheHandler = c.kNoCacheBecauseResourceWithNoCacheHandler,
        kNoCacheBecauseDeferredProduceCodeCache = c.kNoCacheBecauseDeferredProduceCodeCache,
    };

    /// [v8]
    /// Compile an ES module, returning a Module that encapsulates the compiled code.
    /// Corresponds to the ParseModule abstract operation in the ECMAScript specification.
    pub fn compileModule(iso: Isolate, src: *ScriptCompilerSource, options: ScriptCompiler.CompileOptions, reason: ScriptCompiler.NoCacheReason) !Module {
        const mb_res = c.v8__ScriptCompiler__CompileModule(
            iso.handle,
            &src.inner,
            @intFromEnum(options),
            @intFromEnum(reason),
        );
        if (mb_res) |res| {
            return Module{
                .handle = res,
            };
        } else return error.JsException;
    }
};

pub const Script = struct {
    const Self = @This();

    handle: *const c.Script,

    /// [v8]
    /// A shorthand for ScriptCompiler::Compile().
    pub fn compile(ctx: Context, src: String, origin: ?ScriptOrigin) !Self {
        if (c.v8__Script__Compile(ctx.handle, src.handle, if (origin != null) &origin.?.inner else null)) |handle| {
            return Self{
                .handle = handle,
            };
        } else return error.JsException;
    }

    pub fn run(self: Self, ctx: Context) !Value {
        if (c.v8__Script__Run(self.handle, ctx.handle)) |value| {
            return Value{
                .handle = value,
            };
        } else return error.JsException;
    }
};

pub const Module = struct {
    const Self = @This();

    const Status = enum(u32) {
        kUninstantiated = c.kUninstantiated,
        kInstantiating = c.kInstantiating,
        kInstantiated = c.kInstantiated,
        kEvaluating = c.kEvaluating,
        kEvaluated = c.kEvaluated,
        kErrored = c.kErrored,
    };

    handle: *const c.Module,

    pub fn getStatus(self: Self) Status {
        return @as(Status, @enumFromInt(c.v8__Module__GetStatus(self.handle)));
    }

    pub fn getException(self: Self) Value {
        return .{
            .handle = c.v8__Module__GetException(self.handle).?,
        };
    }

    pub fn getModuleRequests(self: Self) FixedArray {
        return .{
            .handle = c.v8__Module__GetModuleRequests(self.handle).?,
        };
    }

    /// [v8]
    /// Instantiates the module and its dependencies.
    ///
    /// Returns an empty Maybe<bool> if an exception occurred during
    /// instantiation. (In the case where the callback throws an exception, that
    /// exception is propagated.)
    pub fn instantiate(self: Self, ctx: Context, cb: c.ResolveModuleCallback) !bool {
        var out: c.MaybeBool = undefined;
        c.v8__Module__InstantiateModule(self.handle, ctx.handle, cb, &out);
        if (out.has_value) {
            return out.value;
        } else return error.JsException;
    }

    /// Evaluates the module, assumes module has been instantiated.
    /// [v8]
    /// Evaluates the module and its dependencies.
    ///
    /// If status is kInstantiated, run the module's code and return a Promise
    /// object. On success, set status to kEvaluated and resolve the Promise with
    /// the completion value; on failure, set status to kErrored and reject the
    /// Promise with the error.
    ///
    /// If IsGraphAsync() is false, the returned Promise is settled.
    pub fn evaluate(self: Self, ctx: Context) !Value {
        if (c.v8__Module__Evaluate(self.handle, ctx.handle)) |res| {
            return Value{
                .handle = res,
            };
        } else return error.JsException;
    }

    pub fn getIdentityHash(self: Self) u32 {
        return @as(u32, @bitCast(c.v8__Module__GetIdentityHash(self.handle)));
    }

    pub fn getScriptId(self: Self) u32 {
        return @as(u32, @intCast(c.v8__Module__ScriptId(self.handle)));
    }
};

pub const ModuleRequest = struct {
    const Self = @This();

    handle: *const c.ModuleRequest,

    /// Returns the specifier of the import inside the double quotes
    pub fn getSpecifier(self: Self) String {
        return .{
            .handle = c.v8__ModuleRequest__GetSpecifier(self.handle).?,
        };
    }

    /// Returns the offset from the start of the source code.
    pub fn getSourceOffset(self: Self) u32 {
        return @as(u32, @intCast(c.v8__ModuleRequest__GetSourceOffset(self.handle)));
    }
};

pub const Data = struct {
    const Self = @This();

    handle: *const c.Data,

    /// Should only be called if you know the underlying type.
    pub fn castTo(self: Self, comptime T: type) T {
        switch (T) {
            ModuleRequest => {
                return .{
                    .handle = self.handle,
                };
            },
            else => unreachable,
        }
    }
};

pub const Value = struct {
    const Self = @This();

    handle: *const c.Value,

    pub fn typeOf(self: Self, isolate: Isolate) !String {
        return String{
            .handle = c.v8__Value__TypeOf(self.handle, isolate.handle) orelse return error.JsException,
        };
    }

    pub fn toString(self: Self, ctx: Context) !String {
        return String{
            .handle = c.v8__Value__ToString(self.handle, ctx.handle) orelse return error.JsException,
        };
    }

    pub fn toDetailString(self: Self, ctx: Context) !String {
        return String{
            .handle = c.v8__Value__ToDetailString(self.handle, ctx.handle) orelse return error.JsException,
        };
    }

    pub fn toBool(self: Self, isolate: Isolate) bool {
        return c.v8__Value__BooleanValue(self.handle, isolate.handle);
    }

    pub fn toI32(self: Self, ctx: Context) !i32 {
        var out: c.MaybeI32 = undefined;
        c.v8__Value__Int32Value(self.handle, ctx.handle, &out);
        if (out.has_value) {
            return out.value;
        } else return error.JsException;
    }

    pub fn toU32(self: Self, ctx: Context) !u32 {
        var out: c.MaybeU32 = undefined;
        c.v8__Value__Uint32Value(self.handle, ctx.handle, &out);
        if (out.has_value) {
            return out.value;
        } else return error.JsException;
    }

    pub fn toF32(self: Self, ctx: Context) !f32 {
        var out: c.MaybeF64 = undefined;
        c.v8__Value__NumberValue(self.handle, ctx.handle, &out);
        if (out.has_value) {
            return @as(f32, @floatCast(out.value));
        } else return error.JsException;
    }

    pub fn toF64(self: Self, ctx: Context) !f64 {
        var out: c.MaybeF64 = undefined;
        c.v8__Value__NumberValue(self.handle, ctx.handle, &out);
        if (out.has_value) {
            return out.value;
        } else return error.JsException;
    }

    pub fn bitCastToI64(self: Self, ctx: Context) !i64 {
        var out: c.MaybeF64 = undefined;
        c.v8__Value__NumberValue(self.handle, ctx.handle, &out);
        if (out.has_value) {
            return @as(i64, @bitCast(out.value));
        } else return error.JsException;
    }

    pub fn bitCastToU64(self: Self, ctx: Context) !u64 {
        var out: c.MaybeF64 = undefined;
        c.v8__Value__NumberValue(self.handle, ctx.handle, &out);
        if (out.has_value) {
            return @as(u64, @bitCast(out.value));
        } else return error.JsException;
    }

    pub fn instanceOf(self: Self, ctx: Context, obj: Object) !bool {
        var out: c.MaybeBool = undefined;
        c.v8__Value__InstanceOf(self.handle, ctx.handle, obj.handle, &out);
        if (out.has_value) {
            return out.value;
        } else return error.JsException;
    }

    pub fn isObject(self: Self) bool {
        return c.v8__Value__IsObject(self.handle);
    }

    pub fn isString(self: Self) bool {
        return c.v8__Value__IsString(self.handle);
    }

    pub fn isFunction(self: Self) bool {
        return c.v8__Value__IsFunction(self.handle);
    }

    pub fn isAsyncFunction(self: Self) bool {
        return c.v8__Value__IsAsyncFunction(self.handle);
    }

    pub fn isArray(self: Self) bool {
        return c.v8__Value__IsArray(self.handle);
    }

    pub fn isTypedArray(self: Self) bool {
        return c.v8__Value__IsTypedArray(self.handle);
    }

    pub fn isUint8Array(self: Self) bool {
        return c.v8__Value__IsUint8Array(self.handle);
    }

    pub fn isUint8ClampedArray(self: Self) bool {
        return c.v8__Value__IsUint8ClampedArray(self.handle);
    }

    pub fn isInt8Array(self: Self) bool {
        return c.v8__Value__IsInt8Array(self.handle);
    }

    pub fn isUint16Array(self: Self) bool {
        return c.v8__Value__IsUint16Array(self.handle);
    }

    pub fn isInt16Array(self: Self) bool {
        return c.v8__Value__IsInt16Array(self.handle);
    }

    pub fn isUint32Array(self: Self) bool {
        return c.v8__Value__IsUint32Array(self.handle);
    }

    pub fn isInt32Array(self: Self) bool {
        return c.v8__Value__IsInt32Array(self.handle);
    }

    pub fn isFloat32Array(self: Self) bool {
        return c.v8__Value__IsFloat32Array(self.handle);
    }

    pub fn isFloat64Array(self: Self) bool {
        return c.v8__Value__IsFloat64Array(self.handle);
    }

    pub fn isArrayBuffer(self: Self) bool {
        return c.v8__Value__IsArrayBuffer(self.handle);
    }

    pub fn isArrayBufferView(self: Self) bool {
        return c.v8__Value__IsArrayBufferView(self.handle);
    }

    pub fn isExternal(self: Self) bool {
        return c.v8__Value__IsExternal(self.handle);
    }

    pub fn isTrue(self: Self) bool {
        return c.v8__Value__IsTrue(self.handle);
    }

    pub fn isFalse(self: Self) bool {
        return c.v8__Value__IsFalse(self.handle);
    }

    pub fn isUndefined(self: Self) bool {
        return c.v8__Value__IsUndefined(self.handle);
    }

    pub fn isNull(self: Self) bool {
        return c.v8__Value__IsNull(self.handle);
    }

    pub fn isNullOrUndefined(self: Self) bool {
        return c.v8__Value__IsNullOrUndefined(self.handle);
    }

    pub fn isNativeError(self: Self) bool {
        return c.v8__Value__IsNativeError(self.handle);
    }

    pub fn isBigInt(self: Self) bool {
        return c.v8__Value__IsBigInt(self.handle);
    }

    pub fn isBigIntObject(self: Self) bool {
        return c.v8__Value__IsBigIntObject(self.handle);
    }

    /// Should only be called if you know the underlying type.
    pub fn castTo(self: Self, comptime T: type) T {
        switch (T) {
            Object,
            Function,
            Array,
            Promise,
            External,
            Integer,
            BigInt,
            Boolean,
            ArrayBuffer,
            ArrayBufferView,
            Uint8Array,
            String,
            => {
                return .{
                    .handle = self.handle,
                };
            },
            else => unreachable,
        }
    }
};

pub const Primitive = struct {
    const Self = @This();

    handle: *const c.Primitive,

    pub fn toValue(self: Self) Value {
        return .{
            .handle = self.handle,
        };
    }
};

pub fn initUndefined(isolate: Isolate) Primitive {
    return .{
        .handle = c.v8__Undefined(isolate.handle).?,
    };
}

pub fn initNull(isolate: Isolate) Primitive {
    return .{
        .handle = c.v8__Null(isolate.handle).?,
    };
}

pub fn initTrue(isolate: Isolate) Boolean {
    return .{
        .handle = c.v8__True(isolate.handle).?,
    };
}

pub fn initFalse(isolate: Isolate) Boolean {
    return .{
        .handle = c.v8__False(isolate.handle).?,
    };
}

pub const Promise = struct {
    const Self = @This();

    pub const State = enum(u32) {
        kPending = c.kPending,
        kFulfilled = c.kFulfilled,
        kRejected = c.kRejected,
    };

    handle: *const c.Promise,

    /// [V8]
    /// Register a resolution/rejection handler with a promise.
    /// The handler is given the respective resolution/rejection value as
    /// an argument. If the promise is already resolved/rejected, the handler is
    /// invoked at the end of turn.
    pub fn onCatch(self: Self, ctx: Context, handler: Function) !Promise {
        if (c.v8__Promise__Catch(self.handle, ctx.handle, handler.handle)) |handle| {
            return Promise{ .handle = handle };
        } else return error.JsException;
    }

    pub fn then(self: Self, ctx: Context, handler: Function) !Promise {
        if (c.v8__Promise__Then(self.handle, ctx.handle, handler.handle)) |handle| {
            return Promise{ .handle = handle };
        } else return error.JsException;
    }

    pub fn thenAndCatch(self: Self, ctx: Context, on_fulfilled: Function, on_rejected: Function) !Promise {
        if (c.v8__Promise__Then2(self.handle, ctx.handle, on_fulfilled.handle, on_rejected.handle)) |handle| {
            return Promise{ .handle = handle };
        } else return error.JsException;
    }

    pub fn getState(self: Self) State {
        return @as(State, @enumFromInt(c.v8__Promise__State(self.handle)));
    }

    /// [V8]
    /// Marks this promise as handled to avoid reporting unhandled rejections.
    pub fn markAsHandled(self: Self) void {
        c.v8__Promise__MarkAsHandled(self.handle);
    }

    pub fn toObject(self: Self) Object {
        return .{
            .handle = @as(*const c.Object, @ptrCast(self.handle)),
        };
    }

    /// [V8]
    /// Returns the content of the [[PromiseResult]] field. The Promise must not be pending.
    pub fn getResult(self: Self) Value {
        return .{
            .handle = c.v8__Promise__Result(self.handle).?,
        };
    }
};

pub const PromiseResolver = struct {
    const Self = @This();

    handle: *const c.PromiseResolver,

    pub fn init(ctx: Context) Self {
        return .{
            .handle = c.v8__Promise__Resolver__New(ctx.handle).?,
        };
    }

    pub fn getPromise(self: Self) Promise {
        return .{
            .handle = c.v8__Promise__Resolver__GetPromise(self.handle).?,
        };
    }

    /// Resolve will continue execution of any yielding generators.
    pub fn resolve(self: Self, ctx: Context, val: Value) ?bool {
        var out: c.MaybeBool = undefined;
        c.v8__Promise__Resolver__Resolve(self.handle, ctx.handle, val.handle, &out);
        if (out.has_value) {
            return out.value;
        } else return null;
    }

    /// Reject will continue execution of any yielding generators.
    pub fn reject(self: Self, ctx: Context, val: Value) ?bool {
        var out: c.MaybeBool = undefined;
        c.v8__Promise__Resolver__Reject(self.handle, ctx.handle, val.handle, &out);
        if (out.has_value) {
            return out.value;
        } else return null;
    }
};

pub const BackingStore = struct {
    const Self = @This();

    handle: *c.BackingStore,

    /// Underlying handle is initially unmanaged.
    pub fn init(iso: Isolate, len: usize) Self {
        return .{
            .handle = c.v8__ArrayBuffer__NewBackingStore(iso.handle, len).?,
        };
    }

    /// Returns null if len is 0.
    pub fn getData(self: Self) ?*anyopaque {
        return c.v8__BackingStore__Data(self.handle);
    }

    pub fn getByteLength(self: Self) usize {
        return c.v8__BackingStore__ByteLength(self.handle);
    }

    pub fn isShared(self: Self) bool {
        return c.v8__BackingStore__IsShared(self.handle);
    }

    pub fn toSharedPtr(self: Self) SharedPtr {
        return c.v8__BackingStore__TO_SHARED_PTR(self.handle);
    }

    pub fn sharedPtrReset(ptr: *SharedPtr) void {
        c.std__shared_ptr__v8__BackingStore__reset(ptr);
    }

    pub fn sharedPtrGet(ptr: *const SharedPtr) Self {
        return .{
            .handle = c.std__shared_ptr__v8__BackingStore__get(ptr).?,
        };
    }

    pub fn sharedPtrUseCount(ptr: *const SharedPtr) u32 {
        return @as(u32, @intCast(c.std__shared_ptr__v8__BackingStore__use_count(ptr)));
    }
};

pub const ArrayBuffer = struct {
    const Self = @This();

    handle: *const c.ArrayBuffer,

    pub fn init(iso: Isolate, len: usize) Self {
        return .{
            .handle = c.v8__ArrayBuffer__New(iso.handle, len).?,
        };
    }

    pub fn initWithBackingStore(iso: Isolate, store: *const SharedPtr) Self {
        return .{
            .handle = c.v8__ArrayBuffer__New2(iso.handle, store).?,
        };
    }

    pub fn getBackingStore(self: Self) SharedPtr {
        return c.v8__ArrayBuffer__GetBackingStore(self.handle);
    }
};

pub const ArrayBufferView = struct {
    const Self = @This();

    handle: *const c.ArrayBufferView,

    pub fn getBuffer(self: Self) ArrayBuffer {
        return .{
            .handle = c.v8__ArrayBufferView__Buffer(self.handle).?,
        };
    }

    pub fn castFrom(val: anytype) Self {
        switch (@TypeOf(val)) {
            Uint8Array => return .{
                .handle = @as(*const c.ArrayBufferView, @ptrCast(val.handle)),
            },
            else => unreachable,
        }
    }
};

pub const FixedArray = struct {
    const Self = @This();

    handle: *const c.FixedArray,

    pub fn length(self: Self) u32 {
        return @as(u32, @intCast(c.v8__FixedArray__Length(self.handle)));
    }

    pub fn get(self: Self, ctx: Context, idx: u32) Data {
        return .{
            .handle = c.v8__FixedArray__Get(self.handle, ctx.handle, @as(c_int, @intCast(idx))).?,
        };
    }
};

pub const Uint8Array = struct {
    const Self = @This();

    handle: *const c.Uint8Array,

    pub fn init(buf: ArrayBuffer, offset: usize, len: usize) Self {
        return .{
            .handle = c.v8__Uint8Array__New(buf.handle, offset, len).?,
        };
    }
};

pub const Json = struct {
    pub fn parse(ctx: Context, json: String) !Value {
        return Value{
            .handle = c.v8__JSON__Parse(ctx.handle, json.handle) orelse return error.JsException,
        };
    }

    pub fn stringify(ctx: Context, val: Value, gap: ?String) !String {
        return String{
            .handle = c.v8__JSON__Stringify(ctx.handle, val.handle, if (gap != null) gap.?.handle else null) orelse return error.JsException,
        };
    }
};

inline fn ptrCastAlign(comptime Ptr: type, ptr: anytype) Ptr {
    const alignment = @typeInfo(Ptr).Pointer.alignment;
    if (alignment == 0) {
        return @as(Ptr, @ptrCast(ptr));
    } else {
        return @as(Ptr, @ptrCast(@as(alignment, @alignCast(ptr))));
    }
}

pub fn setDcheckFunction(func: fn (file: [*c]const u8, line: c_int, msg: [*c]const u8) callconv(.C) void) void {
    c.v8__base__SetDcheckFunction(func);
}

test "Internals." {
    // Verify struct sizes.
    const eq = t.expectEqual;
    try eq(c.v8__Isolate__CreateParams__SIZEOF(), @sizeOf(c.CreateParams));
    try eq(c.v8__TryCatch__SIZEOF(), @sizeOf(c.TryCatch));
    try eq(c.v8__PromiseRejectMessage__SIZEOF(), @sizeOf(c.PromiseRejectMessage));
    try eq(c.v8__ScriptCompiler__Source__SIZEOF(), @sizeOf(c.ScriptCompilerSource));
    try eq(c.v8__ScriptCompiler__CachedData__SIZEOF(), @sizeOf(c.ScriptCompilerCachedData));
    try eq(c.v8__HeapStatistics__SIZEOF(), @sizeOf(c.HeapStatistics));
}

// Inspector

pub const ClientTrustLevel = enum(u32) {
    kUntrusted = c.kUntrusted,
    kFullyTrusted = c.kFullyTrusted,
};

pub const Inspector = struct {
    handle: *c.Inspector = undefined,

    client: InspectorClient = undefined,
    channel: InspectorChannel = undefined,

    rnd: RndGen = RndGen.init(0),

    // The default JS context handle.
    // Set when a context is created.
    ctx_handle: ?*const C_Context = null,

    const RndGen = std.Random.DefaultPrng;

    const contextGroupId = 1;
    const clientTrustLevel = 1;

    pub fn init(
        self: *Inspector,
        client: InspectorClient,
        channel: InspectorChannel,
        isolate: Isolate,
    ) void {
        // NOTE: Inspector self must be created *before*
        // setting inspector on c.InspectorClient and c.InspectorChannel
        // to ensure right data is available on corresponding callbacks
        self.* = Inspector{};

        // client
        client.setInspector(self);
        self.client = client;

        // channel
        channel.setInspector(self);
        self.channel = channel;

        const inspector = c.v8_inspector__Inspector__Create(isolate.handle, self.client.handle).?;
        self.handle = inspector;
    }

    pub fn deinit(self: *Inspector) void {
        self.client.deinit();
        self.channel.deinit();
        c.v8_inspector__Inspector__DELETE(self.handle);
    }

    fn fromData(data: *anyopaque) *Inspector {
        const inspector_raw = @as(*align(1) Inspector, @ptrCast(data));
        return @as(*Inspector, @alignCast(inspector_raw));
    }

    pub fn connect(self: *Inspector) InspectorSession {
        const session = c.v8_inspector__Inspector__Connect(self.handle, contextGroupId, self.channel.handle, clientTrustLevel).?;
        return InspectorSession{ .handle = session };
    }

    pub fn contextCreated(
        self: *Inspector,
        ctx: Context,
        name: []const u8,
        origin: []const u8,
        aux_data: ?[]const u8,
        is_default: bool,
    ) void {
        std.log.debug("Inspector contextCreated called", .{});
        var auxData_ptr: [*c]const u8 = undefined;
        var auxData_len: usize = undefined;
        if (aux_data) |data| {
            auxData_ptr = data.ptr;
            auxData_len = data.len;
        } else {
            auxData_ptr = null;
            auxData_len = 0;
        }
        c.v8_inspector__Inspector__ContextCreated(
            self.handle,
            name.ptr,
            name.len,
            origin.ptr,
            origin.len,
            auxData_ptr,
            auxData_len,
            contextGroupId,
            ctx.handle,
        );
        if (is_default) self.ctx_handle = ctx.handle;
    }
};

// InspectorClient

pub const InspectorClient = struct {
    handle: *c.InspectorClientImpl,

    pub fn init() InspectorClient {
        return .{ .handle = c.v8_inspector__Client__IMPL__CREATE() };
    }

    pub fn deinit(self: InspectorClient) void {
        c.v8_inspector__Client__IMPL__DELETE(self.handle);
    }

    fn setInspector(self: InspectorClient, inspector: *Inspector) void {
        c.v8_inspector__Client__IMPL__SET_DATA(self.handle, inspector);
    }
};

pub export fn v8_inspector__Client__IMPL__generateUniqueId(
    _: *c.InspectorClientImpl,
    data: *anyopaque,
) callconv(.C) i64 {
    const inspector = Inspector.fromData(data);
    return inspector.rnd.random().int(i64);
}

pub export fn v8_inspector__Client__IMPL__runMessageLoopOnPause(
    _: *c.InspectorClientImpl,
    data: *anyopaque,
    contextGroupId: c_int,
) callconv(.C) void {
    _ = contextGroupId;
    std.log.debug("InspectorClient runMessageLoopOnPause called", .{});
    const inspector = Inspector.fromData(data);
    _ = inspector;
    // TODO
}

pub export fn v8_inspector__Client__IMPL__quitMessageLoopOnPause(
    _: *c.InspectorClientImpl,
    data: *anyopaque,
) callconv(.C) void {
    std.log.debug("InspectorClient quitMessageLoopOnPause called", .{});
    const inspector = Inspector.fromData(data);
    _ = inspector;
    // TODO
}

pub export fn v8_inspector__Client__IMPL__runIfWaitingForDebugger(
    _: *c.InspectorClientImpl,
    data: *anyopaque,
    contextGroupId: c_int,
) callconv(.C) void {
    _ = contextGroupId;
    std.log.debug("InspectorClient runIfWaitingForDebugger called", .{});
    const inspector = Inspector.fromData(data);
    _ = inspector;
    // TODO
}

// TODO: move params to C types
pub export fn v8_inspector__Client__IMPL__consoleAPIMessage(
    _: *c.InspectorClientImpl,
    data: *anyopaque,
    contextGroupId: c_int,
    _: c.MessageErrorLevel,
    _: *c.StringView,
    _: *c.StringView,
    _: c_uint,
    _: c_uint,
    _: *c.StackTrace,
) callconv(.C) void {
    _ = contextGroupId;
    std.log.debug("InspectorClient consoleAPIMessage called", .{});
    const inspector = Inspector.fromData(data);
    _ = inspector;
    // TODO
}

pub export fn v8_inspector__Client__IMPL__ensureDefaultContextInGroup(
    _: *c.InspectorClientImpl,
    data: *anyopaque,
) callconv(.C) ?*const C_Context {
    std.log.debug("InspectorClient ensureDefaultContextInGroup called", .{});
    const inspector = Inspector.fromData(data);
    return inspector.ctx_handle;
}

const getTaggedAnyOpaque = @import("../js.zig").getTaggedAnyOpaque;

// This is called from V8. Whenever the v8 inspector has to describe a value
// it'll call this function to gets its [optional] subtype - which, from V8's
// point of view, is an arbitrary string.
pub export fn v8_inspector__Client__IMPL__valueSubtype(
    _: *c.InspectorClientImpl,
    c_value: *const C_Value,
) callconv(.C) [*c]const u8 {
    const external_entry = getTaggedAnyOpaque(.{ .handle = c_value }) orelse return null;
    return if (external_entry.subtype) |st| @tagName(st) else null;
}

// Same as valueSubType above, but for the optional description field.
// From what I can tell, some drivers _need_ the description field to be
// present, even if it's empty. So if we have a subType for the value, we'll
// put an empty description.
pub export fn v8_inspector__Client__IMPL__descriptionForValueSubtype(
    _: *c.InspectorClientImpl,
    context: *const C_Context,
    c_value: *const C_Value,
) callconv(.C) [*c]const u8 {
    _ = context;

    // We _must_ include a non-null description in order for the subtype value
    // to be included. Besides that, I don't know if the value has any meaning
    const external_entry = getTaggedAnyOpaque(.{ .handle = c_value }) orelse return null;
    return if (external_entry.subtype == null) null else "";
}

// InspectorChannel

pub const InspectorChannel = struct {
    handle: *c.InspectorChannelImpl,

    // callbacks
    ctx: *anyopaque,
    onNotif: onNotifFn = undefined,
    onResp: onRespFn = undefined,

    pub const onNotifFn = *const fn (ctx: *anyopaque, msg: []const u8) void;
    pub const onRespFn = *const fn (ctx: *anyopaque, call_id: u32, msg: []const u8) void;

    pub fn init(
        ctx: *anyopaque,
        onResp: onRespFn,
        onNotif: onNotifFn,
        isolate: Isolate,
    ) InspectorChannel {
        const handle = c.v8_inspector__Channel__IMPL__CREATE(isolate.handle);
        return .{
            .handle = handle,
            .ctx = ctx,
            .onResp = onResp,
            .onNotif = onNotif,
        };
    }

    pub fn deinit(self: InspectorChannel) void {
        c.v8_inspector__Channel__IMPL__DELETE(self.handle);
    }

    fn setInspector(self: InspectorChannel, inspector: *Inspector) void {
        c.v8_inspector__Channel__IMPL__SET_DATA(self.handle, inspector);
    }

    fn resp(self: InspectorChannel, call_id: u32, msg: []const u8) void {
        self.onResp(self.ctx, call_id, msg);
    }

    fn notif(self: InspectorChannel, msg: []const u8) void {
        self.onNotif(self.ctx, msg);
    }
};

pub export fn v8_inspector__Channel__IMPL__sendResponse(
    _: *c.InspectorChannelImpl,
    data: *anyopaque,
    call_id: c_int,
    msg: [*c]u8,
    length: usize,
) callconv(.C) void {
    const inspector = Inspector.fromData(data);
    inspector.channel.resp(@as(u32, @intCast(call_id)), msg[0..length]);
}

pub export fn v8_inspector__Channel__IMPL__sendNotification(
    _: *c.InspectorChannelImpl,
    data: *anyopaque,
    msg: [*c]u8,
    length: usize,
) callconv(.C) void {
    const inspector = Inspector.fromData(data);
    inspector.channel.notif(msg[0..length]);
}

pub export fn v8_inspector__Channel__IMPL__flushProtocolNotifications(
    _: *c.InspectorChannelImpl,
    data: *anyopaque,
) callconv(.C) void {
    std.log.debug("InspectorChannel flushProtocolNotifications called", .{});
    const inspector = Inspector.fromData(data);
    _ = inspector;
    // TODO
}

// InspectorSession

pub const InspectorSession = struct {
    handle: *c.InspectorSession,

    pub fn deinit(self: InspectorSession) void {
        c.v8_inspector__Session__DELETE(self.handle);
    }

    pub fn dispatchProtocolMessage(
        self: InspectorSession,
        isolate: Isolate,
        msg: []const u8,
    ) void {
        c.v8_inspector__Session__dispatchProtocolMessage(
            self.handle,
            isolate.handle,
            msg.ptr,
            msg.len,
        );
    }

    pub fn wrapObject(self: InspectorSession, isolate: Isolate, ctx: Context, val: Value, grpname: []const u8, generatepreview: bool) !RemoteObject {
        const remote_object = c.v8_inspector__Session__wrapObject(
            self.handle,
            isolate.handle,
            ctx.handle,
            val.handle,
            grpname.ptr,
            grpname.len,
            generatepreview,
        ).?;
        return RemoteObject{ .handle = remote_object };
    }

    pub fn unwrapObject(self: InspectorSession, allocator: std.mem.Allocator, object_id: []const u8) !UnwrappedObject {
        const in_object_id = c.CZigString{
            .ptr = object_id.ptr,
            .len = object_id.len,
        };
        var out_error: c.CZigString = .{ .ptr = null, .len = 0 };
        var out_value_handle: ?*c.Value = null;
        var out_context_handle: ?*c.Context = null;
        var out_object_group: c.CZigString = .{ .ptr = null, .len = 0 };

        const result = c.v8_inspector__Session__unwrapObject(
            self.handle,
            &allocator,
            &out_error,
            in_object_id,
            &out_value_handle,
            &out_context_handle,
            &out_object_group,
        );
        if (!result) {
            if (cZigStringToString(out_error)) |err| {
                if (std.mem.eql(u8, err, "Invalid remote object id")) return error.InvalidRemoteObjectId;
                if (std.mem.eql(u8, err, "Cannot find context with specified id")) return error.CannotFindContextWithSpecifiedId;
                if (std.mem.eql(u8, err, "Could not find object with given id")) return error.CouldNotFindObjectWithGivenId;
                return error.NewUnwrapErrorPleaseReport;
            }
            return error.V8AllocFailed;
        }
        return .{
            .value = Value{ .handle = out_value_handle.? },
            .context = Context{ .handle = out_context_handle.? },
            .object_group = cZigStringToString(out_object_group),
        };
    }
};

pub fn cZigStringToString(slice: c.CZigString) ?[]const u8 {
    return if (slice.ptr == null) null else slice.ptr[0..slice.len];
}

pub const UnwrappedObject = struct {
    value: Value,
    context: Context,
    object_group: ?[]const u8,
};

/// Note: Some getters return owned memory (strings), while others return memory owned by V8 (objects).
/// The getters short-circuit if the default values is not available as converting the defaults to V8 causes unnecessary overhead.
///
/// https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#type-RemoteObject
pub const RemoteObject = struct {
    handle: *c.RemoteObject,

    pub fn deinit(self: RemoteObject) void {
        c.v8_inspector__RemoteObject__DELETE(self.handle);
    }

    pub fn getType(self: RemoteObject, allocator: std.mem.Allocator) ![]const u8 {
        var ctype_: c.CZigString = .{ .ptr = null, .len = 0 };
        if (!c.v8_inspector__RemoteObject__getType(self.handle, &allocator, &ctype_)) return error.V8AllocFailed;
        return cZigStringToString(ctype_) orelse return error.InvalidType;
    }
    pub fn getSubtype(self: RemoteObject, allocator: std.mem.Allocator) !?[]const u8 {
        if (!c.v8_inspector__RemoteObject__hasSubtype(self.handle)) return null;

        var csubtype: c.CZigString = .{ .ptr = null, .len = 0 };
        if (!c.v8_inspector__RemoteObject__getSubtype(self.handle, &allocator, &csubtype)) return error.V8AllocFailed;
        return cZigStringToString(csubtype);
    }
    pub fn getClassName(self: RemoteObject, allocator: std.mem.Allocator) !?[]const u8 {
        if (!c.v8_inspector__RemoteObject__hasClassName(self.handle)) return null;

        var cclass_name: c.CZigString = .{ .ptr = null, .len = 0 };
        if (!c.v8_inspector__RemoteObject__getClassName(self.handle, &allocator, &cclass_name)) return error.V8AllocFailed;
        return cZigStringToString(cclass_name);
    }
    pub fn getDescription(self: RemoteObject, allocator: std.mem.Allocator) !?[]const u8 {
        if (!c.v8_inspector__RemoteObject__hasDescription(self.handle)) return null;

        var description: c.CZigString = .{ .ptr = null, .len = 0 };
        if (!c.v8_inspector__RemoteObject__getDescription(self.handle, &allocator, &description)) return error.V8AllocFailed;
        return cZigStringToString(description);
    }
    pub fn getObjectId(self: RemoteObject, allocator: std.mem.Allocator) !?[]const u8 {
        if (!c.v8_inspector__RemoteObject__hasObjectId(self.handle)) return null;

        var cobject_id: c.CZigString = .{ .ptr = null, .len = 0 };
        if (!c.v8_inspector__RemoteObject__getObjectId(self.handle, &allocator, &cobject_id)) return error.V8AllocFailed;
        return cZigStringToString(cobject_id);
    }
};

/// Enables C to allocate using the given Zig allocator
pub export fn zigAlloc(self: *anyopaque, bytes: usize) callconv(.C) ?[*]u8 {
    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(self));
    const allocated_bytes = allocator.alloc(u8, bytes) catch return null;
    return allocated_bytes.ptr;
}
