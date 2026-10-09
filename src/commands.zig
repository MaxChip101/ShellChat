const std = @import("std");
const mem = std.mem;
const log = std.log;

const server_handler = @import("server_handler.zig");

const zlua = @import("lua");

pub fn runCommand(allocator: mem.Allocator, client_id: u32, server: *server_handler.Server, command_str: []const u8) !bool {
    var user = server.active_clients.get(client_id) orelse return error.InvalidClient;

    // get command and args
    var it = mem.splitScalar(u8, command_str, ' ');
    const command = it.first();
    var args_list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    const callback = server.command_registery.get(command) orelse {
        try user.printTo(.StdErr, allocator, "Command: \'{s}\' does not exist\r\n", .{command});
        return false;
    };

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
        try user.printTo(.StdErr, allocator, "Command had an error while executing \'{s}\': {s}, {}\r\n", .{ command, err_msg, err });
        lua.pop(1);
        return false;
    };
    return true;
}
