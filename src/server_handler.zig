const std = @import("std");
const mem = std.mem;

const ssh_handler = @import("ssh_handler.zig");
const tools = @import("tools.zig");

const ssh = @import("ssh");
const zlua = @import("lua");
const pg = @import("pg");

pub const Server = struct {
    allocator: mem.Allocator,
    pool: *pg.Pool,
    // replace with db
    //whitelist: std.StringArrayHashMapUnmanaged(Client),
    //channels: std.StringArrayHashMapUnmanaged(Channel),
    active_clients: std.AutoHashMap(u32, Client),
    command_registery: std.StringArrayHashMapUnmanaged(i32), // lua function callback values
    lua: *zlua.Lua,

    const Self = @This();

    pub fn init(allocator: mem.Allocator, lua: *zlua.Lua, pool: *pg.Pool) Self {
        const active_clients: std.AutoHashMap(u32, Client) = .init(allocator);
        const command_registery: std.StringArrayHashMapUnmanaged(i32) = .empty;

        return .{
            .allocator = allocator,
            .active_clients = active_clients,
            .command_registery = command_registery,
            .lua = lua,
            .pool = pool,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.command_registery.keys()) |key| {
            self.allocator.free(key);
        }

        self.active_clients.deinit();
        self.command_registery.deinit(self.allocator);
    }

    pub fn isAuthenticClient(self: *Self, fingerprint: [32]u8) bool {
        _ = self;
        const valid_fingerprint = fingerprint; // get from database
        if (mem.eql(u8, &valid_fingerprint, &fingerprint)) return true;
        return false;
    }

    pub fn addCommand(self: *Self, command_name: []const u8, lua_callback: i32) !void {
        try self.*.command_registery.put(self.allocator, command_name, lua_callback);
    }

    pub fn addClient(self: *Self, client: Client) !void {
        try self.*.active_clients.put(client.id, client);
    }

    pub fn removeClient(self: *Self, id: u32) !void {
        _ = self.*.active_clients.remove(id);
    }
};

pub const WriteMethod = enum {
    StdErr,
    StdOut,
};

pub const ClientMode = enum {
    Normal,
    Focused,
};

pub const Client = struct {
    id: u32, // postgresql database client id
    mode: ClientMode = .Normal,
    focused_channel: ?[]const u8 = null,
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
