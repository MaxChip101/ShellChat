const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const ssh_handler = @import("ssh_handler.zig");
const tools = @import("tools.zig");

const ssh = @import("ssh");
const zlua = @import("lua");
const pg = @import("pg");

pub const Server = struct {
    allocator: mem.Allocator,
    io: Io,
    pool: *pg.Pool,
    lua: *zlua.Lua,
    clients: std.AutoHashMap(u32, *Client),
    channel_types: std.StringArrayHashMapUnmanaged(i32), // lua callback
    commands: std.StringArrayHashMapUnmanaged(i32), // lua callback
    state_mutex: Io.Mutex = .init,
    lua_mutex: Io.Mutex = .init,

    const Self = @This();

    pub fn init(allocator: mem.Allocator, io: Io, lua: *zlua.Lua, pool: *pg.Pool) Self {
        const clients: std.AutoHashMap(u32, *Client) = .init(allocator);
        const commands: std.StringArrayHashMapUnmanaged(i32) = .empty;
        const channel_types: std.StringArrayHashMapUnmanaged(i32) = .empty;

        return .{
            .allocator = allocator,
            .io = io,
            .clients = clients,
            .commands = commands,
            .channel_types = channel_types,
            .lua = lua,
            .pool = pool,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.commands.keys()) |key| {
            self.allocator.free(key);
        }

        for (self.channel_types.keys()) |key| {
            self.allocator.free(key);
        }

        var it = self.clients.valueIterator();
        while (it.next()) |client_ptr| {
            const client = client_ptr.*;
            for (client.outbox.items) |m| self.allocator.free(m.bytes);
            client.outbox.deinit(self.allocator);
            self.allocator.destroy(client);
        }

        self.clients.deinit();
        self.commands.deinit(self.allocator);
        self.channel_types.deinit(self.allocator);
    }

    pub fn authenticate(self: *Self, fingerprint: [32]u8) !?u32 {
        var row = try self.pool.row(
            "SELECT id FROM whitelist WHERE fingerprint = $1",
            .{&fingerprint},
        ) orelse return null;
        defer row.deinit() catch {};
        return @intCast(try row.get(i32, 0));
    }

    pub fn addChannel(self: *Self, name: []const u8, channel_type: []const u8) !void {
        _ = try self.pool.exec("INSERT INTO channels (name, type) VALUES ($1, $2)", .{ name, channel_type });
    }

    pub fn removeChannel(self: *Self, id: u32) !bool {
        const affected = try self.pool.exec("DELETE FROM whitelist WHERE id = $1", .{id});
        if ((affected orelse 0) == 0) return false;
        return true;
    }

    pub fn addCommand(self: *Self, command_name: []const u8, lua_callback: i32) !void {
        try self.*.commands.put(self.allocator, command_name, lua_callback);
    }

    pub fn addClient(self: *Self, client_id: u32) !void {
        const client = try self.allocator.create(Client);
        errdefer self.allocator.destroy(client);
        client.* = .{};

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        try self.*.clients.put(client_id, client);
    }

    pub fn removeClient(self: *Self, client_id: u32) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        const kv = self.clients.fetchRemove(client_id) orelse return;
        const client = kv.value;

        for (client.outbox.items) |m| self.allocator.free(m.bytes);
        client.outbox.deinit(self.allocator);
        self.allocator.destroy(client);
    }

    pub fn whitelistClient(self: *Self, fingerprint: [32]u8, rank: u8) !void {
        _ = try self.pool.exec(
            \\INSERT INTO whitelist (fingerprint, rank) VALUES ($1, $2)
            \\ON CONFLICT (fingerprint) DO UPDATE SET rank = EXCLUDED.rank
        , .{ fingerprint, rank });
    }

    pub fn blacklistClient(self: *Self, client_id: u32) !bool {
        const affected = try self.pool.exec("DELETE FROM whitelist WHERE id = $1", .{client_id});
        if ((affected orelse 0) == 0) return false;

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.clients.get(client_id) != null) {
            self.removeClient(client_id);
        }

        return true;
    }

    pub fn sendTo(self: *Server, client_id: u32, stream: Stream, bytes: []const u8) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        const client = self.clients.get(client_id) orelse return;

        if (bytes.len > 4096 or client.outbox.items.len >= 256)
            return;

        const copy = self.allocator.dupe(u8, bytes) catch return;
        client.outbox.append(self.allocator, .{ .stream = stream, .bytes = copy }) catch {
            self.allocator.free(copy);
            return;
        };
    }

    pub fn sendFmt(self: *Server, client_id: u32, stream: Stream, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.sendTo(client_id, stream, str);
    }

    pub fn takeOutbox(self: *Server, client_id: u32) ?std.ArrayListUnmanaged(OutMsg) {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        const client = self.clients.get(client_id) orelse return null;
        const taken = client.outbox;
        client.*.outbox = .empty;
        return taken;
    }
};

pub const Stream = enum {
    StdErr,
    StdOut,
};

pub const OutMsg = struct {
    stream: Stream,
    bytes: []u8,
};

pub const Client = struct {
    outbox: std.ArrayListUnmanaged(OutMsg) = .empty,
};

// modular chat server
// use ssh to communicate
// lua plugins can create custom channels
// for white list only, client's with fingerprints that are already in the system are accepted
