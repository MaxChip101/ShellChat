const std = @import("std");
const mem = std.mem;

const ssh_handler = @import("ssh_handler.zig");
const tools = @import("tools.zig");

const ssh = @import("ssh");

pub const Server = struct {
    allocator: mem.Allocator,
    title: []const u8,
    whitelist: ?[][32]u8,
    banlist: [][32]u8,
    channels: std.AutoHashMap(u32, Channel),
    active_clients: tools.IDMap(Client),

    const Self = @This();

    pub fn init(allocator: mem.Allocator, title: []const u8, whitelist: ?[][32]u8, banlist: [][32]u8) Self {
        const channels: std.AutoHashMap(u32, Channel) = .init(allocator);
        const active_clients: tools.IDMap(Client) = .init(allocator);

        return .{
            .allocator = allocator,
            .title = title,
            .whitelist = whitelist,
            .banlist = banlist,
            .channels = channels,
            .active_clients = active_clients,
        };
    }

    pub fn deinit(self: *Self) void {
        self.channels.deinit();
        self.active_clients.deinit();
    }

    pub fn isAuthenticClient(self: *Self, fingerprint: [32]u8) bool {
        for (self.banlist) |banned_fingerprint| {
            if (mem.eql(u8, &banned_fingerprint, &fingerprint)) return false;
        }

        if (self.whitelist) |whitelist| {
            for (whitelist) |valid_fingerprint| {
                if (mem.eql(u8, &valid_fingerprint, &fingerprint)) return true;
            }
        }
        return false;
    }

    pub fn addClient(self: *Self, client: Client) !u32 {
        return try self.*.active_clients.create(client);
    }

    pub fn removeClient(self: *Self, id: u32) !void {
        return try self.*.active_clients.delete(id);
    }
};

pub const Channel = struct {
    name: []const u8,
    type: u32,
};

pub const WriteMethod = enum {
    StdErr,
    StdOut,
};

pub const Client = struct {
    name: []const u8,
    fingerprint: [32]u8,
    channel: ssh.ssh_channel,

    const Self = @This();

    pub fn writeTo(self: *Self, method: WriteMethod, bytes: []const u8) !void {
        switch (method) {
            .StdOut => try ssh_handler.channelWriteAll(self.channel, bytes),
            .StdErr => try ssh_handler.channelWriteAllErr(self.channel, bytes),
        }
    }

    pub fn printToBuf(self: *Self, method: WriteMethod, buf: []u8, comptime format: []const u8, args: anytype) !void {
        switch (method) {
            .StdOut => try ssh_handler.channelPrintBuf(buf, self.channel, format, args),
            .StdErr => try ssh_handler.channelPrintBufErr(buf, self.channel, format, args),
        }
    }

    pub fn printTo(self: *Self, method: WriteMethod, allocator: mem.Allocator, comptime format: []const u8, args: anytype) !void {
        switch (method) {
            .StdOut => try ssh_handler.channelPrint(allocator, self.channel, format, args),
            .StdErr => try ssh_handler.channelPrintErr(allocator, self.channel, format, args),
        }
    }
};

// modular chat server
// use ssh to communicate
// lua plugins can create custom channels
// for white list only, client's with fingerprints that are already in the system are accepted
