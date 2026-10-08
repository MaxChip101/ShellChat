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
    whitelist: std.StringArrayHashMapUnmanaged(server_handler.Client),
    channels: std.StringArrayHashMapUnmanaged(server_handler.Channel),
    host: []const u8,
    port: u16,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        for (self.whitelist.values()) |client| {
            allocator.free(client.username);
        }
        for (self.channels.values()) |*channel| {
            channel.permissions.deinit(allocator);
        }
        self.channels.deinit(allocator);
        self.whitelist.deinit(allocator);
        allocator.free(self.title);
        allocator.free(self.host);
    }
};

const Config = struct {
    title: []const u8,
    whitelisted_clients: []Client,
    channels: []Channel,
    host: []const u8,
    port: u16,
};

pub const Client = struct {
    username: []const u8,
    fingerprint: []const u8,
    rank: u8,
};

pub const Channel = struct {
    name: []const u8,
    type: []const u8,
    permissions: []Permission,
};

pub const Permission = struct {
    name: []const u8,
    rank: u8,
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
        log.err("failed to parse or find config.toml in binary directory", .{});
        return err;
    };
    defer result.deinit();

    const config = result.value;

    var whitelist: std.StringArrayHashMapUnmanaged(server_handler.Client) = .empty;
    try whitelist.ensureTotalCapacity(allocator, config.whitelisted_clients.len);

    for (config.whitelisted_clients, 0..) |client, i| {
        const fingerprint = parseFingerprint(client.fingerprint) catch |err| {
            log.err("config.toml: whitelisted_clients[{d}] is not a valid fingerprint", .{i});
            return err;
        };
        const key = try allocator.dupe(u8, &fingerprint);
        whitelist.putAssumeCapacity(key, .{
            .username = try allocator.dupe(u8, client.username),
            .fingerprint = fingerprint,
            .rank = client.rank,
        });
    }

    var channels: std.StringArrayHashMapUnmanaged(server_handler.Channel) = .empty;
    try channels.ensureTotalCapacity(allocator, config.channels.len);

    for (config.channels) |channel| {
        var permissions: std.StringArrayHashMapUnmanaged(u8) = .empty;
        try permissions.ensureTotalCapacity(allocator, channel.permissions.len);
        for (channel.permissions) |permission| {
            permissions.putAssumeCapacity(permission.name, permission.rank);
        }
        channels.putAssumeCapacity(channel.name, .{ .type = channel.type, .permissions = permissions });
    }

    return .{
        .title = try allocator.dupe(u8, config.title),
        .whitelist = whitelist,
        .channels = channels,
        .host = try allocator.dupe(u8, config.host),
        .port = config.port,
    };
}
