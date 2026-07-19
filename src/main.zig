const std = @import("std");
const Io = std.Io;

extern fn @"_ZN2v82V810GetVersionEv"() [*:0]const u8;

const v8_zig = @import("v8_zig");

pub fn main(_: std.process.Init) !void {
    const version = @"_ZN2v82V810GetVersionEv"();
    std.debug.print("V8 version: {s}\n", .{version});
}