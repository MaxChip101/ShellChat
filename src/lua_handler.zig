const std = @import("std");
const log = std.log;

const server_handler = @import("server_handler.zig");
const tools = @import("tools.zig");

const zlua = @import("lua");

pub const lib_name = "server";

// Helper functions

pub fn pullNumber(lua: *zlua.Lua, idx: i32) f32 {
    return @floatCast(lua.toNumber(idx) catch 0.0);
}

pub fn pullInt(lua: *zlua.Lua, idx: i32) i32 {
    return @intCast(lua.toInteger(idx) catch 0);
}

pub fn pullUInt(lua: *zlua.Lua, idx: i32) u32 {
    return @intCast(lua.toInteger(idx) catch 0);
}

pub fn pullString(lua: *zlua.Lua, idx: i32) [:0]const u8 {
    return lua.toString(idx) catch "";
}

pub fn pullFunc(lua: *zlua.Lua, idx: i32) i32 {
    lua.pushValue(idx);
    return lua.ref(zlua.registry_index);
}

pub fn getServer(lua: *zlua.Lua) *server_handler.Server {
    _ = lua.getField(zlua.registry_index, "SERVER");
    const server = lua.toUserdata(server_handler.Server, -1) catch {
        lua.raiseErrorStr("Failed to get the server from registery", .{});
    };
    lua.pop(1);
    return server;
}

pub const lib_funcs = [_]zlua.FnReg{
    .{ .name = "registerCommand", .func = zlua.wrap(registerCommand) },
    .{ .name = "createChannel", .func = zlua.wrap(createChannel) },
    .{ .name = "deleteChannel", .func = zlua.wrap(deleteChannel) },
    .{ .name = "whitelistClient", .func = zlua.wrap(whitelistClient) },
    .{ .name = "blacklistClient", .func = zlua.wrap(blacklistClient) },
    .{ .name = "printClient", .func = zlua.wrap(printClient) },
    .{ .name = "warnClient", .func = zlua.wrap(warnClient) },
    .{ .name = "errorClient", .func = zlua.wrap(errorClient) },
};

// Library functions

pub fn registerCommand(lua: *zlua.Lua) i32 {
    const raw_command = pullString(lua, 1);
    const callback = pullFunc(lua, 2);

    const server = getServer(lua);

    const command = server.allocator.dupe(u8, raw_command) catch {
        lua.raiseErrorStr("Out of memory allocating command string", .{});
    };

    server.addCommand(command, callback) catch |err| {
        server.allocator.free(command);
        log.err("[INTERNAL] failed to register command to server: {}", .{err});
        return 0;
    };

    return 0;
}

pub fn createChannel(lua: *zlua.Lua) i32 {
    const name = pullString(lua, 1);
    const channel_type = pullString(lua, 2);
    const raw_rank = pullUInt(lua, 3);

    const rank: u8 = @intCast(raw_rank);

    const server = getServer(lua);

    server.addChannel(name, channel_type, rank) catch |err| {
        log.err("[INTERNAL] failed to create channel on database: {}", .{err});
        return 0;
    };

    return 0;
}

pub fn deleteChannel(lua: *zlua.Lua) i32 {
    const id = pullUInt(lua, 1);

    const server = getServer(lua);

    const successful = server.removeChannel(id) catch |err| {
        log.err("[INTERNAL] failed to create channel on database: {}", .{err});
        return 0;
    };

    if (!successful) {
        lua.raiseErrorStr("Failed to delete channel with id: {d}", .{id});
    }

    return 0;
}

pub fn whitelistClient(lua: *zlua.Lua) i32 {
    const fingerprint = pullString(lua, 1);
    const in_rank = pullUInt(lua, 2);

    if (in_rank > 255) lua.raiseErrorStr("Rank out of range", .{});

    const rank: u8 = @intCast(in_rank);

    const fp = tools.parseFingerprint(fingerprint) catch {
        lua.raiseErrorStr("Not a valid hex fingerprint: %s", .{fingerprint.ptr});
    };

    const server = getServer(lua);

    server.whitelistClient(fp, rank) catch |err| {
        log.err("[INTERNAL] failed to whitelist client on database: {}", .{err});
        return 0;
    };

    return 0;
}

pub fn blacklistClient(lua: *zlua.Lua) i32 {
    const id = pullUInt(lua, 1);

    const server = getServer(lua);

    const successful = server.blacklistClient(id) catch |err| {
        log.err("[INTERNAL] failed to blacklist client on database: {}", .{err});
        return 0;
    };

    if (!successful) {
        lua.raiseErrorStr("Failed to blacklist client with id: {d}", .{id});
    }

    return 0;
}

pub fn printClient(lua: *zlua.Lua) i32 {
    const client_id = pullUInt(lua, 1);
    const num_args = lua.getTop();

    const arg_count: usize = @intCast(num_args);

    const server = getServer(lua);

    for (2..(arg_count + 1)) |i| {
        const arg = pullString(lua, @intCast(i));
        if (i == arg_count) {
            server.sendFmt(client_id, .StdOut, "{s}\r\n", .{arg});
        } else {
            server.sendFmt(client_id, .StdOut, "{s}\t", .{arg});
        }
    }

    return 0;
}

pub fn warnClient(lua: *zlua.Lua) i32 {
    const client_id = pullUInt(lua, 1);
    const num_args = lua.getTop();

    const arg_count: usize = @intCast(num_args);

    const server = getServer(lua);

    server.sendTo(client_id, .StdErr, "Warning: ");

    for (2..(arg_count + 1)) |i| {
        const arg = pullString(lua, @intCast(i));
        if (i == arg_count) {
            server.sendFmt(client_id, .StdErr, "{s}\r\n", .{arg});
        } else {
            server.sendFmt(client_id, .StdErr, "{s}\t", .{arg});
        }
    }

    return 0;
}

pub fn errorClient(lua: *zlua.Lua) i32 {
    const client_id = pullUInt(lua, 1);
    const num_args = lua.getTop();

    const arg_count: usize = @intCast(num_args);

    const server = getServer(lua);

    server.sendTo(client_id, .StdErr, "Error: ");

    for (2..(arg_count + 1)) |i| {
        const arg = pullString(lua, @intCast(i));
        if (i == arg_count) {
            server.sendFmt(client_id, .StdErr, "{s}\r\n", .{arg});
        } else {
            server.sendFmt(client_id, .StdErr, "{s}\t", .{arg});
        }
    }

    return 0;
}
