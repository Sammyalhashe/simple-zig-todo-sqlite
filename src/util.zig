const std = @import("std");

pub fn generateUuidV4(io: std.Io) [36]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    const hex = "0123456789abcdef";
    var uuid: [36]u8 = undefined;
    var i: usize = 0;
    for (bytes, 0..) |b, idx| {
        if (idx == 4 or idx == 6 or idx == 8 or idx == 10) {
            uuid[i] = '-';
            i += 1;
        }
        uuid[i] = hex[b >> 4];
        uuid[i + 1] = hex[b & 0x0f];
        i += 2;
    }
    return uuid;
}
