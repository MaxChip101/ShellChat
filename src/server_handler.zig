const std = @import("std");
const mem = std.mem;

const ssh_handler = @import("ssh_handler.zig");
const tools = @import("tools.zig");

const ssh = @import("ssh");

pub const Server = struct {
    allocator: mem.Allocator,
    title: []const u8,
    whitelist: std.StringArrayHashMapUnmanaged(Client),
    channels: std.StringArrayHashMapUnmanaged(Channel),
    active_clients: tools.IDMap(Client),

    const Self = @This();

    pub fn init(
        allocator: mem.Allocator,
        title: []const u8,
        whitelist: std.StringArrayHashMapUnmanaged(Client),
        channels: std.StringArrayHashMapUnmanaged(Channel),
    ) Self {
        const active_clients: tools.IDMap(Client) = .init(allocator);

        return .{
            .allocator = allocator,
            .title = title,
            .whitelist = whitelist,
            .channels = channels,
            .active_clients = active_clients,
        };
    }

    pub fn deinit(self: *Self) void {
        self.active_clients.deinit();
    }

    pub fn isAuthenticClient(self: *Self, client: Client) bool {
        if (self.whitelist.get(&client.fingerprint)) |valid_client| {
            if (mem.eql(u8, valid_client.username, client.username)) return true;
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
    type: []const u8,
    permissions: std.StringArrayHashMapUnmanaged(u8),
    // work on channels
};

pub const WriteMethod = enum {
    StdErr,
    StdOut,
};

pub const Client = struct {
    username: []const u8,
    fingerprint: [32]u8,
    rank: u8,
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
