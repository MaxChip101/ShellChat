const std = @import("std");
const mem = std.mem;
const log = std.log;
const crypto = std.crypto;
const Io = std.Io;

const tools = @import("tools.zig");

const toml = @import("toml");

pub const ServerInitSettings = struct {
    title: []const u8,
    whitelist: [][32]u8,
};

pub const Config = struct {
    title: []const u8,
    whitelisted_clients: []Client,
};

pub const Client = struct {
    name: []const u8,
    fingerprint: []const u8,
};

fn parseHexFingerprint(fingerprint: []const u8) ![32]u8 {
    if (fingerprint.len != 64) return error.InvalidFingerprint;
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, fingerprint);
    return out;
}

pub fn getSettings(allocator: mem.Allocator, io: Io) !ServerInitSettings {
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

    var whitelist: ?[][32]u8 = null;

    if (config.whitelist.enabled) {
        var whitelist_list: std.ArrayList([32]u8) = .empty;
        for (config.whitelisted_clients, 0..) |client, i| {
            const fingerprint = getFingerprint(allocator, pub_key) catch |err| {
                log.err("config.toml: whitelist.banned_clients[{d}] is not a valid public key", .{i});
                return err;
            };
            try whitelist_list.append(allocator, fingerprint);
        }
        whitelist = try whitelist_list.toOwnedSlice(allocator);
    }

    return .{
        .title = config.title,
        .whitelist = whitelist,
    };
}
