const std = @import("std");
const log = std.log;
const heap = std.heap;
const mem = std.mem;
const atomic = std.atomic;
const posix = std.posix;

const commands = @import("commands.zig");
const server_handler = @import("server_handler.zig");
const ssh_handler = @import("ssh_handler.zig");
const sql_handler = @import("sql_handler.zig");
const lua_handler = @import("lua_handler.zig");
const tools = @import("tools.zig");

const ssh = @import("ssh");
const pg = @import("pg");
const zlua = @import("lua");

var running: atomic.Value(bool) = .init(true);

fn handleSignal(_: posix.SIG) callconv(.c) void {
    running.store(false, .release);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const act = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = mem.zeroes(posix.sigset_t),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);

    var gpa = heap.DebugAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }

    const lua = try zlua.Lua.init(allocator);
    defer lua.deinit();
    lua.openLibs();

    lua.newLib(&lua_handler.lib_funcs);
    lua.setGlobal(lua_handler.lib_name);

    var server: server_handler.Server = .init(allocator, lua);
    defer server.deinit();

    lua.pushLightUserdata(@ptrCast(&server));
    lua.setField(zlua.registry_index, "SERVER");

    const script = try tools.pathFromBinaryZ(io, allocator, "init.lua");
    defer allocator.free(script);

    lua.doFile(script) catch {
        const err_msg = lua.toString(-1) catch "unkown error";
        log.err("[LUA] {s}", .{err_msg});
        lua.pop(1);
        return error.LuaRuntime;
    };

    _ = lua.getGlobal(lua_handler.lib_name);

    _ = lua.getField(-1, "host");
    const raw_host = if (lua.isString(-1))
        lua_handler.pullString(lua, -1)
    else
        "127.0.0.0";

    const host = try allocator.dupe(u8, raw_host);
    defer allocator.free(host);
    lua.pop(1);

    _ = lua.getField(-1, "port");
    const raw_port = if (lua.isInteger(-1))
        lua_handler.pullUInt(lua, -1)
    else
        2222;

    const port: c_uint = @intCast(raw_port);
    lua.pop(1);
    lua.pop(1);

    _ = ssh.ssh_init();
    defer _ = ssh.ssh_finalize();

    const sshbind = ssh.ssh_bind_new() orelse return error.BindCreationFailure;
    defer ssh.ssh_bind_free(sshbind);

    const key = try tools.pathFromBinaryZ(io, allocator, "ssh_host_ed25519_key");
    defer allocator.free(key);

    _ = ssh.ssh_bind_options_set(sshbind, ssh.SSH_BIND_OPTIONS_BINDADDR, host.ptr);
    _ = ssh.ssh_bind_options_set(sshbind, ssh.SSH_BIND_OPTIONS_BINDPORT, &port);
    _ = ssh.ssh_bind_options_set(sshbind, ssh.SSH_BIND_OPTIONS_HOSTKEY, key.ptr);

    if (ssh.ssh_bind_listen(sshbind) < 0) {
        log.err("error listening on (host={s} port={d}): {s}", .{ host, port, ssh.ssh_get_error(sshbind) });
        return error.ListenFailure;
    }
    log.info("ssh server listening on: {s}:{d}", .{ host, port });

    while (running.load(.acquire)) {
        const session = ssh.ssh_new() orelse continue;

        if (ssh.ssh_bind_accept(sshbind, session) == ssh.SSH_ERROR) {
            log.err("error accepting connection: {s}", .{ssh.ssh_get_error(sshbind)});
            ssh.ssh_free(session);
            continue;
        }
        log.debug("[CONNECT] client connection accepted", .{});

        const thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, handleClient, .{ allocator, &server, session }) catch |err| {
            log.err("failed to spawn thread: {}", .{err});
            ssh.ssh_disconnect(session);
            ssh.ssh_free(session);
            continue;
        };

        thread.detach();
    }
    log.info("[STOP] server closed successfully", .{});
}

fn handleClient(allocator: mem.Allocator, server: *server_handler.Server, session: ssh.ssh_session) !void {
    defer {
        ssh.ssh_disconnect(session);
        ssh.ssh_free(session);
    }

    if (ssh.ssh_handle_key_exchange(session) != ssh.SSH_OK) {
        log.warn("[REJECT] key exchange failed: {s}", .{ssh.ssh_get_error(session)});
        return error.KeyExchangeFailed;
    }

    _ = ssh.ssh_set_auth_methods(session, ssh.SSH_AUTH_METHOD_PUBLICKEY);

    var u_buf: [32]u8 = undefined;
    var username: []const u8 = "unknown";
    var fingerprint: [32]u8 = undefined;
    var auth_success = false;
    while (!auth_success) {
        const msg = ssh.ssh_message_get(session) orelse break;
        defer ssh.ssh_message_free(msg);

        if (ssh.ssh_message_type(msg) == ssh.SSH_REQUEST_AUTH) {
            if (ssh.ssh_message_auth_user(msg)) |c_username| {
                const u = std.mem.span(c_username);
                const u_len = @min(u.len, u_buf.len);
                @memcpy(u_buf[0..u_len], u[0..u_len]);
                username = u_buf[0..u_len];
            }

            const auth_subtype = ssh.ssh_message_subtype(msg);

            if (auth_subtype == ssh.SSH_AUTH_METHOD_NONE) {
                _ = ssh.ssh_message_auth_set_methods(msg, ssh.SSH_AUTH_METHOD_PUBLICKEY);
                _ = ssh.ssh_message_reply_default(msg);
                continue;
            }

            if (auth_subtype == ssh.SSH_AUTH_METHOD_PUBLICKEY) {
                const pubkey = ssh.ssh_message_auth_pubkey(msg);

                if (pubkey != null) {
                    var hash_ptr: [*c]u8 = undefined;
                    var hash_len: usize = 0;

                    if (ssh.ssh_get_publickey_hash(pubkey, ssh.SSH_PUBLICKEY_HASH_SHA256, &hash_ptr, &hash_len) == ssh.SSH_OK) {
                        defer ssh.ssh_clean_pubkey_hash(&hash_ptr);
                        @memcpy(&fingerprint, hash_ptr[0..32]);
                    }

                    if (!server.isAuthenticClient(fingerprint)) {
                        log.warn("[REJECT] client is not whitelisted: fingerprint=\"{x}\"", .{ username, 0, fingerprint });
                        return error.ClientRejected;
                    }

                    const state = ssh.ssh_message_auth_publickey_state(msg);
                    if (state == ssh.SSH_PUBLICKEY_STATE_NONE) {
                        _ = ssh.ssh_message_auth_reply_pk_ok_simple(msg);
                    } else if (state == ssh.SSH_PUBLICKEY_STATE_VALID) {
                        _ = ssh.ssh_message_auth_reply_success(msg, 0);
                        auth_success = true;
                    } else {
                        _ = ssh.ssh_message_reply_default(msg);
                    }
                    continue;
                }
            }

            _ = ssh.ssh_message_auth_reply_success(msg, 0);
            auth_success = true;
            continue;
        }
        _ = ssh.ssh_message_reply_default(msg);
    }
    if (!auth_success) return error.AuthFailed;

    var channel_msg: ssh.ssh_message = undefined;
    while (true) {
        channel_msg = ssh.ssh_message_get(session) orelse return error.NoChannel;
        if (ssh.ssh_message_type(channel_msg) == ssh.SSH_REQUEST_CHANNEL_OPEN and
            ssh.ssh_message_subtype(channel_msg) == ssh.SSH_CHANNEL_SESSION)
        {
            break;
        }
        ssh.ssh_message_free(channel_msg);
    }

    const channel = ssh.ssh_message_channel_request_open_reply_accept(channel_msg) orelse return error.ChannelFailed;
    ssh.ssh_message_free(channel_msg);
    defer {
        _ = ssh.ssh_channel_send_eof(channel);
        _ = ssh.ssh_channel_close(channel);
        ssh.ssh_channel_free(channel);
    }

    while (true) {
        const req_msg = ssh.ssh_message_get(session) orelse break;
        defer ssh.ssh_message_free(req_msg);

        if (ssh.ssh_message_type(req_msg) == ssh.SSH_REQUEST_CHANNEL) {
            const subtype = ssh.ssh_message_subtype(req_msg);
            if (subtype == ssh.SSH_CHANNEL_REQUEST_PTY or subtype == ssh.SSH_CHANNEL_REQUEST_SHELL) {
                _ = ssh.ssh_message_channel_request_reply_success(req_msg);
                if (subtype == ssh.SSH_CHANNEL_REQUEST_SHELL) break;
            } else {
                _ = ssh.ssh_message_reply_default(req_msg);
            }
        } else {
            _ = ssh.ssh_message_reply_default(req_msg);
        }
    }

    const client_id = 0;

    try server.addClient(.{
        .id = client_id, // get this from database
        .channel = channel,
    });
    defer server.removeClient(client_id) catch {};

    log.info("[ACCEPT] id={d} username=\"{s}\" fingerprint=\"{x}\"", .{ client_id, username, fingerprint });

    var input_buf: [1024]u8 = undefined;

    while (true) {
        const bytes_read = ssh.channel_read(channel, &input_buf, @intCast(input_buf.len), 0);
        if (bytes_read <= 0) break;

        const input = input_buf[0..@intCast(bytes_read)];

        if (std.mem.eql(u8, input, "q") or std.mem.eql(u8, input, "q\r") or std.mem.eql(u8, input, "q\r\n")) {
            try ssh_handler.channelWriteAll(channel, "disconnecting...\r\n");
            break;
        }

        if (mem.eql(u8, input, "w")) {
            _ = try commands.runCommand(allocator, client_id, server, "/teste");
        }

        if (mem.eql(u8, input, "r")) {
            _ = try commands.runCommand(allocator, client_id, server, "/test");
        }

        try ssh_handler.channelPrint(allocator, channel, "read: {s}\r\n", .{input});
    }

    log.info("[DISCONNECT] id={d} username=\"{s}\" fingerprint=\"{x}\"", .{ client_id, username, fingerprint });
}
