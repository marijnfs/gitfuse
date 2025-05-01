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

var file_buffers: std.StringHashMap(*std.ArrayList(u8)) = undefined;
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

const repo_path = "/home/marijnfs/dev/gitfuse.git";

pub fn init() !void {
    _ = git.git_libgit2_init();

    file_buffers = std.StringHashMap(*std.ArrayList(u8)).init(ally);
    {
        var repo_tmp: ?*git.git_repository = null;
        const err = git.git_repository_open(&repo_tmp, repo_path);
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

pub fn create_commit(tree: *git.git_tree, parent: *git.git_commit, reference: []const u8) !git.git_oid {
    var oid = std.mem.zeroes(git.git_oid);

    const author: git.git_signature = .{
        .name = @constCast("gitfuse"),
        .email = @constCast(""),
        .when = .{
            .time = std.time.timestamp(),
            .offset = 0,
            .sign = 0,
        },
    };

    const parents: [1]*git.git_commit = .{parent};

    const reference_c = try ally.dupeZ(u8, reference);
    try git_try(git.git_commit_create(&oid, repo, reference_c, &author, &author, "UTF-8", "GitFuse", tree, parents.len, @constCast(@ptrCast(&parents))));

    return oid;
}

const Reference = struct {
    commit: *git.git_commit,
    tree: *git.git_tree,
};

pub fn get_reference() !Reference {
    var reference_treeish: ?*git.git_object = null;

    const reference_branch = "refs/heads/master";
    try git_try(git.git_revparse_single(&reference_treeish, repo, reference_branch));

    var ref_commit: ?*git.git_commit = null;
    try git_try(git.git_commit_lookup(&ref_commit, repo, git.git_object_id(reference_treeish)));

    var ref_tree: ?*git.git_tree = null;
    try git_try(git.git_commit_tree(&ref_tree, ref_commit));

    return .{
        .commit = ref_commit.?,
        .tree = ref_tree.?,
    };
}

pub fn get_active_tree() !*git.git_tree {
    const target_branch = "refs/heads/gitfuse";

    var treeish: ?*git.git_object = null;
    git_try(git.git_revparse_single(&treeish, repo, target_branch)) catch {
        std.log.debug("Didn't find target branch, creating it", .{});

        const ref = try get_reference();

        _ = try create_commit(ref.tree, ref.commit, target_branch);

        // Finally the treeish is gonna point to the ref tree
        return ref.tree;
    };


    var ref_commit: ?*git.git_commit = null;
    try git_try(git.git_commit_lookup(&ref_commit, repo, git.git_object_id(treeish)));

    var ref_tree: ?*git.git_tree = null;
    try git_try(git.git_commit_tree(&ref_tree, ref_commit));

    return ref_tree.?;
}

// Make the file buffer of 'path' persistent.
// This means updating the target branch with the contents of this buffer.
// Does not close the buffer.
// If buffer does not exist, that is an error
pub fn persist_file_buffer(path: []const u8) !void {
    if (file_buffers.get(path)) |buffer| {
        // First we create the blob and get the oid
        var buffer_iod = std.mem.zeroes(git.git_oid);
        try git_try(git.git_blob_create_from_buffer(&buffer_iod, repo, @ptrCast(&buffer.items), buffer.items.len));

        // Grab our active target tree and setup the builder
        const active_tree = try get_active_tree();
        const reference = try get_reference();

        // Find the sequence of trees to the path
        var trees = std.ArrayList(*git.git_tree).init(ally);
        var paths = std.ArrayList([]const u8).init(ally);
        var it = std.mem.tokenize(u8, path, "/");

        var current_tree: ?*git.git_tree = active_tree;

        while (it.next()) |subpath| {
            try trees.append(current_tree.?);
            try paths.append(subpath);

            const subpath_z = try ally.dupeZ(u8, subpath);
            defer ally.free(subpath_z);

            const entry = git.git_tree_entry_byname(current_tree, subpath_z);
            if (entry == null)
                return error.NotFound;
            std.debug.print("found: {any}\n", .{entry});

            const entry_type = git.git_tree_entry_type(entry);
            const sub_oid = git.git_tree_entry_id(entry);

            const last_comparison = it.peek() == null;
            if (last_comparison) {
                var obj_c: ?*git.git_object = null;
                try git_try(git.git_object_lookup(&obj_c, repo, sub_oid, git.GIT_OBJECT_ANY));
                if (obj_c == null) {
                    return error.FailedLookup;
                }

                // We are on the last level and found the file
                break;
            }
            if (entry_type != git.GIT_OBJ_TREE) {
                return error.ExpectedTree;
            }

            try git_try(git.git_tree_lookup(&current_tree, repo, sub_oid));
        }

        // Now recursively build up the updated tree
        var i: usize = trees.items.len;
        var current_oid = buffer_iod;
        while (i > 0) {
            i -= 1;
            const tree = trees.items[i];
            const subpath = paths.items[i];
            const subpath_c = try ally.dupeZ(u8, subpath);
            var builder: ?*git.git_treebuilder = null;
            try git_try(git.git_treebuilder_new(&builder, repo, tree));
            defer git.git_treebuilder_free(builder);

            const mode: git.git_filemode_t = 0o0222;
            try git_try(git.git_treebuilder_insert(null, builder, subpath_c, &current_oid, mode));
            var tree_oid: git.git_oid = undefined;
            try git_try(git.git_treebuilder_write(&tree_oid, builder));

            current_oid = tree_oid;
        }

        // Now the new tree id is current_oid
        // Set up the commit
        const target_branch = "refs/heads/gitfuse";

        const new_tree_oid = current_oid;

        var new_tree: ?*git.git_tree = null;
        try git_try(git.git_tree_lookup(&new_tree, repo, &new_tree_oid));
        _ = try create_commit(
            new_tree.?,
            reference.commit,

            target_branch,
        );
    } else {
        return error.BufferNotFound;
    }
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
        .create = &create,
        .flush = &flush,
        .fsync = &fsync,
        .write = &write,
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
                state.st_mode = fuse.S_IFREG | 0o0222; // | fmode;
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

    // Look at existing buffers
    if (file_buffers.get(path)) |buffer| {
        stat.st_mode = fuse.S_IFREG | 0o0222;
        stat.st_nlink = 1;
        stat.st_size = @intCast(buffer.items.len);
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

        stat.st_mode = fuse.S_IFREG | 0o0222;
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
    // fi.?.direct_io = 1;
        
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
    std.log.debug("Putting path '{s}', size: {}", .{ path, buffer_copy.len });

    const new_buf = ally.create(std.ArrayList(u8)) catch unreachable;
    new_buf.* = std.ArrayList(u8).fromOwnedSlice(ally, buffer_copy);

    const key = ally.dupe(u8, path) catch unreachable;
    file_buffers.put(key, new_buf) catch unreachable;

    std.log.debug("Done {}", .{file_buffers.count()});

    return 0;
}

pub fn release(c_path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    std.log.debug("Release {s}", .{c_path});
    const path = std.mem.span(c_path);

    persist_file_buffer(path) catch unreachable;

    if (file_buffers.get(path)) |list| {
        list.deinit();
        _ = file_buffers.remove(path);
    }
    _ = fi;
    return 0;
}

pub fn create(c_path: [*c]const u8, mode: fuse.mode_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;
    _ = mode;

    std.log.debug("Create {s}", .{c_path});

    const new_buf = ally.create(std.ArrayList(u8)) catch unreachable;
    new_buf.* = std.ArrayList(u8).init(ally);
    const key = ally.dupe(u8, std.mem.span(c_path)) catch unreachable;
    file_buffers.put(key, new_buf) catch unreachable;

    return 0;
}

pub fn flush(c_path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;
    const path = std.mem.span(c_path);
    std.log.debug("Flush {s}", .{c_path});
    persist_file_buffer(path) catch unreachable;
    return 0;
}

pub fn fsync(c_path: [*c]const u8, sync: c_int, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = sync;
    _ = fi;


    const path = std.mem.span(c_path);
    std.log.debug("Fsync {s}", .{c_path});
    persist_file_buffer(path) catch unreachable;
    return 0;
}

pub fn write(c_path: [*c]const u8, buf: [*c]const u8, buf_size: usize, offset: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;
    _ = buf;

    std.log.debug("Write {s} {} {}", .{ c_path, buf_size, offset });
    const path = std.mem.span(c_path);
    if (file_buffers.get(path)) {

    }
    return @intCast(buf_size);
}

pub fn read(c_path: [*c]const u8, buf: [*c]u8, buf_size: usize, offset_c: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;

    std.log.debug("Reading {s}", .{c_path});

    const path = std.mem.span(c_path);
    const offset: usize = @intCast(offset_c);

    std.log.debug("buf count {}", .{file_buffers.count()});
    var it = file_buffers.keyIterator();
    std.log.debug("has {}", .{file_buffers.contains(path)});
    while (it.next()) |key| {
        std.log.debug("it '{s}'", .{key.*});
    }

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
    std.log.debug("path not found '{s}'", .{path});
    const ENOENT = 2;
    return -ENOENT;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
