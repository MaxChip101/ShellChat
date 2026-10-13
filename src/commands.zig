const std = @import("std");
const mem = std.mem;
const log = std.log;
const Io = std.Io;

const server_handler = @import("server_handler.zig");

const zlua = @import("lua");

pub fn runCommand(allocator: mem.Allocator, io: Io, client_id: u32, server: *server_handler.Server, command_str: []const u8) !bool {
    // get command and args
    var it = mem.splitScalar(u8, command_str, ' ');
    const command = it.first();
    var args_list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (isInternalCommand(command)) {
        return try runInternalCommand(io, server, client_id, command, args);
    } else {
        return try runLuaCommand(io, server, client_id, command, args);
    }
}

const internal_commands = [_][]const u8{
    "/exit",
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
    _ = io;
    _ = args;
    if (mem.eql(u8, command, internal_commands[0])) {
        server.removeClient(client_id);
    }
    return true;
}

fn runLuaCommand(io: Io, server: *server_handler.Server, client_id: u32, command: []const u8, args: [][]const u8) !bool {
    const callback = server.commands.get(command) orelse {
        server.sendFmt(client_id, .StdErr, "Command: \'{s}\' does not exist\r\n", .{command});
        return false;
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
        return false;
    };
    return true;
}
