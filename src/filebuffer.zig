const std = @import("std");

const Self = @This();

buffer: std.ArrayList(u8),
read_only: bool,
n_readers: usize = 1,

pub fn init(allocator: std.mem.Allocator, read_only: bool) !*Self {
    const file_buffer = try allocator.create(Self);
    file_buffer.* = .{
        .buffer = std.ArrayList(u8).init(allocator),
        .read_only = read_only,
    };
    return file_buffer;
}

/// Initialize filebuffer based from an existing buffer. Makes copy of buffer, does not take ownership.
pub fn init_buffer(allocator: std.mem.Allocator, buffer: []const u8, read_only: bool) !*Self {
    const file_buffer = try allocator.create(Self);

    const buffer_copy = try allocator.dupe(u8, buffer);
    file_buffer.* = .{
        .buffer = std.ArrayList(u8).fromOwnedSlice(allocator, buffer_copy),
        .read_only = read_only,
    };
    return file_buffer;
}

pub fn contents(self: *Self) []u8 {
    return self.buffer.items;
}

pub fn size(self: *Self) usize {
    return self.buffer.items.len;
}

pub fn last_reader(self: *Self) bool {
    return self.n_readers == 1;
}

pub fn write(self: *Self, buffer: []const u8, offset: usize) !void {
    const total = buffer.len + offset;
    if (total > self.buffer.items.len) {
        try self.buffer.ensureTotalCapacityPrecise(total);
        self.buffer.expandToCapacity();
    }

    @memcpy(self.contents()[offset .. offset + buffer.len], buffer);
}

pub fn truncate(self: *Self) void {
    self.buffer.clearAndFree();
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.buffer.deinit();
    allocator.destroy(self);
}
