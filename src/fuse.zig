const std = @import("std");

pub const fuse = @cImport({
    @cDefine("FUSE_USE_VERSION", "31");
    @cInclude("fuse_wrapper.h");
});
const ENOENT = 2;

const app = @import("app.zig");
const git = @import("git.zig");
const cgit = git.cgit;

const ally = app.ally;

const FuseFileInfo = @import("fusefileinfo.zig").FuseFileInfo;

pub fn readdir(cpath: [*c]const u8, buf: ?*anyopaque, filler: fuse.fuse_fill_dir_t, offset: fuse.off_t, fi: ?*fuse.fuse_file_info, flags: fuse.fuse_readdir_flags) callconv(.C) c_int {
    std.log.debug("readdir: {s}", .{cpath});
    const path = std.mem.span(cpath);

    const path_tree = git.get_dir(path) catch unreachable;

    const N = cgit.git_tree_entrycount(path_tree);
    for (0..N) |n| {
        var state = std.mem.zeroes(fuse.struct_stat);

        const entry = cgit.git_tree_entry_byindex(path_tree, n);
        const name = cgit.git_tree_entry_name(entry);
        // const fmode: c_uint = @intCast(cgit.git_tree_entry_filemode(entry));
        const ftype = cgit.git_tree_entry_type(entry);

        switch (ftype) {
            cgit.GIT_OBJ_TREE => {
                state.st_mode = fuse.S_IFDIR | 0o0755; // | fmode;
                state.st_nlink = 2;
                _ = filler.?(buf, name, &state, 0, 0);
            },
            cgit.GIT_OBJ_BLOB => {
                state.st_mode = fuse.S_IFREG | 0o0644; // | fmode;
                state.st_nlink = 1;
                _ = filler.?(buf, name, &state, 0, 0);
            },
            else => {
                @panic("Help");
            },
        }
    }

    _ = offset;
    _ = fi;
    _ = flags;
    return 0;
}

pub fn getattr(c_path: [*c]const u8, stbuf: ?*fuse.struct_stat, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    var packed_fi: ?*FuseFileInfo = null;
    if (fi) |fi_ptr| {
        packed_fi = @alignCast(@ptrCast(fi_ptr));
    }

    std.log.debug("getattr: {s}", .{c_path});

    const path = std.mem.span(c_path);
    var stat = std.mem.zeroes(fuse.struct_stat);
    defer stbuf.?.* = stat;
    stat.st_mtim = .{
        .tv_sec = app.get_modtime(path) catch unreachable,
        .tv_nsec = 0,
    };

    // First deal with root case
    const ROOT = "/";
    if (std.mem.eql(u8, ROOT, path)) {
        stat.st_mode = fuse.S_IFDIR | 0o0755;
        return 0;
    }

    // Look at existing buffers
    if (app.file_buffers.get(path)) |buffer| {
        stat.st_mode = fuse.S_IFREG | 0o0644;
        stat.st_nlink = 1;
        stat.st_size = @intCast(buffer.size());
        return 0;
    }

    const object = git.get_object(path) catch {
        std.log.debug("getattr no object: {s}", .{path});
        return -ENOENT;
    };
    const o_type = cgit.git_object_type(object);

    if (o_type == cgit.GIT_OBJECT_BLOB) {
        const blob: *cgit.git_blob = @ptrCast(object);
        const size = cgit.git_blob_rawsize(blob);

        stat.st_mode = fuse.S_IFREG | 0o0644;
        stat.st_nlink = 1;
        stat.st_size = @intCast(size);
    } else if (o_type == cgit.GIT_OBJECT_TREE) {
        stat.st_mode = fuse.S_IFDIR | 0o0755;
        stat.st_nlink = 2;
    } else {
        return -ENOENT;
    }

    return 0;
}

pub fn open(c_path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    const packed_fi: *FuseFileInfo = @alignCast(@ptrCast(fi.?));
    packed_fi.fh = 123; //TODO: use fh for buffers

    const fi_flags = packed_fi.flags;
    // const direct_ptr: *c_int = @ptrCast(@alignCast(fi.?));
    // const fi_flags = direct_ptr.*;
    const trunc = (fi_flags & fuse.O_TRUNC) > 0;
    const access = fi_flags & fuse.O_ACCMODE;
    // const append = access == fuse.O_APPEND;
    // const write_only = access == fuse.O_WRONLY;
    const read_only = access == fuse.O_RDONLY;
    // const read_write = access == fuse.O_RDWR;

    //Access codes: O_RDONLY = 32768. O_WRONLY=32769. O_RDWR = 32770. O_APPEND = 33792

    std.log.debug("Opening {s}", .{c_path});

    const path = std.mem.span(c_path);

    _ = app.get_or_put_buffer(path, read_only, trunc) catch {
        std.log.warn("Failed to open buffer '{s}'", .{path});
        return -ENOENT;
    };

    return 0;
}

pub fn release(c_path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    std.log.debug("Release {s}", .{c_path});
    const path = std.mem.span(c_path);

    app.persist_file_buffer(path) catch {
        std.log.warn("Buffer not found during release", .{});
        return 0;
    };

    if (app.file_buffers.get(path)) |buffer| {
        if (buffer.last_reader()) {
            buffer.deinit(ally);
            _ = app.file_buffers.remove(path);
        } else {
            buffer.n_readers -= 1;
        }
    }
    _ = fi;
    return 0;
}

pub fn create(c_path: [*c]const u8, mode: fuse.mode_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;
    _ = mode;

    std.log.debug("Create {s}", .{c_path});

    const path = std.mem.span(c_path);
    const read_only = false;
    _ = app.create_buffer(path, read_only) catch {
        return -1;
    };
    return 0;
}

pub fn flush(c_path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;
    std.log.debug("Flush {s}", .{c_path});
    return 0;
}

pub fn fsync(c_path: [*c]const u8, sync: c_int, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = sync;
    _ = fi;

    const path = std.mem.span(c_path);
    std.log.debug("Fsync {s}", .{c_path});
    app.persist_file_buffer(path) catch unreachable;
    return 0;
}

pub fn truncate(c_path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;
    std.log.debug("Truncate {s}", .{c_path});
}

pub fn write(c_path: [*c]const u8, buf: [*c]const u8, buf_size: usize, offset_c: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    const offset: usize = @intCast(offset_c);
    const packed_fi: *FuseFileInfo = @alignCast(@ptrCast(fi.?));

    std.log.debug("Write {s} {} {} fh:{}", .{ c_path, buf_size, offset, packed_fi.fh });
    const path = std.mem.span(c_path);
    if (app.file_buffers.get(path)) |file_buf| {
        if (file_buf.read_only) {
            std.log.warn("Writing to read only buffer: {s}", .{c_path});
            return -1;
        }
        file_buf.write(buf[0..buf_size], offset) catch unreachable;
    }

    _ = app.update_modtime(path) catch unreachable;
    return @intCast(buf_size);
}

pub fn read(c_path: [*c]const u8, buf: [*c]u8, buf_size: usize, offset_c: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;

    std.log.debug("Reading {s}", .{c_path});

    const path = std.mem.span(c_path);
    const offset: usize = @intCast(offset_c);

    if (app.file_buffers.get(path)) |buffer| {
        const contents = buffer.contents();
        var copy_size = buf_size;
        if (offset + copy_size >= contents.len) {
            copy_size = contents.len - offset;
        }
        @memcpy(buf[0..copy_size], contents[offset .. offset + copy_size]);

        return @intCast(copy_size);
    }

    std.log.debug("path not found '{s}'", .{path});
    return -ENOENT;
}

pub fn unlink(c_path: [*c]const u8) callconv(.C) c_int {
    const path = std.mem.span(c_path);
    app.remove_file(path) catch {
        std.log.warn("Remove failed", .{});
        return -1;
    };
    return 0;
}

pub fn rename(c_src_path: [*c]const u8, c_dest_path: [*c]const u8, flag: c_uint) callconv(.C) c_int {
    _ = flag; // todo, handle RENAME_EXCHANGE and RENAME_NOREPLACE

    const src_path = std.mem.span(c_src_path);
    const dest_path = std.mem.span(c_dest_path);

    // load existing buffer
    const read_only = true;
    const trunc = false;
    const src_buffer = app.get_or_put_buffer(src_path, read_only, trunc) catch {
        std.log.warn("Failed to get buffer {s}", .{src_path});
        return -1;
    };
    const content = src_buffer.contents();

    // create new buffer
    _ = app.create_buffer_from_content(dest_path, content) catch {
        std.log.warn("Failed to create {s}", .{dest_path});

        return -1;
    };

    // now remove old buffer
    app.remove_file(src_path) catch {
        std.log.warn("Remove failed", .{});
        return -1;
    };
    src_buffer.deinit(ally);
    _ = app.file_buffers.remove(src_path);
    return 0;
}
