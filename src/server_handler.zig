const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const atomic = std.atomic;

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

    title: []const u8 = "chat server",
    manage_whitelist_rank: u8 = 255,
    manage_channel_rank: u8 = 255,

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

    pub fn setTitle(self: *Self, raw_title: []const u8) !void {
        const title = try self.allocator.dupe(u8, raw_title);
        self.title = title;
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
            client.deinit(self.allocator);
            self.allocator.destroy(client);
        }

        self.allocator.free(self.title);

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

    pub fn getChannels(self: *Self, client_id: u32) !*pg.Result {
        const client = try self.getWhitelistClient(client_id) orelse return error.InvalidClientID;
        return try self.pool.query("SELECT * FROM channels WHERE rank <= $1", .{client.rank});
    }

    pub fn getWhitelist(self: *Self) !*pg.Result {
        return try self.pool.query("SELECT * FROM whitelist", .{});
    }

    pub fn addChannel(self: *Self, name: []const u8, channel_type: []const u8, rank: u8) !void {
        _ = try self.pool.exec("INSERT INTO channels (name, type, rank) VALUES ($1, $2, $3)", .{ name, channel_type, rank });
    }

    pub fn removeChannel(self: *Self, id: u32) !bool {
        const affected = try self.pool.exec("DELETE FROM channels WHERE id = $1", .{id});
        if ((affected orelse 0) == 0) return false;
        return true;
    }

    pub fn addCommand(self: *Self, command_name: []const u8, lua_callback: i32) !void {
        try self.*.commands.put(self.allocator, command_name, lua_callback);
    }

    pub fn addClient(self: *Self, client_id: u32, name: []const u8, fingerprint: [32]u8) !*Client {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const client = try self.allocator.create(Client);
        errdefer self.allocator.destroy(client);
        client.* = .{ .name = name_copy, .fingerprint = fingerprint };

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        const gop = try self.clients.getOrPut(client_id);
        if (gop.found_existing) return error.AlreadyConnected;
        gop.value_ptr.* = client;
        return client;
    }

    pub fn removeClient(self: *Self, client_id: u32) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        const kv = self.clients.fetchRemove(client_id) orelse return;
        kv.value.deinit(self.allocator);
        self.allocator.destroy(kv.value);
    }

    pub fn whitelistClient(self: *Self, fingerprint: [32]u8, rank: u8, actor_rank: u8) !bool {
        const affected = try self.pool.exec(
            \\INSERT INTO whitelist (fingerprint, rank) VALUES ($1, $2)
            \\ON CONFLICT (fingerprint) DO UPDATE SET rank = EXCLUDED.rank
            \\WHERE whitelist.rank <= $3
        , .{ fingerprint, rank, actor_rank });
        return (affected orelse 0) > 0;
    }

    pub fn blacklistClient(self: *Self, client_id: u32) !bool {
        const affected = try self.pool.exec("DELETE FROM whitelist WHERE id = $1", .{client_id});
        if ((affected orelse 0) == 0) return false;

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.clients.get(client_id)) |client| client.kicked.store(true, .release);

        return true;
    }

    pub fn getChannelFromName(self: *Server, channel_name: []const u8) !?*Channel {
        var row = try self.pool.row("SELECT * FROM channels WHERE name = $1", .{channel_name}) orelse return null;
        defer row.deinit() catch {};

        const id = std.math.cast(u32, try row.get(i32, 0)) orelse return error.InvalidChannel;
        const rank = std.math.cast(u8, try row.get(i16, 3)) orelse return error.InvalidRank;
        const owned_name = try self.allocator.dupe(u8, try row.get([]const u8, 1));
        errdefer self.allocator.free(owned_name);
        const owned_type = try self.allocator.dupe(u8, try row.get([]const u8, 2));
        errdefer self.allocator.free(owned_type);

        const channel = try self.allocator.create(Channel);
        channel.* = .{
            .id = id,
            .name = owned_name,
            .type = owned_type,
            .rank = rank,
        };

        return channel;
    }

    pub fn setChannel(self: *Server, client_id: u32, channel: ?*Channel) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const client = self.clients.getPtr(client_id) orelse {
            if (channel) |ch| {
                ch.deinit(self.allocator);
            }
            return;
        };
        if (client.*.channel) |old| {
            old.deinit(self.allocator);
        }
        client.*.channel = channel;
    }

    pub fn getWhitelistClient(self: *Server, client_id: u32) !?WhitelistClient {
        var row = try self.pool.row("SELECT * FROM whitelist WHERE id = $1", .{client_id}) orelse return null;
        defer row.deinit() catch {};

        const fp_bytes = try row.get([]const u8, 1);
        if (fp_bytes.len != 32) {
            return error.InvalidFingerprint;
        }
        var fingerprint: [32]u8 = undefined;
        @memcpy(&fingerprint, fp_bytes);

        const rank: u8 = @intCast(try row.get(i16, 2));

        return .{ .id = client_id, .fingerprint = fingerprint, .rank = rank };
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
        const str = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(str);
        self.sendTo(client_id, stream, str);
    }

    pub fn sendLocked(self: *Server, client: *Client, stream: Stream, bytes: []const u8) void {
        if (bytes.len > 4096 or client.outbox.items.len >= 256)
            return;

        const copy = self.allocator.dupe(u8, bytes) catch return;
        client.outbox.append(self.allocator, .{ .stream = stream, .bytes = copy }) catch {
            self.allocator.free(copy);
            return;
        };
    }

    pub fn sendLockedFmt(self: *Server, client: *Client, stream: Stream, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(str);
        self.sendLocked(client, stream, str);
    }

    pub fn broadcast(self: *Server, stream: Stream, bytes: []const u8) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        var it = self.clients.valueIterator();
        while (it.next()) |client| {
            self.sendLocked(client.*, stream, bytes);
        }
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
    name: []const u8,
    fingerprint: [32]u8,
    outbox: std.ArrayListUnmanaged(OutMsg) = .empty,
    channel: ?*Channel = null,
    kicked: atomic.Value(bool) = .init(false),
    cols: u16 = 80,
    rows: u16 = 24,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        for (self.outbox.items) |m| allocator.free(m.bytes);
        self.outbox.deinit(allocator);
        allocator.free(self.name);
        if (self.channel) |channel| {
            channel.deinit(allocator);
        }
    }
};

pub const Channel = struct {
    id: u32,
    name: []const u8,
    type: []const u8,
    rank: u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.type);
    }
};

pub const WhitelistClient = struct {
    id: u32,
    fingerprint: [32]u8,
    rank: u8,
};
