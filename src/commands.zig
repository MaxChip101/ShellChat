const std = @import("std");
const mem = std.mem;
const log = std.log;
const Io = std.Io;

const server_handler = @import("server_handler.zig");
const tools = @import("tools.zig");

const zlua = @import("lua");

pub fn runCommand(allocator: mem.Allocator, io: Io, client_id: u32, server: *server_handler.Server, command_str: []const u8) !bool {
    if (command_str.len == 0) return false;

    // get command and args
    var it = mem.splitScalar(u8, command_str, ' ');
    const command = it.first();
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    while (it.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (isInternalCommand(command)) {
        return try runInternalCommand(io, server, client_id, command, args);
    }

    try runLuaCommand(io, server, client_id, command, args);
    return false;
}

const internal_commands = [_][]const u8{
    "/exit",
    "/help",
    "/join",
    "/leave",
    "/whitelist",
    "/blacklist",
    "/createChannel",
    "/removeChannel",
    "/list",
};

fn isInternalCommand(command: []const u8) bool {
    for (internal_commands) |in_cmd| {
        if (mem.eql(u8, command, in_cmd)) {
            return true;
        }
    }
    return false;
}

fn runInternalCommand(io: Io, server: *server_handler.Server, client_id: u32, command: []const u8, args: [][]const u8) !bool {
    if (mem.eql(u8, command, internal_commands[0])) { // /exit
        return true;
    } else if (mem.eql(u8, command, internal_commands[1])) { // /help
        server.sendTo(client_id, .StdOut, "Internal Commands:\n\r");
        for (internal_commands) |cmd| {
            server.sendFmt(client_id, .StdOut, "\t{s}\n\r", .{cmd});
        }
        server.sendTo(client_id, .StdOut, "Lua Commands:\n\r");
        for (server.commands.keys()) |cmd| {
            server.sendFmt(client_id, .StdOut, "\t{s}\n\r", .{cmd});
        }
    } else if (mem.eql(u8, command, internal_commands[2])) { // /join [channel]
        if (args.len < 1) {
            server.sendTo(client_id, .StdErr, "Missing arguments: [channel_name]\r\n");
            return false;
        }
        if (try server.getChannelFromName(args[0])) |channel| {
            server.state_mutex.lockUncancelable(io);
            defer server.state_mutex.unlock(io);
            const client = server.clients.getPtr(client_id) orelse return false;
            client.*.channel = channel;
        } else {
            server.sendFmt(client_id, .StdErr, "Channel does not exist with name: {s}\r\n", .{args[0]});
        }
    } else if (mem.eql(u8, command, internal_commands[3])) { // /leave
        server.state_mutex.lockUncancelable(io);
        defer server.state_mutex.unlock(io);
        const client = server.clients.getPtr(client_id) orelse return false;
        client.*.channel = null;
    } else if (mem.eql(u8, command, internal_commands[4])) { // whitelist [fingerprint] [rank]
        const client = try server.getWhitelistClient(client_id) orelse {
            return false;
        };

        if (client.rank < server.manage_whitelist_rank) {
            server.sendFmt(client_id, .StdErr, "Invalid Permissions: {d} < {d}\r\n", .{ client.rank, server.manage_whitelist_rank });
            return false;
        }

        if (args.len < 2) {
            server.sendTo(client_id, .StdErr, "Missing arguments: [fingerprint] [rank]\r\n");
            return false;
        }
        const fingerprint = tools.parseFingerprint(args[0]) catch {
            server.sendFmt(client_id, .StdErr, "Invalid fingerprint: {s}\r\n", .{args[0]});
            return false;
        };
        const rank = std.fmt.parseInt(u8, args[1], 10) catch {
            server.sendFmt(client_id, .StdErr, "Invalid rank: {s}\r\n", .{args[1]});
            return false;
        };
        try server.whitelistClient(fingerprint, rank);
        server.sendTo(client_id, .StdOut, "Successfully whitelisted client\r\n");
    } else if (mem.eql(u8, command, internal_commands[5])) { // blacklist [client_id]
        const client = try server.getWhitelistClient(client_id) orelse {
            return false;
        };

        if (client.rank < server.manage_whitelist_rank) {
            server.sendFmt(client_id, .StdErr, "Invalid Permissions: {d} < {d}\r\n", .{ client.rank, server.manage_whitelist_rank });
            return false;
        }

        if (args.len < 1) {
            server.sendTo(client_id, .StdErr, "Missing argument: [client_id]\r\n");
            return false;
        }
        const c_id = std.fmt.parseInt(u32, args[1], 10) catch {
            server.sendFmt(client_id, .StdErr, "Invalid client id: {s}\r\n", .{args[0]});
            return false;
        };
        const successful = try server.blacklistClient(c_id);
        if (successful) {
            server.sendTo(client_id, .StdOut, "Successfully blacklisted client\r\n");
        } else {
            server.sendTo(client_id, .StdErr, "Failed to blacklist client\r\n");
        }
    } else if (mem.eql(u8, command, internal_commands[6])) { // createChannel [name] [type] [rank]
        const client = try server.getWhitelistClient(client_id) orelse {
            return false;
        };

        if (client.rank < server.manage_channel_rank) {
            server.sendFmt(client_id, .StdErr, "Invalid Permissions: {d} < {d}\r\n", .{ client.rank, server.manage_channel_rank });
            return false;
        }

        if (args.len < 3) {
            server.sendTo(client_id, .StdErr, "Missing arguments: [name] [type] [rank]\r\n");
            return false;
        }
        const rank = std.fmt.parseInt(u8, args[2], 10) catch {
            server.sendFmt(client_id, .StdErr, "Invalid rank: {s}\r\n", .{args[1]});
            return false;
        };
        try server.addChannel(args[0], args[1], rank);
        server.sendTo(client_id, .StdOut, "Successfully created channel\r\n");
    } else if (mem.eql(u8, command, internal_commands[7])) { // removeChannel [channel_id]
        const client = try server.getWhitelistClient(client_id) orelse {
            return false;
        };

        if (client.rank < server.manage_channel_rank) {
            server.sendFmt(client_id, .StdErr, "Invalid Permissions: {d} < {d}\r\n", .{ client.rank, server.manage_channel_rank });
            return false;
        }

        if (args.len < 1) {
            server.sendTo(client_id, .StdErr, "Missing arguments: [channel_id]\r\n");
            return false;
        }
        const channel_id = std.fmt.parseInt(u32, args[1], 10) catch {
            server.sendFmt(client_id, .StdErr, "Invalid channel id: {s}\r\n", .{args[0]});
            return false;
        };
        const successful = try server.removeChannel(channel_id);
        if (successful) {
            server.sendTo(client_id, .StdOut, "Successfully removed channel\r\n");
        } else {
            server.sendTo(client_id, .StdErr, "Failed to remove channel\r\n");
        }
    } else if (mem.eql(u8, command, internal_commands[8])) { // /list [topic]
        if (args.len < 1) {
            server.sendTo(client_id, .StdErr, "Missing arguments: [channels, whitelist, clients, channel_types]\r\n");
            return false;
        }

        if (mem.eql(u8, args[0], "channels")) {
            var result = try server.getChannels(client_id);
            defer result.deinit();

            server.sendTo(client_id, .StdOut, "Channels:\r\n");

            while (try result.next()) |row| {
                const id = try row.get(i32, 0);
                const name = try row.get([]const u8, 1);
                const channel_type = try row.get([]const u8, 2);
                const rank = try row.get(i16, 3);

                server.sendFmt(client_id, .StdOut, "\tid: {d}\tname: {s}\ttype: {s}\trank: {d}\r\n", .{ id, name, channel_type, rank });
            }
        } else if (mem.eql(u8, args[0], "whitelist")) {
            var result = try server.getWhitelist();
            defer result.deinit();

            server.sendTo(client_id, .StdOut, "Whitelist:\r\n");

            while (try result.next()) |row| {
                const id = try row.get(i32, 0);
                const fingerprint = try row.get([]const u8, 1);
                const rank = try row.get(i16, 2);

                server.sendFmt(client_id, .StdOut, "\tid: {d}\tfingerprint: {x}\trank: {d}\r\n", .{ id, fingerprint, rank });
            }
        } else if (mem.eql(u8, args[0], "clients")) {
            server.state_mutex.lockUncancelable(io);
            var it = server.clients.iterator();
            server.state_mutex.unlock(io);

            server.sendTo(client_id, .StdOut, "Clients:\r\n");
            while (it.next()) |client| {
                server.sendFmt(client_id, .StdOut, "\t{s} : {x}\r\n", .{ client.value_ptr.*.name, client.value_ptr.*.fingerprint });
            }
        } else if (mem.eql(u8, args[0], "channel_types")) {
            server.sendTo(client_id, .StdOut, "Channel Types:\r\n");
            for (server.channel_types.keys()) |channel_type| {
                server.sendFmt(client_id, .StdOut, "\t{s}\r\n", .{channel_type});
            }
        } else {
            server.sendFmt(client_id, .StdErr, "'{s}' is not a listable topic", .{args[0]});
        }
    }
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
