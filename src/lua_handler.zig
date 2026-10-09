const std = @import("std");
const log = std.log;

const server_handler = @import("server_handler.zig");

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

pub fn pullBool(lua: *zlua.Lua, idx: i32) bool {
    return lua.toBoolean(idx);
}

pub fn pullString(lua: *zlua.Lua, idx: i32) [:0]const u8 {
    return lua.toString(idx) catch "";
}

pub fn pullFunc(lua: *zlua.Lua, idx: i32) i32 {
    lua.pushValue(idx);
    return lua.ref(zlua.registry_index);
}

pub const lib_funcs = [_]zlua.FnReg{
    .{ .name = "registerCommand", .func = zlua.wrap(registerCommand) },
};

// Library functions

pub fn registerCommand(lua: *zlua.Lua) i32 {
    const raw_command = pullString(lua, 1);
    const callback = pullFunc(lua, 2);

    _ = lua.getField(zlua.registry_index, "SERVER");
    const server = lua.toUserdata(server_handler.Server, -1) catch {
        lua.raiseErrorStr("Failed to get the server from registery", .{});
    };
    lua.pop(1);

    const command = server.allocator.dupe(u8, raw_command) catch {
        lua.raiseErrorStr("Out of memory allocating command string", .{});
    };

    server.addCommand(command, callback) catch |err| {
        server.allocator.free(command);
        log.err("[INTERNAL] failed to register command to server: {}", .{err});
    };

    return 0;
}
