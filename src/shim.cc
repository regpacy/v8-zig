// Thin C ABI shim over V8's C++ API.
//
// V8's public headers mix real out-of-line functions (linkable directly by
// mangled name) with inline-only constructs (HandleScope/Isolate::Scope/
// Context::Scope ctors+dtors, MaybeLocal<T>::ToLocalChecked, Maybe<T>::
// ToChecked, Isolate::CreateParams setup, NewDefaultPlatform's
// std::unique_ptr<Platform> return). The inline-only pieces have no linkable
// symbol at all -- they only exist inlined at V8's own call sites -- so they
// cannot be called from Zig directly. This file gives each of those a flat
// extern "C" entry point, compiled by the same compiler/headers used to
// build libv8_monolith.a so the ABI (struct layouts, calling convention)
// is guaranteed to match.
//
// v8::Local<T> is declared V8_TRIVIAL_ABI (clang's [[clang::trivial_abi]]),
// so despite having non-trivial-looking special members it occupies exactly
// one pointer's worth of storage and is passed/returned purely in registers.
// Clang still refuses to let an extern "C" function return/take a C++ class
// type by value though, so Handle (a plain void*) is used at the extern "C"
// boundary and Local<T> is memcpy'd in/out of it -- a safe, standard-legal
// reinterpretation given the matching size/layout.

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "include/libplatform/libplatform.h"
#include "include/v8-array-buffer.h"
#include "include/v8-context.h"
#include "include/v8-exception.h"
#include "include/v8-external.h"
#include "include/v8-function.h"
#include "include/v8-function-callback.h"
#include "include/v8-initialization.h"
#include "include/v8-isolate.h"
#include "include/v8-json.h"
#include "include/v8-local-handle.h"
#include "include/v8-message.h"
#include "include/v8-object.h"
#include "include/v8-primitive.h"
#include "include/v8-script.h"
#include "include/v8-template.h"
#include "include/v8-typed-array.h"
#include "include/v8-value.h"

using Handle = void*;

template <typename T>
static Handle ToHandle(v8::Local<T> local) {
  static_assert(sizeof(local) == sizeof(Handle));
  Handle h;
  std::memcpy(&h, &local, sizeof(h));
  return h;
}

template <typename T>
static v8::Local<T> FromHandle(Handle h) {
  v8::Local<T> local;
  static_assert(sizeof(local) == sizeof(Handle));
  std::memcpy(&local, &h, sizeof(local));
  return local;
}

extern "C" {

// --- Platform / global lifecycle ---

bool v8shim_initialize_icu_default_location(const char* exec_path) {
  return v8::V8::InitializeICUDefaultLocation(exec_path);
}

void v8shim_initialize_external_startup_data(const char* exec_path) {
  v8::V8::InitializeExternalStartupData(exec_path);
}

v8::Platform* v8shim_platform_new() {
  return v8::platform::NewDefaultPlatform().release();
}

void v8shim_platform_delete(v8::Platform* platform) { delete platform; }

void v8shim_initialize_platform(v8::Platform* platform) {
  v8::V8::InitializePlatform(platform);
}

bool v8shim_initialize() { return v8::V8::Initialize(); }

void v8shim_dispose() { v8::V8::Dispose(); }

void v8shim_dispose_platform() { v8::V8::DisposePlatform(); }

// --- ArrayBuffer::Allocator ---

void v8shim_array_buffer_allocator_delete(
    v8::ArrayBuffer::Allocator* allocator) {
  delete allocator;
}

// --- Isolate ---

v8::Isolate* v8shim_isolate_new(v8::ArrayBuffer::Allocator* allocator) {
  v8::Isolate::CreateParams create_params;
  create_params.array_buffer_allocator = allocator;
  return v8::Isolate::New(create_params);
}

void v8shim_isolate_dispose(v8::Isolate* isolate) { isolate->Dispose(); }

void* v8shim_isolate_scope_new(v8::Isolate* isolate) {
  return new v8::Isolate::Scope(isolate);
}

void v8shim_isolate_scope_delete(void* scope) {
  delete static_cast<v8::Isolate::Scope*>(scope);
}

// HandleScope declares its own operator new/delete private (it must not be
// heap-allocated the normal way), so construct it in-place via placement new
// on memory obtained from the global allocation functions instead.
void* v8shim_handle_scope_new(v8::Isolate* isolate) {
  void* mem = ::operator new(sizeof(v8::HandleScope));
  return ::new (mem) v8::HandleScope(isolate);
}

void v8shim_handle_scope_delete(void* scope) {
  auto* handle_scope = static_cast<v8::HandleScope*>(scope);
  handle_scope->~HandleScope();
  ::operator delete(handle_scope);
}

// --- Context ---

Handle v8shim_context_new(v8::Isolate* isolate) {
  return ToHandle(v8::Context::New(isolate));
}

void* v8shim_context_scope_new(Handle context) {
  return new v8::Context::Scope(FromHandle<v8::Context>(context));
}

void v8shim_context_scope_delete(void* scope) {
  delete static_cast<v8::Context::Scope*>(scope);
}

Handle v8shim_context_global(Handle context) {
  return ToHandle(FromHandle<v8::Context>(context)->Global());
}

// --- String ---

Handle v8shim_string_new_utf8(v8::Isolate* isolate, const char* data) {
  return ToHandle(v8::String::NewFromUtf8(isolate, data,
                                           v8::NewStringType::kNormal)
                       .ToLocalChecked());
}

// Explicit-length variant: NewFromUtf8's default (-1) length relies on
// strlen, so it can't safely handle buffer bytes (embedded NULs, no
// guaranteed terminator).
Handle v8shim_string_new_utf8_len(v8::Isolate* isolate, const char* data,
                                   int length) {
  return ToHandle(v8::String::NewFromUtf8(isolate, data,
                                           v8::NewStringType::kNormal, length)
                       .ToLocalChecked());
}

// --- Script ---

// Formats an uncaught JS exception the same way d8 does ("<file>:<line>:
// Uncaught <message>") and exits, instead of letting the caller's
// ToLocalChecked() abort the whole process with a much less useful fatal
// error. try_catch must be the active TryCatch that caught this exception.
[[noreturn]] static void ReportExceptionAndExit(v8::Isolate* isolate,
                                                 v8::TryCatch* try_catch) {
  v8::HandleScope handle_scope(isolate);
  v8::String::Utf8Value exception(isolate, try_catch->Exception());
  v8::Local<v8::Message> message = try_catch->Message();
  if (message.IsEmpty()) {
    fprintf(stderr, "Uncaught %s\n", *exception);
  } else {
    v8::Local<v8::Context> context = isolate->GetCurrentContext();
    v8::String::Utf8Value filename(isolate, message->GetScriptResourceName());
    int line = message->GetLineNumber(context).FromMaybe(-1);
    fprintf(stderr, "%s:%d: Uncaught %s\n", *filename, line, *exception);
  }
  std::exit(1);
}

Handle v8shim_script_compile(Handle context, Handle source, Handle filename) {
  v8::Local<v8::Context> ctx = FromHandle<v8::Context>(context);
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  v8::TryCatch try_catch(isolate);

  v8::ScriptOrigin origin(FromHandle<v8::Value>(filename));
  v8::MaybeLocal<v8::Script> maybe_script =
      v8::Script::Compile(ctx, FromHandle<v8::String>(source), &origin);
  if (maybe_script.IsEmpty()) {
    ReportExceptionAndExit(isolate, &try_catch);
  }
  return ToHandle(maybe_script.ToLocalChecked());
}

Handle v8shim_script_run(Handle context, Handle script) {
  v8::Local<v8::Script> script_local = FromHandle<v8::Script>(script);
  v8::Local<v8::Context> ctx = FromHandle<v8::Context>(context);
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  v8::TryCatch try_catch(isolate);

  v8::MaybeLocal<v8::Value> result = script_local->Run(ctx);
  if (result.IsEmpty()) {
    ReportExceptionAndExit(isolate, &try_catch);
  }
  return ToHandle(result.ToLocalChecked());
}

// --- JSON ---

Handle v8shim_json_parse(Handle context, Handle json_string) {
  v8::Local<v8::Context> ctx = FromHandle<v8::Context>(context);
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  v8::TryCatch try_catch(isolate);

  v8::MaybeLocal<v8::Value> result =
      v8::JSON::Parse(ctx, FromHandle<v8::String>(json_string));
  if (result.IsEmpty()) {
    ReportExceptionAndExit(isolate, &try_catch);
  }
  return ToHandle(result.ToLocalChecked());
}

// --- ArrayBuffer / TypedArray ---

Handle v8shim_array_buffer_new(v8::Isolate* isolate, size_t byte_length) {
  return ToHandle(v8::ArrayBuffer::New(isolate, byte_length));
}

void* v8shim_array_buffer_data(Handle array_buffer) {
  return FromHandle<v8::ArrayBuffer>(array_buffer)->Data();
}

size_t v8shim_array_buffer_byte_length(Handle array_buffer) {
  return FromHandle<v8::ArrayBuffer>(array_buffer)->ByteLength();
}

Handle v8shim_uint8array_new(Handle array_buffer, size_t byte_offset,
                              size_t length) {
  return ToHandle(v8::Uint8Array::New(FromHandle<v8::ArrayBuffer>(array_buffer),
                                       byte_offset, length));
}

Handle v8shim_typed_array_buffer(Handle value) {
  return ToHandle(FromHandle<v8::Uint8Array>(value)->Buffer());
}

size_t v8shim_typed_array_byte_offset(Handle value) {
  return FromHandle<v8::Uint8Array>(value)->ByteOffset();
}

size_t v8shim_typed_array_byte_length(Handle value) {
  return FromHandle<v8::Uint8Array>(value)->ByteLength();
}

bool v8shim_value_is_number(Handle value) {
  return FromHandle<v8::Value>(value)->IsNumber();
}

bool v8shim_value_is_uint8array(Handle value) {
  return FromHandle<v8::Value>(value)->IsUint8Array();
}

// --- Value ---

void* v8shim_value_to_utf8(v8::Isolate* isolate, Handle value) {
  return new v8::String::Utf8Value(isolate, FromHandle<v8::Value>(value));
}

void v8shim_utf8value_delete(void* utf8_value) {
  delete static_cast<v8::String::Utf8Value*>(utf8_value);
}

const char* v8shim_utf8value_cstr(void* utf8_value) {
  return **static_cast<v8::String::Utf8Value*>(utf8_value);
}

uint32_t v8shim_value_uint32(Handle context, Handle value) {
  return FromHandle<v8::Value>(value)
      ->Uint32Value(FromHandle<v8::Context>(context))
      .ToChecked();
}

Handle v8shim_integer_new(v8::Isolate* isolate, int32_t value) {
  return ToHandle(v8::Integer::New(isolate, value));
}

Handle v8shim_boolean_new(v8::Isolate* isolate, bool value) {
  return ToHandle(v8::Boolean::New(isolate, value));
}

Handle v8shim_isolate_current_context(v8::Isolate* isolate) {
  return ToHandle(isolate->GetCurrentContext());
}

// --- Object ---

Handle v8shim_object_new(v8::Isolate* isolate) {
  return ToHandle(v8::Object::New(isolate));
}

bool v8shim_object_set(Handle context, Handle object, Handle key,
                        Handle value) {
  return FromHandle<v8::Object>(object)
      ->Set(FromHandle<v8::Context>(context), FromHandle<v8::Value>(key),
            FromHandle<v8::Value>(value))
      .ToChecked();
}

Handle v8shim_object_get(Handle context, Handle object, Handle key) {
  return ToHandle(FromHandle<v8::Object>(object)
                       ->Get(FromHandle<v8::Context>(context),
                             FromHandle<v8::Value>(key))
                       .ToLocalChecked());
}

// --- FunctionTemplate ---

Handle v8shim_function_template_new(v8::Isolate* isolate,
                                     v8::FunctionCallback callback,
                                     Handle data) {
  v8::Local<v8::Value> data_local =
      data ? FromHandle<v8::Value>(data) : v8::Local<v8::Value>();
  return ToHandle(v8::FunctionTemplate::New(isolate, callback, data_local));
}

Handle v8shim_function_template_get_function(Handle context, Handle tmpl) {
  return ToHandle(FromHandle<v8::FunctionTemplate>(tmpl)
                       ->GetFunction(FromHandle<v8::Context>(context))
                       .ToLocalChecked());
}

// --- FunctionCallbackInfo ---
//
// Passed to a v8::FunctionCallback by const reference, which is ABI-identical
// to a plain pointer -- no shim needed for the callback signature itself,
// only for reading out of the (inline-only) accessor methods.

int v8shim_fci_length(const v8::FunctionCallbackInfo<v8::Value>* info) {
  return info->Length();
}

Handle v8shim_fci_get(const v8::FunctionCallbackInfo<v8::Value>* info,
                       int i) {
  return ToHandle((*info)[i]);
}

v8::Isolate* v8shim_fci_get_isolate(
    const v8::FunctionCallbackInfo<v8::Value>* info) {
  return info->GetIsolate();
}

Handle v8shim_fci_get_data(const v8::FunctionCallbackInfo<v8::Value>* info) {
  return ToHandle(info->Data());
}

Handle v8shim_fci_this(const v8::FunctionCallbackInfo<v8::Value>* info) {
  return ToHandle(info->This());
}

void v8shim_fci_set_return_value(
    const v8::FunctionCallbackInfo<v8::Value>* info, Handle value) {
  info->GetReturnValue().Set(FromHandle<v8::Value>(value));
}

// --- External ---

Handle v8shim_external_new(v8::Isolate* isolate, void* value) {
  return ToHandle(v8::External::New(isolate, value,
                                     v8::kExternalPointerTypeTagDefault));
}

void* v8shim_external_value(Handle external) {
  return FromHandle<v8::Value>(external).As<v8::External>()->Value(
      v8::kExternalPointerTypeTagDefault);
}

}  // extern "C"
