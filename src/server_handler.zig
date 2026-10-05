const std = @import("std");
const mem = std.mem;

const tools = @import("tools.zig");

pub const ServerSettings = struct {
    whitelist_enabled: bool = true,
    // other settings along with white list and ban list
    // maybe put title here?
};

pub const Server = struct {
    allocator: mem.Allocator,
    settings: ServerSettings,
    title: []const u8,
    channels: std.AutoHashMap(usize, Channel),
    active_clients: std.AutoHashMap([32]u8, Client),

    const Self = @This();

    pub fn init(allocator: mem.Allocator, title: []const u8, settings: ServerSettings) !Self {
        const channels: std.AutoHashMap(usize, Channel) = .init(allocator);
        const active_clients: std.AutoHashMap([32]u8, Client) = .init(allocator);

        return .{
            .allocator = allocator,
            .title = title,
            .settings = settings,
            .channels = channels,
            .active_clients = active_clients,
        };
    }
};

pub const Channel = struct {
    name: []const u8,
    type: u32,
};

pub const Client = struct {
    name: []const u8,
    fingerprint: []const u8,
};

// modular chat server
// use ssh to communicate
// lua plugins can create custom channels
// for white list only, client's with fingerprints that are already in the system are accepted
