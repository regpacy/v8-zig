const std = @import("std");
const v8 = @import("v8_zig");

pub fn main(init: std.process.Init) !void {
    const argv0: [*:0]const u8 = init.minimal.args.vector[0];

    if (!v8.initializeIcuDefaultLocation(argv0)) {
        std.debug.print("Failed to initialize ICU\n", .{});
        return error.IcuInitFailed;
    }
    v8.initializeExternalStartupData(argv0);

    const platform = v8.newDefaultPlatform();
    v8.initializePlatform(platform);
    _ = v8.initialize();

    const allocator = v8.newDefaultArrayBufferAllocator();

    const isolate = v8.newIsolate(allocator);
    {
        const isolate_scope = v8.newIsolateScope(isolate);
        defer v8.deleteIsolateScope(isolate_scope);

        const handle_scope = v8.newHandleScope(isolate);
        defer v8.deleteHandleScope(handle_scope);

        const context = v8.newContext(isolate);

        const context_scope = v8.newContextScope(context);
        defer v8.deleteContextScope(context_scope);

        {
            const source = v8.newStringFromUtf8(isolate, "'Hello' + ', World!'");
            const script = v8.compileScript(context, source);
            const result = v8.runScript(context, script);

            const utf8 = v8.valueToUtf8(isolate, result);
            defer v8.deleteUtf8Value(utf8);
            std.debug.print("{s}\n", .{v8.utf8ValueCStr(utf8)});
        }

        {
            const csource =
                \\let bytes = new Uint8Array([
                \\  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01,
                \\  0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07,
                \\  0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09, 0x01,
                \\  0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b
                \\]);
                \\let module = new WebAssembly.Module(bytes);
                \\let instance = new WebAssembly.Instance(module);
                \\instance.exports.add(3, 4);
            ;

            const source = v8.newStringFromUtf8(isolate, csource);
            const script = v8.compileScript(context, source);
            const result = v8.runScript(context, script);

            const number = v8.valueToUint32(context, result);
            std.debug.print("3 + 4 = {d}\n", .{number});
        }
    }

    // Mirrors the original hello-world.cc teardown order exactly: V8 asserts
    // on this ordering internally, so isolate -> V8 -> platform -> allocator
    // -> platform-object-deletion must happen in this sequence, not
    // whatever order Zig's `defer` LIFO stack would naturally produce.
    v8.disposeIsolate(isolate);
    v8.dispose();
    v8.disposePlatform();
    v8.deleteArrayBufferAllocator(allocator);
    v8.deletePlatform(platform);
}
