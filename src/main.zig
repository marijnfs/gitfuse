const std = @import("std");
const fuse = @cImport({
    @cDefine("FUSE_USE_VERSION", "31");
    @cInclude("fuse3/fuse.h");
});
const git = @cImport({
    @cInclude("git2.h");
});

const zli = @import("zli");

pub fn tree_callback(root: [*c]const u8, entry: ?*const git.git_tree_entry, payload: ?*anyopaque) callconv(.C) c_int {
    std.debug.print("{s}{s}\n", .{ root, git.git_tree_entry_name(entry) });

    // _ = entry;
    _ = payload;
    return 0;
}

var repo: *git.git_repository = undefined;
const ally = std.heap.c_allocator;

var file_buffers: std.StringHashMap(std.ArrayList(u8)) = undefined;
var fd_counter: u64 = 0;

fn git_try(err_code: c_int) !void {
    if (err_code < 0) {
        return error.git_error;
    }
}

pub fn get_dir(path: []const u8) !*git.git_tree {
    const branch = "refs/heads/master";

    var treeish: ?*git.git_object = null;
    try git_try(git.git_revparse_single(&treeish, repo, branch));
    defer git.git_object_free(treeish);

    var commit: ?*git.git_commit = null;
    try git_try(git.git_commit_lookup(&commit, repo, git.git_object_id(treeish)));

    var tree: ?*git.git_tree = null;
    try git_try(git.git_commit_tree(&tree, commit));

    var current_tree = tree;
    var it = std.mem.tokenize(u8, path, "/");

    while (it.next()) |subpath| {
        const subpath_z = try ally.dupeZ(u8, subpath);
        defer ally.free(subpath_z);

        const entry = git.git_tree_entry_byname(current_tree, subpath_z);
        if (entry == null)
            return error.NotFound;
        std.debug.print("found: {any}\n", .{entry});

        const entry_type = git.git_tree_entry_type(entry);
        if (entry_type != git.GIT_OBJ_TREE) {
            return error.ExpectedTree;
        }

        const oid = git.git_tree_entry_id(entry);
        try git_try(git.git_tree_lookup(&current_tree, repo, oid));
    }

    return current_tree.?;
}

pub fn get_object(path: []const u8) !*git.git_object {
    const branch = "refs/heads/master";

    var treeish: ?*git.git_object = null;
    try git_try(git.git_revparse_single(&treeish, repo, branch));
    defer git.git_object_free(treeish);

    var commit: ?*git.git_commit = null;
    try git_try(git.git_commit_lookup(&commit, repo, git.git_object_id(treeish)));

    var tree: ?*git.git_tree = null;
    try git_try(git.git_commit_tree(&tree, commit));

    var current_tree = tree;
    var it = std.mem.tokenize(u8, path, "/");

    while (it.next()) |subpath| {
        const subpath_z = try ally.dupeZ(u8, subpath);
        defer ally.free(subpath_z);

        const entry = git.git_tree_entry_byname(current_tree, subpath_z);
        if (entry == null)
            return error.NotFound;
        std.debug.print("found: {any}\n", .{entry});

        const entry_type = git.git_tree_entry_type(entry);
        const oid = git.git_tree_entry_id(entry);

        const last_comparison = it.peek() == null;
        if (last_comparison) {
            var obj_c: ?*git.git_object = null;
            try git_try(git.git_object_lookup(&obj_c, repo, oid, git.GIT_OBJECT_ANY));
            if (obj_c == null) {
                return error.FailedLookup;
            }
            return obj_c.?;
        }
        if (entry_type != git.GIT_OBJ_TREE) {
            return error.ExpectedTree;
        }

        try git_try(git.git_tree_lookup(&current_tree, repo, oid));
    }

    return error.NotFound;
}

pub fn init() !void {
    _ = git.git_libgit2_init();

    file_buffers = std.StringHashMap(std.ArrayList(u8)).init(ally);
    {
        const path = ".";
        var repo_tmp: ?*git.git_repository = null;
        const err = git.git_repository_open(&repo_tmp, path);
        if (err < 0) {
            return error.Failed;
        }
        repo = repo_tmp.?;
    }
}

pub fn deinit() void {
    _ = git.git_libgit2_shutdown();

    git.git_repository_free(repo);
}

pub fn list_git_dir(tree: *git.git_tree) void {
    const N = git.git_tree_entrycount(tree);
    for (0..N) |n| {
        const entry = git.git_tree_entry_byindex(tree, n);
        const name = git.git_tree_entry_name(entry);
        std.log.info("entry: {s}", .{name});
    }
}

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    var args = std.ArrayList([:0]u8).init(ally);
    {
        var iterator = try std.process.argsWithAllocator(ally);
        while (iterator.next()) |arg| {
            std.log.info("adding {s}", .{arg});
            try args.append(try ally.dupeZ(u8, arg));
        }
    }

    try init();
    defer deinit();

    // const path = args.items[1];
    // const path_tree = try get_dir(path);
    // list_git_dir(path_tree);
    // _ = git.git_tree_walk(tree, git.GIT_TREEWALK_PRE, tree_callback, null);

    const operations: fuse.fuse_operations = .{
        .getattr = &getattr,
        .readdir = &readdir,
        .open = &open,
        .read = &read,
        .release = &release,
    };

    var c_strings = try ally.alloc([*c]u8, args.items.len + 1);
    for (0..args.items.len) |i| {
        c_strings[i] = args.items[i];
    }
    c_strings[args.items.len] = null;
    _ = fuse.fuse_main_fn(@intCast(args.items.len), @ptrCast(c_strings), &operations, null);

    while (true) {
        std.time.sleep(1000);
    }
    std.log.info("Done", .{});
    // _ = fuse.fuse_main_real(@intCast(args.items.len), @ptrCast(c_strings), &operations, @sizeOf(@TypeOf(operations)), null);
}

pub fn readdir(cpath: [*c]const u8, buf: ?*anyopaque, filler: fuse.fuse_fill_dir_t, offset: fuse.off_t, fi: ?*fuse.fuse_file_info, flags: fuse.fuse_readdir_flags) callconv(.C) c_int {
    std.log.info("readdir: {s}", .{cpath});
    const path = std.mem.span(cpath);

    //if (!std.mem.eql(u8, path, "/")) {
    //    const ENOENT = 2;
    //    return -ENOENT;
    //}

    const path_tree = get_dir(path) catch unreachable;

    const N = git.git_tree_entrycount(path_tree);
    for (0..N) |n| {
        var state = std.mem.zeroes(fuse.struct_stat);

        const entry = git.git_tree_entry_byindex(path_tree, n);
        const name = git.git_tree_entry_name(entry);
        // const fmode: c_uint = @intCast(git.git_tree_entry_filemode(entry));
        const ftype = git.git_tree_entry_type(entry);

        switch (ftype) {
            git.GIT_OBJ_TREE => {
                state.st_mode = fuse.S_IFDIR | 0o0755; // | fmode;
                state.st_nlink = 2;
                _ = filler.?(buf, name, &state, 0, 0);
            },
            git.GIT_OBJ_BLOB => {
                state.st_mode = fuse.S_IFREG | 0o0444; // | fmode;
                state.st_nlink = 1;
                _ = filler.?(buf, name, &state, 0, 0);
            },
            else => {
                @panic("Help");
            },
        }
        std.log.info("entry: {s}", .{name});
    }

    _ = offset;
    _ = fi;
    _ = flags;
    return 0;
}

pub fn getattr(c_path: [*c]const u8, stbuf: ?*fuse.struct_stat, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;
    const path = std.mem.span(c_path);
    var stat = std.mem.zeroes(fuse.struct_stat);

    std.log.info("getattr: {s}", .{path});

    // First deal with root case
    const ROOT = "/";
    if (std.mem.eql(u8, ROOT, path)) {
        stat.st_mode = fuse.S_IFDIR | 0o0755;
        stat.st_nlink = 2;
        stbuf.?.* = stat;
        return 0;
    }

    const object = get_object(path) catch {
        std.log.debug("getattr no object: {s}", .{path});
        const ENOENT = 2;
        return -ENOENT;
    };
    const o_type = git.git_object_type(object);

    if (o_type == git.GIT_OBJECT_BLOB) {
        const blob: *git.git_blob = @ptrCast(object);
        const size = git.git_blob_rawsize(blob);

        stat.st_mode = fuse.S_IFREG | 0o0444;
        stat.st_nlink = 1;
        stat.st_size = @intCast(size);
    } else if (o_type == git.GIT_OBJECT_TREE) {
        stat.st_mode = fuse.S_IFDIR | 0o0755;
        stat.st_nlink = 2;
    } else {
        const ENOENT = 2;
        return -ENOENT;
    }

    stbuf.?.* = stat;
    return 0;
}

pub fn open(c_path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;
    // bitfields don't work for zig 0.13, so we use the path for now

    std.log.debug("Opening {s}", .{c_path});

    const path = std.mem.span(c_path);

    const object = get_object(path) catch {
        std.log.debug("read: no object: {s}", .{path});
        const ENOENT = 2;
        return -ENOENT;
    };

    const o_type = git.git_object_type(object);
    if (o_type != git.GIT_OBJECT_BLOB) {
        std.log.debug("object not blob: {s}", .{path});
        const ENOENT = 2;
        return -ENOENT;
    }

    const blob: *git.git_blob = @ptrCast(object);
    defer git.git_blob_free(blob);

    const content_c = git.git_blob_rawcontent(blob);
    if (content_c == null) {
        std.log.debug("blob has no content: {s}", .{path});
        const ENOENT = 2;
        return -ENOENT;
    }
    const content_ptr: [*c]const u8 = @ptrCast(content_c.?);
    const size = git.git_blob_rawsize(blob);

    const content = content_ptr[0..size];
    const buffer_copy = ally.dupe(u8, content) catch unreachable;
    std.log.debug("Putting path {s}, size: {}",.{path, buffer_copy.len});
    file_buffers.put(path, std.ArrayList(u8).fromOwnedSlice(ally, buffer_copy)) catch unreachable;
    std.log.debug("Done",.{});

    return 0;
}

pub fn release(c_path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    std.log.debug("Release {s}", .{c_path});
    const path = std.mem.span(c_path);
    if (file_buffers.get(path)) |list| {
        list.deinit();
        _ = file_buffers.remove(path);
    }
    _ = fi;
    return 0;
}

pub fn read(c_path: [*c]const u8, buf: [*c]u8, buf_size: usize, offset_c: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;

    std.log.debug("Reading {s}", .{c_path});

    const path = std.mem.span(c_path);
    const offset: usize = @intCast(offset_c);

    if (file_buffers.get(path)) |list| {
        const buffer = list.items;
        var copy_size = buf_size;
        if (offset + copy_size >= buffer.len) {
            copy_size = buffer.len - offset;
        }
        @memcpy(buf[0..copy_size], buffer[offset .. offset + copy_size]);
        std.log.debug("sizes: copy{} off{} total{}", .{ copy_size, offset, buffer.len });

        return @intCast(copy_size);
    }
    std.log.debug("path not found {s}", .{path});
    const ENOENT = 2;
    return -ENOENT;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
