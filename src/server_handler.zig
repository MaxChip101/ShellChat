const std = @import("std");

pub const Server = struct {
    whitelist_enabled: bool,
    title: []const u8,
    channels: []Channel,
};

pub const Channel = struct {
    name: []const u8,
    type: u32,
};

pub const Client = struct {
    name: []const u8,
    fingerprint: []const u8,
};

// modular chat server
// use ssh to communicate
// lua plugins can create custom channels
// for white list only, client's with fingerprints that are already in the system are accepted
