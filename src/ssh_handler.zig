const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const ssh = @import("ssh");

pub const SshError = error{WriteFailed};

pub fn channelWrite(channel: ssh.ssh_channel, bytes: []const u8) SshError!usize {
    if (bytes.len == 0) return 0;
    const len: c_uint = @intCast(@min(bytes.len, std.math.maxInt(c_uint)));
    const length = ssh.ssh_channel_write(channel, bytes.ptr, len);
    if (length <= 0) return error.WriteFailed;
    return @intCast(length);
}

pub fn channelWriteErr(channel: ssh.ssh_channel, bytes: []const u8) SshError!usize {
    if (bytes.len == 0) return 0;
    const len: c_uint = @intCast(@min(bytes.len, std.math.maxInt(c_uint)));
    const length = ssh.ssh_channel_write_stderr(channel, bytes.ptr, len);
    if (length <= 0) return error.WriteFailed;
    return @intCast(length);
}

pub fn channelWriteAll(channel: ssh.ssh_channel, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += try channelWrite(channel, bytes[written..]);
    }
}

pub fn channelWriteAllErr(channel: ssh.ssh_channel, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += try channelWriteErr(channel, bytes[written..]);
    }
}

pub fn channelWriteByte(channel: ssh.ssh_channel, byte: u8) SshError!void {
    const length = ssh.ssh_channel_write(channel, &byte, 1);
    if (length <= 0) return error.WriteFailed;
}

pub fn channelWriteByteErr(channel: ssh.ssh_channel, byte: u8) SshError!void {
    const length = ssh.ssh_channel_write_stderr(channel, &byte, 1);
    if (length <= 0) return error.WriteFailed;
}

pub fn channelPrint(allocator: mem.Allocator, channel: ssh.ssh_channel, comptime format: []const u8, args: anytype) !void {
    const formatted = try fmt.allocPrint(allocator, format, args);
    defer allocator.free(formatted);
    _ = try channelWriteAll(channel, formatted);
}

pub fn channelPrintErr(allocator: mem.Allocator, channel: ssh.ssh_channel, comptime format: []const u8, args: anytype) !void {
    const formatted = try fmt.allocPrint(allocator, format, args);
    defer allocator.free(formatted);
    _ = try channelWriteAllErr(channel, formatted);
}

pub fn channelPrintBuf(buf: []u8, channel: ssh.ssh_channel, comptime format: []const u8, args: anytype) !void {
    const formatted = try fmt.bufPrint(buf, format, args);
    _ = try channelWriteAll(channel, formatted);
}

pub fn channelPrintBufErr(buf: []u8, channel: ssh.ssh_channel, comptime format: []const u8, args: anytype) !void {
    const formatted = try fmt.bufPrint(buf, format, args);
    _ = try channelWriteAllErr(channel, formatted);
}
