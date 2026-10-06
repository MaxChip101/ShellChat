const std = @import("std");
const mem = std.mem;
const log = std.log;
const fmt = std.fmt;
const Io = std.Io;

const tools = @import("tools.zig");
const server_handler = @import("server_handler.zig");

const toml = @import("toml");

pub const ServerSettings = struct {
    title: []const u8,
    whitelist: []server_handler.Client,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        for (self.whitelist) |client| {
            allocator.free(client.username);
        }
        allocator.free(self.title);
        allocator.free(self.whitelist);
    }
};

const Config = struct {
    title: []const u8,
    whitelisted_clients: []Client,
};

pub const Client = struct {
    username: []const u8,
    fingerprint: []const u8,
};

fn parseFingerprint(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidLength;

    var out: [32]u8 = undefined;
    _ = try fmt.hexToBytes(&out, hex);
    return out;
}

pub fn getSettings(allocator: mem.Allocator, io: Io) !ServerSettings {
    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    const path = try tools.pathFromBinary(io, allocator, "config.toml");
    defer allocator.free(path);

    var result = parser.parseFile(io, path) catch |err| {
        log.err("cannot find config.toml in binary directory", .{});
        return err;
    };
    defer result.deinit();

    const config = result.value;

    var whitelist_list: std.ArrayList(server_handler.Client) = .empty;

    for (config.whitelisted_clients, 0..) |client, i| {
        const fingerprint = parseFingerprint(client.fingerprint) catch |err| {
            log.err("config.toml: whitelisted_clients[{d}] is not a valid fingerprint", .{i});
            return err;
        };
        try whitelist_list.append(allocator, .{
            .username = try allocator.dupe(u8, client.username),
            .fingerprint = fingerprint,
            .channel = null,
        });
    }

    return .{
        .title = try allocator.dupe(u8, config.title),
        .whitelist = try whitelist_list.toOwnedSlice(allocator),
    };
}
