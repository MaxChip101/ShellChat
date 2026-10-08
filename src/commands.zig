const std = @import("std");
const mem = std.mem;
const log = std.log;

const server_handler = @import("server_handler.zig");

pub fn runCommand(allocator: mem.Allocator, client_id: u32, server: *server_handler.Server, command_str: []const u8) !void {

    // get command and args
    var it = mem.splitScalar(u8, command_str, ' ');
    const command = it.first();
    var args_list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    const callback = server.command_registery.get(command) orelse {
        log.err("Command: \'{s}\' doesn't exist", .{command});
        return error.NonExistentCommand;
    };

    // handle the lua callback
    _ = client_id;
    _ = callback;
    _ = args;
}
