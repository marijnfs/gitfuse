const std = @import("std");
const fuse = @cImport({
    @cDefine("FUSE_USE_VERSION", "31");
    // @cInclude("fuse_wrapper.h");
    @cInclude("fuse3/fuse.h");
});
const ENOENT = 2;

const git = @cImport({
    @cInclude("git2.h");
});

const zargs = @import("zargs");

// Debug mode
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
// const ally = debug_allocator.allocator();

// Fast mode
const ally = std.heap.smp_allocator;

var global_arena = std.heap.ArenaAllocator.init(ally);
const ally_arena = global_arena.allocator();
// const ally = std.heap.c_allocator;

var repo: *git.git_repository = undefined;

const FuseFileInfo = @import("fusefileinfo.zig").FuseFileInfo;

const FileBuffer = @import("filebuffer.zig");

var file_buffers: std.StringHashMap(*FileBuffer) = undefined;
var mod_times: std.StringHashMap(i64) = undefined;
var fd_counter: u64 = 0;

fn git_try(err_code: c_int) !void {
    if (err_code < 0) {
        const err: *const git.git_error = git.git_error_last();
        std.log.warn("Git error: {s}", .{err.message});
        return error.git_error;
    }
}

// get tree in active repository, corresponding to path
pub fn get_dir(path: []const u8) !*git.git_tree {
    const tree = try get_active_tree();

    var current_tree: ?*git.git_tree = tree;
    var it = std.mem.tokenizeSequence(u8, path, "/");

    while (it.next()) |subpath| {
        const subpath_z = try ally.dupeZ(u8, subpath);
        defer ally.free(subpath_z);

        const entry = git.git_tree_entry_byname(current_tree, subpath_z);
        if (entry == null)
            return error.NotFound;

        const entry_type = git.git_tree_entry_type(entry);
        if (entry_type != git.GIT_OBJ_TREE) {
            return error.ExpectedTree;
        }

        const oid = git.git_tree_entry_id(entry);
        try git_try(git.git_tree_lookup(&current_tree, repo, oid));
    }

    return current_tree.?;
}

pub fn get_blob(path: []const u8) !*git.git_blob {
    const object = try get_object(path);

    const o_type = git.git_object_type(object);
    if (o_type != git.GIT_OBJECT_BLOB)
        return error.ObjectNotBlob;

    return @ptrCast(object);
}

// get object from active repository, corresponding to path
pub fn get_object(path: []const u8) !*git.git_object {
    const tree = try get_active_tree();

    var current_tree: ?*git.git_tree = tree;
    var it = std.mem.tokenizeSequence(u8, path, "/");

    while (it.next()) |subpath| {
        const subpath_z = try ally.dupeZ(u8, subpath);
        defer ally.free(subpath_z);

        const entry = git.git_tree_entry_byname(current_tree, subpath_z);
        if (entry == null)
            return error.NotFound;

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

pub fn init(repository_path: []const u8) !void {
    _ = git.git_libgit2_init();

    file_buffers = std.StringHashMap(*FileBuffer).init(ally);
    {
        var repo_tmp: ?*git.git_repository = null;
        try git_try(git.git_repository_open(&repo_tmp, try ally_arena.dupeZ(u8, repository_path)));
        repo = repo_tmp.?;
    }

    mod_times = std.StringHashMap(i64).init(ally);
}

pub fn deinit() void {
    std.log.info("Closing application", .{});
    _ = git.git_libgit2_shutdown();

    git.git_repository_free(repo);
    file_buffers.deinit();
    mod_times.deinit();

    global_arena.deinit();
    _ = debug_allocator.deinit();
}

pub fn create_commit(tree: *git.git_tree, parent: *git.git_commit, reference_opt: ?[]const u8) !git.git_oid {
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

    try git_try(git.git_commit_create(&oid, repo, null, &author, &author, "UTF-8", "GitFuse", tree, parents.len, @constCast(@ptrCast(&parents))));

    var commit: ?*git.git_commit = null;
    try git_try(git.git_commit_lookup(&commit, repo, &oid));

    if (reference_opt) |reference| {
        const reference_c = try ally.dupeZ(u8, reference);
        defer ally.free(reference_c);

        var git_reference: ?*git.git_reference = null;
        const force = 1;
        try git_try(git.git_branch_create(&git_reference, repo, reference_c, commit, force));
    }

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
    const target_branch = "gitfuse";

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
    std.log.debug("Persisting: {s}", .{path});
    if (file_buffers.get(path)) |buffer| {
        if (buffer.read_only) {
            return;
        }

        // First we create the blob and get the oid
        var buffer_oid = std.mem.zeroes(git.git_oid);

        const buffer_data = buffer.contents();
        try git_try(git.git_blob_create_from_buffer(&buffer_oid, repo, buffer_data.ptr, buffer_data.len));

        // Grab our active target tree and setup the builder
        const active_tree = try get_active_tree();
        const reference = try get_reference();

        // Find the sequence of trees to the path
        var trees = std.ArrayList(*git.git_tree).init(ally);
        var paths = std.ArrayList([]const u8).init(ally);
        defer trees.deinit();
        defer paths.deinit();

        var it = std.mem.tokenizeSequence(u8, path, "/");

        var current_tree: ?*git.git_tree = active_tree;

        while (it.next()) |subpath| {
            try trees.append(current_tree.?);
            try paths.append(subpath);

            const last_comparison = it.peek() == null;
            if (last_comparison) {
                // We are on the last level and found the file
                break;
            }

            const subpath_z = try ally.dupeZ(u8, subpath);
            defer ally.free(subpath_z);

            const entry = git.git_tree_entry_byname(current_tree, subpath_z);
            if (entry == null)
                return error.NotFound;

            const entry_type = git.git_tree_entry_type(entry);
            const sub_oid = git.git_tree_entry_id(entry);

            if (entry_type != git.GIT_OBJ_TREE) {
                return error.ExpectedTree;
            }

            try git_try(git.git_tree_lookup(&current_tree, repo, sub_oid));
        }

        // Now recursively build up the updated tree
        var i: usize = trees.items.len;
        var new_oid = buffer_oid;
        var oid_mode: git.git_filemode_t = git.GIT_FILEMODE_BLOB;
        while (i > 0) {
            i -= 1;
            const tree = trees.items[i];
            const subpath = paths.items[i];
            const subpath_c = try ally.dupeZ(u8, subpath);
            defer ally.free(subpath_c);

            var builder: ?*git.git_treebuilder = null;
            try git_try(git.git_treebuilder_new(&builder, repo, tree));
            defer git.git_treebuilder_free(builder);

            try git_try(git.git_treebuilder_insert(null, builder, subpath_c, &new_oid, oid_mode));
            var tree_oid: git.git_oid = undefined;
            try git_try(git.git_treebuilder_write(&tree_oid, builder));

            new_oid = tree_oid;
            oid_mode = git.GIT_FILEMODE_TREE;
        }

        // Now the new tree id is new_oid
        // Set up the commit
        const target_branch = "gitfuse";

        const new_tree_oid = new_oid;

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
    std.log.debug("Done Persisting: {s}", .{path});
}

pub fn remove_file(path: []const u8) !void {
    std.log.debug("Persisting: {s}", .{path});

    // Grab our active target tree and setup the builder
    const active_tree = try get_active_tree();
    const reference = try get_reference();

    // Find the sequence of trees to the path
    var trees = std.ArrayList(*git.git_tree).init(ally);
    var paths = std.ArrayList([]const u8).init(ally);
    defer trees.deinit();
    defer paths.deinit();

    var it = std.mem.tokenizeSequence(u8, path, "/");

    var current_tree: ?*git.git_tree = active_tree;

    while (it.next()) |subpath| {
        try trees.append(current_tree.?);
        try paths.append(subpath);

        const last_comparison = it.peek() == null;
        if (last_comparison) {
            // We are on the last level and found the file
            break;
        }

        const subpath_z = try ally.dupeZ(u8, subpath);
        defer ally.free(subpath_z);

        const entry = git.git_tree_entry_byname(current_tree, subpath_z);
        if (entry == null)
            return error.NotFound;

        const entry_type = git.git_tree_entry_type(entry);
        const sub_oid = git.git_tree_entry_id(entry);

        if (entry_type != git.GIT_OBJ_TREE) {
            return error.ExpectedTree;
        }

        try git_try(git.git_tree_lookup(&current_tree, repo, sub_oid));
    }

    // Now recursively build up the updated tree
    var i: usize = trees.items.len;
    var new_oid: git.git_oid = undefined;
    var oid_mode: git.git_filemode_t = git.GIT_FILEMODE_BLOB;
    while (i > 0) {
        i -= 1;
        const tree = trees.items[i];
        const subpath = paths.items[i];
        const subpath_c = try ally.dupeZ(u8, subpath);
        defer ally.free(subpath_c);

        var builder: ?*git.git_treebuilder = null;
        try git_try(git.git_treebuilder_new(&builder, repo, tree));
        defer git.git_treebuilder_free(builder);

        const deepest_tree = (i == trees.items.len - 1);
        // on the deepest tree we remove the object, all other levels are updates of the trees, done with an overwriting insert
        if (deepest_tree) {
            try git_try(git.git_treebuilder_remove(builder, subpath_c));
        } else {
            try git_try(git.git_treebuilder_insert(null, builder, subpath_c, &new_oid, oid_mode));
        }
        var tree_oid: git.git_oid = undefined;
        try git_try(git.git_treebuilder_write(&tree_oid, builder));

        new_oid = tree_oid;
        oid_mode = git.GIT_FILEMODE_TREE;
    }

    // Now the new tree id is new_oid
    // Set up the commit
    const target_branch = "gitfuse";

    const new_tree_oid = new_oid;

    var new_tree: ?*git.git_tree = null;
    try git_try(git.git_tree_lookup(&new_tree, repo, &new_tree_oid));
    _ = try create_commit(
        new_tree.?,
        reference.commit,
        target_branch,
    );
}
pub fn update_modtime(path: []const u8) !i64 {
    const cur = std.time.timestamp();

    if (mod_times.getPtr(path)) |timestamp| {
        timestamp.* = cur;
        return cur;
    }

    try mod_times.put(try ally_arena.dupe(u8, path), cur);
    return cur;
}

pub fn get_modtime(path: []const u8) !i64 {
    if (mod_times.get(path)) |timestamp| {
        return timestamp;
    }

    const cur = std.time.timestamp();
    try mod_times.put(try ally_arena.dupe(u8, path), cur);
    return cur;
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
    const cmd = zargs.Command.new("GitFuse")
        .about("GitFuse -- Mount your Git repository like a filesystem.")
        .author("Marijn Stollenga")
        .homepage("")
        .optArg("repository", []const u8, .{ .short = 'r', .long = "repository" })
        .optArg("mount", []const u8, .{ .short = 'm', .long = "mount" });

    const args = cmd.parse(ally) catch |e|
        zargs.exitf(e, 1, "\n{s}\n", .{cmd.usage()});
    defer cmd.destroy(&args, ally);

    std.debug.print("Store log into {s}\n", .{args.repository});

    try init(args.repository);
    defer deinit();

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
        .unlink = &unlink,
    };

    var fuse_args = std.ArrayList(?[:0]u8).init(ally_arena);
    try fuse_args.append(try ally_arena.dupeZ(u8, "<program>"));
    try fuse_args.append(try ally_arena.dupeZ(u8, args.mount));
    try fuse_args.append(try ally_arena.dupeZ(u8, "-f"));
    try fuse_args.append(try ally_arena.dupeZ(u8, "-s"));

    // This seems necessary to pass arguments properly
    var c_strings = try ally_arena.alloc([*c]u8, fuse_args.items.len);
    for (0..fuse_args.items.len) |i| {
        c_strings[i] = fuse_args.items[i].?;
    }

    // fuse_main is supposed to be called instead of fuse_main_fn, but it is a #define and not a proper function
    _ = fuse.fuse_main_fn(@intCast(c_strings.len), @ptrCast(c_strings.ptr), &operations, null);
}

pub fn readdir(cpath: [*c]const u8, buf: ?*anyopaque, filler: fuse.fuse_fill_dir_t, offset: fuse.off_t, fi: ?*fuse.fuse_file_info, flags: fuse.fuse_readdir_flags) callconv(.C) c_int {
    std.log.debug("readdir: {s}", .{cpath});
    const path = std.mem.span(cpath);

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
        .tv_sec = get_modtime(path) catch unreachable,
        .tv_nsec = 0,
    };

    // First deal with root case
    const ROOT = "/";
    if (std.mem.eql(u8, ROOT, path)) {
        stat.st_mode = fuse.S_IFDIR | 0o0755;
        return 0;
    }

    // Look at existing buffers
    if (file_buffers.get(path)) |buffer| {
        stat.st_mode = fuse.S_IFREG | 0o0644;
        stat.st_nlink = 1;
        stat.st_size = @intCast(buffer.size());
        return 0;
    }

    const object = get_object(path) catch {
        std.log.debug("getattr no object: {s}", .{path});
        return -ENOENT;
    };
    const o_type = git.git_object_type(object);

    if (o_type == git.GIT_OBJECT_BLOB) {
        const blob: *git.git_blob = @ptrCast(object);
        const size = git.git_blob_rawsize(blob);

        stat.st_mode = fuse.S_IFREG | 0o0644;
        stat.st_nlink = 1;
        stat.st_size = @intCast(size);
    } else if (o_type == git.GIT_OBJECT_TREE) {
        stat.st_mode = fuse.S_IFDIR | 0o0755;
        stat.st_nlink = 2;
    } else {
        return -ENOENT;
    }

    return 0;
}

pub fn get_blob_content(blob: *git.git_blob) ![]const u8 {
    const content_c = git.git_blob_rawcontent(blob);
    if (content_c == null) {
        return error.NoContent;
    }
    const content_ptr: [*c]const u8 = @ptrCast(content_c.?);
    const size = git.git_blob_rawsize(blob);
    return content_ptr[0..size];
}

fn get_or_put_buffer(path: []const u8, read_only: bool, trunc: bool) !*FileBuffer {
    if (file_buffers.get(path)) |buffer| {
        std.log.debug("Opening existing buffer", .{});
        buffer.n_readers += 1;
        return buffer;
    }

    const blob = try get_blob(path);
    defer git.git_blob_free(blob);

    const content = try get_blob_content(blob);

    std.log.debug("Opening existing file '{s}', size: {}", .{ path, content.len });

    const new_buf = try FileBuffer.init_buffer(ally, content, read_only);

    if (trunc) {
        new_buf.truncate();
    }

    const key = try ally_arena.dupe(u8, path);
    try file_buffers.put(key, new_buf);
    return new_buf;
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

    _ = get_or_put_buffer(path, read_only, trunc) catch {
        std.log.warn("Failed to open buffer '{s}'", .{path});
        return -ENOENT;
    };

    return 0;
}

pub fn release(c_path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    std.log.debug("Release {s}", .{c_path});
    const path = std.mem.span(c_path);

    persist_file_buffer(path) catch {
        std.log.warn("Buffer not found during release", .{});
        return 0;
    };

    if (file_buffers.get(path)) |buffer| {
        if (buffer.last_reader()) {
            buffer.deinit(ally);
            _ = file_buffers.remove(path);
        } else {
            buffer.n_readers -= 1;
        }
    }
    _ = fi;
    return 0;
}

pub fn create_buffer(path: []const u8, read_only: bool) !*FileBuffer {
    const new_buf = try FileBuffer.init(ally, read_only);
    const key = try ally_arena.dupe(u8, path);
    try file_buffers.put(key, new_buf);
    return new_buf;
}

pub fn create_buffer_from_content(path: []const u8, content: []const u8) !*FileBuffer {
    const read_only = false;
    const new_buf = try FileBuffer.init_buffer(ally, content, read_only);
    const key = try ally_arena.dupe(u8, path);
    try file_buffers.put(key, new_buf);
    return new_buf;
}

pub fn create(c_path: [*c]const u8, mode: fuse.mode_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;
    _ = mode;

    std.log.debug("Create {s}", .{c_path});

    const path = std.mem.span(c_path);
    const read_only = false;
    _ = create_buffer(path, read_only) catch {
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
    persist_file_buffer(path) catch unreachable;
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
    if (file_buffers.get(path)) |file_buf| {
        if (file_buf.read_only) {
            std.log.warn("Writing to read only buffer: {s}", .{c_path});
            return -1;
        }
        file_buf.write(buf[0..buf_size], offset) catch unreachable;
    }

    _ = update_modtime(path) catch unreachable;
    return @intCast(buf_size);
}

pub fn read(c_path: [*c]const u8, buf: [*c]u8, buf_size: usize, offset_c: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
    _ = fi;

    std.log.debug("Reading {s}", .{c_path});

    const path = std.mem.span(c_path);
    const offset: usize = @intCast(offset_c);

    if (file_buffers.get(path)) |buffer| {
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
    remove_file(path) catch {
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
    const src_buffer = get_or_put_buffer(src_path, read_only, trunc);
    const content = src_buffer.content();

    // create new buffer
    _ = create_buffer_from_content(dest_path, content) catch {
        std.log.warn("Failed to create {s}", .{dest_path});

        return -1;
    };

    // now remove old buffer
    remove_file(src_path) catch {
        std.log.warn("Remove failed", .{});
        return -1;
    };
    src_buffer.deinit() catch unreachable;
    file_buffers.remove(src_path) catch unreachable;
    return 0;
}
