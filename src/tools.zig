const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const process = std.process;

pub fn pathFromBinary(io: std.Io, allocator: mem.Allocator, path: []const u8) ![]u8 {
    const binary_directory = try process.executableDirPathAlloc(io, allocator);
    defer allocator.free(binary_directory);
    return try fs.path.join(allocator, &[_][]const u8{ binary_directory, path });
}

pub fn pathFromBinaryZ(io: std.Io, allocator: mem.Allocator, path: []const u8) ![:0]const u8 {
    const binary_directory = try process.executableDirPathAlloc(io, allocator);
    defer allocator.free(binary_directory);
    return try fs.path.joinZ(allocator, &[_][]const u8{ binary_directory, path });
}
