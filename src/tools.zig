const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const fmt = std.fmt;
const process = std.process;

const Error = error{
    InvalidID,
};

pub fn IDMap(comptime T: type) type {
    return struct {
        allocator: mem.Allocator,
        values: []T,
        active: []bool,
        open: []u32,
        open_len: usize,

        const Self = @This();

        pub fn init(allocator: mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .values = &[_]T{},
                .active = &[_]bool{},
                .open = &[_]u32{},
                .open_len = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.values);
            self.allocator.free(self.active);
            self.allocator.free(self.open);
        }

        pub fn create(self: *Self, data: T) !u32 {
            if (self.open_len > 0) {
                self.*.open_len -= 1;
                const id = self.open[self.open_len];
                self.*.values[id] = data;
                self.*.active[id] = true;
                return id;
            }

            const id: u32 = @intCast(self.values.len);
            self.*.values = try self.allocator.realloc(self.values, self.values.len + 1);
            self.*.active = try self.allocator.realloc(self.active, self.active.len + 1);
            self.*.values[id] = data;
            self.*.active[id] = true;

            return id;
        }

        pub fn set(self: *Self, id: u32, value: T) !void {
            if (id >= self.values.len or !self.active[id]) return Error.InvalidID;
            self.*.values[id] = value;
        }

        pub fn get(self: Self, id: u32) ?T {
            if (id >= self.values.len or !self.active[id]) return null;
            return self.values[id];
        }

        pub fn size(self: Self) usize {
            return self.values.len;
        }

        pub fn getPtr(self: *Self, id: u32) ?*T {
            if (id >= self.values.len or !self.active[id]) return null;
            return &self.values[id];
        }

        pub fn getActiveIDs(self: Self) []bool {
            return self.active;
        }

        pub fn toSlice(self: Self) []T {
            return self.values;
        }

        pub fn delete(self: *Self, id: u32) !void {
            if (id >= self.values.len or !self.active[id]) return Error.InvalidID;
            self.*.active[id] = false;

            if (self.open_len == self.open.len) {
                self.*.open = try self.allocator.realloc(self.open, self.open.len + 1);
            }

            self.open[self.open_len] = id;
            self.*.open_len += 1;
        }
    };
}

pub fn parseFingerprint(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidLength;
    var out: [32]u8 = undefined;
    _ = try fmt.hexToBytes(&out, hex);
    return out;
}

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
