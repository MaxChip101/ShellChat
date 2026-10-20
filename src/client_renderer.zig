const ssh = @import("ssh");

const ssh_handler = @import("ssh_handler.zig");

pub const CursorType = enum(u8) {
    Default = 0,
    BlinkingBlock = 1,
    SteadyBlock = 2,
    BlinkingUnderline = 3,
    SteadyUnderline = 4,
    BlinkingBar = 5,
    SteadyBar = 6,
};

pub fn displayCommandLine(channel: ssh.ssh_channel, rows: u16, command_line: []const u8) !void {
    try saveCursorPos(channel);
    try moveCursor(channel, rows, 1);
    try clearLine(channel);
    try ssh_handler.channelWriteAll(channel, command_line);
    try restoreCursorPos(channel);
}

pub fn displayAlternateBuffer(channel: ssh.ssh_channel) !void {
    try ssh_handler.channelWriteAll(channel, "\x1B[?1049h");
}

pub fn displayOriginalBuffer(channel: ssh.ssh_channel) !void {
    try ssh_handler.channelWriteAll(channel, "\x1B[?1049l");
}

pub fn clearBuffer(channel: ssh.ssh_channel) !void {
    try ssh_handler.channelWriteAll(channel, "\x1B[3J");
}

pub fn moveCursor(channel: ssh.ssh_channel, row: u16, col: u16) !void {
    var buf: [256]u8 = undefined;
    try ssh_handler.channelPrintBuf(&buf, channel, "\x1B[{d};{d}H", .{ row, col });
}

pub fn clearLine(channel: ssh.ssh_channel) !void {
    try ssh_handler.channelWriteAll(channel, "\x1B[K");
}

pub fn saveCursorPos(channel: ssh.ssh_channel) !void {
    try ssh_handler.channelWriteAll(channel, "\x1B[s");
}

pub fn restoreCursorPos(channel: ssh.ssh_channel) !void {
    try ssh_handler.channelWriteAll(channel, "\x1B[u");
}

pub fn setCursor(channel: ssh.ssh_channel, cursor: CursorType) !void {
    var buf: [256]u8 = undefined;
    try ssh_handler.channelPrintBuf(&buf, channel, "\x1B[{d} q", .{cursor});
}
