const std = @import("std");
const mem = std.mem;
const log = std.log;
const Io = std.Io;

const server_handler = @import("server_handler.zig");
const tools = @import("tools.zig");

const zlua = @import("lua");

const Ctx = struct {
    allocator: mem.Allocator,
    io: Io,
    server: *server_handler.Server,
    client_id: u32,
    args: []const []const u8,

    const Self = @This();

    fn fail(self: *Self, comptime fmt: []const u8, args: anytype) error{BadArgs} {
        self.server.sendFmt(self.client_id, .StdErr, fmt ++ "\r\n", args);
        return error.BadArgs;
    }

    fn ok(self: *Self, msg: []const u8) bool {
        self.server.sendFmt(self.client_id, .StdOut, "{s}\r\n", .{msg});
        return false;
    }
};

const Handler = *const fn (*Ctx) anyerror!bool;

const command_list = std.StaticStringMap(Handler).initComptime(.{
    .{ "/exit", &cmdExit },
    .{ "/help", &cmdHelp },
    .{ "/join", &cmdJoin },
    .{ "/leave", &cmdLeave },
    .{ "/whitelist", &cmdWhitelist },
    .{ "/blacklist", &cmdBlacklist },
    .{ "/createChannel", &cmdCreateChannel },
    .{ "/removeChannel", &cmdRemoveChannel },
    .{ "/list", &cmdList },
    .{ "/broadcast", &cmdBroadcast },
});

pub fn runCommand(allocator: mem.Allocator, io: Io, client_id: u32, server: *server_handler.Server, command_str: []const u8) !bool {
    var it = mem.tokenizeScalar(u8, command_str, ' ');
    const command = it.next() orelse return false;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    while (it.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    if (command[0] != '/') {
        // handle sending to channel
        return false;
    }

    if (command_list.get(command)) |handler| {
        var ctx: Ctx = .{ .allocator = allocator, .io = io, .server = server, .client_id = client_id, .args = args_list.items };
        return handler(&ctx) catch |err| switch (err) {
            error.BadArgs, error.PermissionDenied => false,
            else => return err,
        };
    }

    try runLuaCommand(io, server, client_id, command, args_list.items);
    return false;
}

fn requireRank(ctx: *Ctx, needed: u8) !server_handler.WhitelistClient {
    const me = try ctx.server.getWhitelistClient(ctx.client_id) orelse return error.PermissionDenied;
    if (me.rank < needed) {
        ctx.server.sendFmt(ctx.client_id, .StdErr, "Invalid Permissions: {d} < {d}\r\n", .{ me.rank, needed });
        return error.PermissionDenied;
    }
    return me;
}

fn cmdExit(_: *Ctx) !bool {
    return true;
}

fn cmdHelp(ctx: *Ctx) !bool {
    ctx.server.sendTo(ctx.client_id, .StdOut, "Internal Commands:\n\r");
    for (command_list.keys()) |cmd| {
        ctx.server.sendFmt(ctx.client_id, .StdOut, "\t{s}\n\r", .{cmd});
    }
    ctx.server.sendTo(ctx.client_id, .StdOut, "Lua Commands:\n\r");
    for (ctx.server.commands.keys()) |cmd| {
        ctx.server.sendFmt(ctx.client_id, .StdOut, "\t{s}\n\r", .{cmd});
    }
    return false;
}

fn cmdJoin(ctx: *Ctx) !bool {
    if (ctx.args.len < 1) return ctx.fail("Missing arguments: [channel_name]", .{});
    const me = try requireRank(ctx, 0);
    var channel = try ctx.server.getChannelFromName(ctx.args[0]) orelse
        return ctx.fail("Channel does not exist with name: {s}", .{ctx.args[0]});
    if (channel.rank > me.rank) {
        channel.deinit(ctx.server.allocator);
        return ctx.fail("Channel does not exist with name: {s}", .{ctx.args[0]});
    }
    ctx.server.setChannel(ctx.client_id, channel);
    return false;
}

fn cmdLeave(ctx: *Ctx) !bool {
    ctx.server.setChannel(ctx.client_id, null);
    return false;
}

fn cmdWhitelist(ctx: *Ctx) !bool {
    const me = try requireRank(ctx, ctx.server.manage_whitelist_rank);
    if (ctx.args.len < 2) return ctx.fail("Missing arguments: [fingerprint] [rank]", .{});
    const fp = tools.parseFingerprint(ctx.args[0]) catch
        return ctx.fail("Invalid fingerprint: {s}", .{ctx.args[0]});
    const rank = std.fmt.parseInt(u8, ctx.args[1], 10) catch
        return ctx.fail("Invalid rank: {s}", .{ctx.args[1]});
    if (rank > me.rank) return ctx.fail("You cannot grant a rank above your own ({d})", .{me.rank});
    if (!try ctx.server.whitelistClient(fp, rank, me.rank))
        return ctx.fail("You cannot change a higher-ranked client", .{});
    return ctx.ok("Successfully whitelisted client");
}

fn cmdBlacklist(ctx: *Ctx) !bool {
    const me = try requireRank(ctx, ctx.server.manage_whitelist_rank);
    if (ctx.args.len < 2) return ctx.fail("Missing arguments: [fingerprint] [rank]", .{});
    const target_id = std.fmt.parseInt(u32, ctx.args[0], 10) catch
        return ctx.fail("Invalid client id: {s}", .{ctx.args[0]});
    const target = try ctx.server.getWhitelistClient(target_id) orelse
        return ctx.fail("Client does not exist with id: {d}", .{target_id});
    if (target.rank > me.rank) return ctx.fail("You cannot blacklist a higher-ranked client", .{});
    if (!try ctx.server.blacklistClient(target_id)) return ctx.fail("Failed to blacklist client", .{});
    return ctx.ok("Successfully blacklisted client");
}

fn cmdCreateChannel(ctx: *Ctx) !bool {
    _ = try requireRank(ctx, ctx.server.manage_channel_rank);
    if (ctx.args.len < 3) return ctx.fail("Missing arguments: [name] [type] [rank]", .{});
    const rank = std.fmt.parseInt(u8, ctx.args[2], 10) catch
        return ctx.fail("Invalid rank: {s}", .{ctx.args[2]});
    try ctx.server.addChannel(ctx.args[0], ctx.args[1], rank);
    return ctx.ok("Successfully created channel");
}

fn cmdRemoveChannel(ctx: *Ctx) !bool {
    _ = try requireRank(ctx, ctx.server.manage_channel_rank);
    if (ctx.args.len < 1) return ctx.fail("Missing arguments: [channel_id]", .{});
    const id = std.fmt.parseInt(u32, ctx.args[0], 10) catch
        return ctx.fail("Invalid channel id: {s}", .{ctx.args[0]});
    if (!try ctx.server.removeChannel(id)) return ctx.fail("Failed to remove channel", .{});
    return ctx.ok("Successfully removed channel");
}

fn cmdList(ctx: *Ctx) !bool {
    if (ctx.args.len < 1) return ctx.fail("Missing arguments: [channels, whitelist, clients, channel_types]", .{});
    return ctx.ok("IMPL");
}

fn cmdBroadcast(ctx: *Ctx) !bool {
    if (ctx.args.len == 0) return ctx.fail("Missing message: /broadcast [message]", .{});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);

    for (ctx.args, 0..) |arg, i| {
        if (i > 0) try buf.append(ctx.allocator, ' ');
        try buf.appendSlice(ctx.allocator, arg);
    }
    try buf.appendSlice(ctx.allocator, "\r\n");

    ctx.server.broadcast(.StdOut, buf.items);
    return false;
}

fn runLuaCommand(io: Io, server: *server_handler.Server, client_id: u32, command: []const u8, args: [][]const u8) !void {
    const callback = server.commands.get(command) orelse {
        server.sendFmt(client_id, .StdErr, "Command: \'{s}\' does not exist\r\n", .{command});
        return;
    };

    server.lua_mutex.lockUncancelable(io);
    defer server.lua_mutex.unlock(io);

    const lua = server.lua;

    _ = lua.getIndexRaw(zlua.registry_index, callback);

    lua.pushInteger(client_id);

    _ = lua.pushString(command);

    lua.newTable();
    for (args, 0..) |arg, i| {
        _ = lua.pushString(arg);
        lua.setIndexRaw(-2, @intCast(i + 1));
    }

    lua.protectedCall(.{ .args = 3, .results = 0 }) catch |err| {
        const err_msg = lua.toString(-1) catch "Unknown Lua error";
        log.err("Command had an error while executing \'{s}\': {s}, {}", .{ command, err_msg, err });
        server.sendFmt(client_id, .StdErr, "Command had an error while executing \'{s}\': {s}, {}\r\n", .{ command, err_msg, err });
        lua.pop(1);
    };
}
