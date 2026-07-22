//! Zig bindings for V8's C++ API.
//!
//! Two layers of extern declarations back these functions:
//!
//! - Real, non-inline, default-argument-free V8 symbols are bound directly
//!   by their Itanium-mangled name (see `shell/v8-syms.txt`-style lookups
//!   via `nm -C libv8_monolith.a`), the same way `main.zig` originally
//!   bound `v8::V8::GetVersion`.
//! - Everything that only exists inlined in V8's headers (HandleScope,
//!   Isolate::Scope, Context::Scope, MaybeLocal<T>::ToLocalChecked,
//!   Maybe<T>::ToChecked, Isolate::CreateParams setup, the
//!   std::unique_ptr<Platform>-returning NewDefaultPlatform, and
//!   V8::Initialize()'s build-config bitmask) is exposed through the
//!   `v8shim_*` C ABI defined in `shim.cc`, compiled by the same
//!   compiler/headers used to build libv8_monolith.a.

const std = @import("std");
const builtin = @import("builtin");

pub const Platform = opaque {};
pub const ArrayBufferAllocator = opaque {};
pub const Isolate = opaque {};
pub const IsolateScope = opaque {};
pub const HandleScope = opaque {};
pub const Context = opaque {};
pub const ContextScope = opaque {};
pub const String = opaque {};
pub const Script = opaque {};
pub const Value = opaque {};
pub const Utf8Value = opaque {};
pub const Object = opaque {};
pub const FunctionTemplate = opaque {};
pub const Function = opaque {};
pub const FunctionCallbackInfo = opaque {};

// --- Real out-of-line V8 symbols, bound directly by mangled name ---
//
// The Linux libv8_monolith.a carries Itanium-mangled names; the Windows
// v8_monolith.lib was built with clang-cl and carries MSVC-mangled ones, so
// the direct bindings pick the right spelling per target.

const use_msvc_mangling = builtin.os.tag == .windows;

const v8_get_version = @extern(*const fn () callconv(.c) [*:0]const u8, .{
    .name = if (use_msvc_mangling)
        "?GetVersion@V8@v8@@SAPEBDXZ"
    else
        "_ZN2v82V810GetVersionEv",
});
const v8_new_default_allocator = @extern(*const fn () callconv(.c) ?*ArrayBufferAllocator, .{
    .name = if (use_msvc_mangling)
        "?NewDefaultAllocator@Allocator@ArrayBuffer@v8@@SAPEAV123@XZ"
    else
        "_ZN2v811ArrayBuffer9Allocator19NewDefaultAllocatorEv",
});

pub fn getVersion() [*:0]const u8 {
    return v8_get_version();
}

pub fn newDefaultArrayBufferAllocator() ?*ArrayBufferAllocator {
    return v8_new_default_allocator();
}

// --- Inline-only V8 constructs, bound through the shim.cc C ABI ---

extern fn v8shim_initialize_icu_default_location(exec_path: [*:0]const u8) bool;
extern fn v8shim_initialize_external_startup_data(exec_path: [*:0]const u8) void;
extern fn v8shim_platform_new() ?*Platform;
extern fn v8shim_platform_delete(platform: ?*Platform) void;
extern fn v8shim_initialize_platform(platform: ?*Platform) void;
extern fn v8shim_initialize() bool;
extern fn v8shim_dispose() void;
extern fn v8shim_dispose_platform() void;

extern fn v8shim_array_buffer_allocator_delete(allocator: ?*ArrayBufferAllocator) void;

extern fn v8shim_isolate_new(allocator: ?*ArrayBufferAllocator) ?*Isolate;
extern fn v8shim_isolate_dispose(isolate: ?*Isolate) void;
extern fn v8shim_isolate_scope_new(isolate: ?*Isolate) ?*IsolateScope;
extern fn v8shim_isolate_scope_delete(scope: ?*IsolateScope) void;
extern fn v8shim_handle_scope_new(isolate: ?*Isolate) ?*HandleScope;
extern fn v8shim_handle_scope_delete(scope: ?*HandleScope) void;

extern fn v8shim_context_new(isolate: ?*Isolate) ?*Context;
extern fn v8shim_context_scope_new(context: ?*Context) ?*ContextScope;
extern fn v8shim_context_scope_delete(scope: ?*ContextScope) void;
extern fn v8shim_context_global(context: ?*Context) ?*Object;

extern fn v8shim_string_new_utf8(isolate: ?*Isolate, data: [*:0]const u8) ?*String;

extern fn v8shim_script_compile(context: ?*Context, source: ?*String, filename: ?*Value) ?*Script;
extern fn v8shim_script_run(context: ?*Context, script: ?*Script) ?*Value;

extern fn v8shim_value_to_utf8(isolate: ?*Isolate, value: ?*Value) ?*Utf8Value;
extern fn v8shim_utf8value_delete(utf8_value: ?*Utf8Value) void;
extern fn v8shim_utf8value_cstr(utf8_value: ?*Utf8Value) [*:0]const u8;
extern fn v8shim_value_uint32(context: ?*Context, value: ?*Value) u32;

extern fn v8shim_integer_new(isolate: ?*Isolate, value: i32) ?*Value;
extern fn v8shim_boolean_new(isolate: ?*Isolate, value: bool) ?*Value;
extern fn v8shim_isolate_current_context(isolate: ?*Isolate) ?*Context;

extern fn v8shim_object_new(isolate: ?*Isolate) ?*Object;
extern fn v8shim_object_set(context: ?*Context, object: ?*Object, key: ?*Value, value: ?*Value) bool;
extern fn v8shim_object_get(context: ?*Context, object: ?*Object, key: ?*Value) ?*Value;

pub const FunctionCallback = *const fn (info: ?*const FunctionCallbackInfo) callconv(.c) void;

extern fn v8shim_function_template_new(isolate: ?*Isolate, callback: FunctionCallback, data: ?*Value) ?*FunctionTemplate;
extern fn v8shim_function_template_get_function(context: ?*Context, template: ?*FunctionTemplate) ?*Function;

extern fn v8shim_fci_length(info: ?*const FunctionCallbackInfo) c_int;
extern fn v8shim_fci_get(info: ?*const FunctionCallbackInfo, i: c_int) ?*Value;
extern fn v8shim_fci_get_isolate(info: ?*const FunctionCallbackInfo) ?*Isolate;
extern fn v8shim_fci_get_data(info: ?*const FunctionCallbackInfo) ?*Value;
extern fn v8shim_fci_set_return_value(info: ?*const FunctionCallbackInfo, value: ?*Value) void;

extern fn v8shim_external_new(isolate: ?*Isolate, value: ?*anyopaque) ?*Value;
extern fn v8shim_external_value(external: ?*Value) ?*anyopaque;

// --- Ergonomic Zig wrappers ---

pub const IcuError = error{IcuInitializationFailed};

pub fn initializeIcuDefaultLocation(exec_path: [*:0]const u8) IcuError!void {
    if (!v8shim_initialize_icu_default_location(exec_path)) {
        return error.IcuInitializationFailed;
    }
}

pub fn initializeExternalStartupData(exec_path: [*:0]const u8) void {
    v8shim_initialize_external_startup_data(exec_path);
}

pub fn newDefaultPlatform() ?*Platform {
    return v8shim_platform_new();
}

pub fn deletePlatform(platform: ?*Platform) void {
    v8shim_platform_delete(platform);
}

pub fn initializePlatform(platform: ?*Platform) void {
    v8shim_initialize_platform(platform);
}

pub fn initialize() bool {
    return v8shim_initialize();
}

pub fn dispose() void {
    v8shim_dispose();
}

pub fn disposePlatform() void {
    v8shim_dispose_platform();
}

pub fn deleteArrayBufferAllocator(allocator: ?*ArrayBufferAllocator) void {
    v8shim_array_buffer_allocator_delete(allocator);
}

pub fn newIsolate(allocator: ?*ArrayBufferAllocator) ?*Isolate {
    return v8shim_isolate_new(allocator);
}

pub fn disposeIsolate(isolate: ?*Isolate) void {
    v8shim_isolate_dispose(isolate);
}

pub fn newIsolateScope(isolate: ?*Isolate) ?*IsolateScope {
    return v8shim_isolate_scope_new(isolate);
}

pub fn deleteIsolateScope(scope: ?*IsolateScope) void {
    v8shim_isolate_scope_delete(scope);
}

pub fn newHandleScope(isolate: ?*Isolate) ?*HandleScope {
    return v8shim_handle_scope_new(isolate);
}

pub fn deleteHandleScope(scope: ?*HandleScope) void {
    v8shim_handle_scope_delete(scope);
}

pub fn newContext(isolate: ?*Isolate) ?*Context {
    return v8shim_context_new(isolate);
}

pub fn newContextScope(context: ?*Context) ?*ContextScope {
    return v8shim_context_scope_new(context);
}

pub fn deleteContextScope(scope: ?*ContextScope) void {
    v8shim_context_scope_delete(scope);
}

pub fn contextGlobal(context: ?*Context) ?*Object {
    return v8shim_context_global(context);
}

pub fn newStringFromUtf8(isolate: ?*Isolate, data: [*:0]const u8) ?*String {
    return v8shim_string_new_utf8(isolate, data);
}

pub fn compileScript(context: ?*Context, source: ?*String, filename: ?*Value) ?*Script {
    return v8shim_script_compile(context, source, filename);
}

pub fn runScript(context: ?*Context, script: ?*Script) ?*Value {
    return v8shim_script_run(context, script);
}

pub fn valueToUtf8(isolate: ?*Isolate, value: ?*Value) ?*Utf8Value {
    return v8shim_value_to_utf8(isolate, value);
}

pub fn deleteUtf8Value(utf8_value: ?*Utf8Value) void {
    v8shim_utf8value_delete(utf8_value);
}

pub fn utf8ValueCStr(utf8_value: ?*Utf8Value) [*:0]const u8 {
    return v8shim_utf8value_cstr(utf8_value);
}

pub fn valueToUint32(context: ?*Context, value: ?*Value) u32 {
    return v8shim_value_uint32(context, value);
}

pub fn newInteger(isolate: ?*Isolate, value: i32) ?*Value {
    return v8shim_integer_new(isolate, value);
}

pub fn newBoolean(isolate: ?*Isolate, value: bool) ?*Value {
    return v8shim_boolean_new(isolate, value);
}

pub fn isolateCurrentContext(isolate: ?*Isolate) ?*Context {
    return v8shim_isolate_current_context(isolate);
}

pub fn newObject(isolate: ?*Isolate) ?*Object {
    return v8shim_object_new(isolate);
}

pub fn objectSet(context: ?*Context, object: ?*Object, key: ?*Value, value: ?*Value) bool {
    return v8shim_object_set(context, object, key, value);
}

pub fn objectGet(context: ?*Context, object: ?*Object, key: ?*Value) ?*Value {
    return v8shim_object_get(context, object, key);
}

pub fn newFunctionTemplate(isolate: ?*Isolate, callback: FunctionCallback, data: ?*Value) ?*FunctionTemplate {
    return v8shim_function_template_new(isolate, callback, data);
}

pub fn functionTemplateGetFunction(context: ?*Context, template: ?*FunctionTemplate) ?*Function {
    return v8shim_function_template_get_function(context, template);
}

pub fn fciLength(info: ?*const FunctionCallbackInfo) c_int {
    return v8shim_fci_length(info);
}

pub fn fciGet(info: ?*const FunctionCallbackInfo, i: c_int) ?*Value {
    return v8shim_fci_get(info, i);
}

pub fn fciGetIsolate(info: ?*const FunctionCallbackInfo) ?*Isolate {
    return v8shim_fci_get_isolate(info);
}

pub fn fciGetData(info: ?*const FunctionCallbackInfo) ?*Value {
    return v8shim_fci_get_data(info);
}

pub fn fciSetReturnValue(info: ?*const FunctionCallbackInfo, value: ?*Value) void {
    v8shim_fci_set_return_value(info, value);
}

pub fn newExternal(isolate: ?*Isolate, value: ?*anyopaque) ?*Value {
    return v8shim_external_new(isolate, value);
}

pub fn externalValue(external: ?*Value) ?*anyopaque {
    return v8shim_external_value(external);
}

test "basic version call" {
    _ = getVersion();
}
