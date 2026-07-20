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

// --- Real out-of-line V8 symbols, bound directly by mangled name ---

extern fn @"_ZN2v82V810GetVersionEv"() [*:0]const u8;
extern fn @"_ZN2v811ArrayBuffer9Allocator19NewDefaultAllocatorEv"() ?*ArrayBufferAllocator;

pub fn getVersion() [*:0]const u8 {
    return @"_ZN2v82V810GetVersionEv"();
}

pub fn newDefaultArrayBufferAllocator() ?*ArrayBufferAllocator {
    return @"_ZN2v811ArrayBuffer9Allocator19NewDefaultAllocatorEv"();
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

extern fn v8shim_string_new_utf8(isolate: ?*Isolate, data: [*:0]const u8) ?*String;

extern fn v8shim_script_compile(context: ?*Context, source: ?*String) ?*Script;
extern fn v8shim_script_run(context: ?*Context, script: ?*Script) ?*Value;

extern fn v8shim_value_to_utf8(isolate: ?*Isolate, value: ?*Value) ?*Utf8Value;
extern fn v8shim_utf8value_delete(utf8_value: ?*Utf8Value) void;
extern fn v8shim_utf8value_cstr(utf8_value: ?*Utf8Value) [*:0]const u8;
extern fn v8shim_value_uint32(context: ?*Context, value: ?*Value) u32;

// --- Ergonomic Zig wrappers ---

pub fn initializeIcuDefaultLocation(exec_path: [*:0]const u8) bool {
    return v8shim_initialize_icu_default_location(exec_path);
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

pub fn newStringFromUtf8(isolate: ?*Isolate, data: [*:0]const u8) ?*String {
    return v8shim_string_new_utf8(isolate, data);
}

pub fn compileScript(context: ?*Context, source: ?*String) ?*Script {
    return v8shim_script_compile(context, source);
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

test "basic version call" {
    _ = getVersion();
}
