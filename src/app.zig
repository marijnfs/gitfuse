const std = @import("std");

const git = @import("git.zig");
const cgit = git.cgit;
// Debug mode
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
// const ally = debug_allocator.allocator();

// Fast mode
pub const ally = std.heap.smp_allocator;

var global_arena = std.heap.ArenaAllocator.init(ally);
pub const ally_arena = global_arena.allocator();

const FileBuffer = @import("filebuffer.zig");

pub var file_buffers: std.StringHashMap(*FileBuffer) = undefined;
var mod_times: std.StringHashMap(i64) = undefined;
var fd_counter: u64 = 0;

pub fn init(repository_path: []const u8, reference_branch: []const u8, active_branch: []const u8) !void {
    try git.init(repository_path, reference_branch, active_branch);
    file_buffers = std.StringHashMap(*FileBuffer).init(ally);
    mod_times = std.StringHashMap(i64).init(ally);
}

pub fn deinit() void {
    file_buffers.deinit();
    mod_times.deinit();

    global_arena.deinit();
    _ = debug_allocator.deinit();
}

pub fn get_or_put_buffer(path: []const u8, read_only: bool, trunc: bool) !*FileBuffer {
    if (file_buffers.get(path)) |buffer| {
        std.log.debug("Opening existing buffer", .{});
        buffer.n_readers += 1;
        return buffer;
    }

    const blob = try git.get_blob(path);
    defer cgit.git_blob_free(blob);

    const content = try git.get_blob_content(blob);

    std.log.debug("Opening existing file '{s}', size: {}", .{ path, content.len });

    const new_buf = try FileBuffer.init_buffer(ally, content, read_only);

    if (trunc) {
        new_buf.truncate();
    }

    const key = try ally_arena.dupe(u8, path);
    try file_buffers.put(key, new_buf);
    return new_buf;
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

// Make the file buffer of 'path' persistent.
// This means updating the target branch with the contents of this buffer.
// Does not close the buffer.
// If buffer does not exist, that is an error
pub fn persist_file_buffer(path: []const u8) !void {
    std.log.debug("Persisting: {s}", .{path});

    if (try git.is_ignored(path)) {
        std.log.debug("Ignore Persist: {s}", .{path});

        // Ignored files are not to be persisted
        return;
    }

    if (file_buffers.get(path)) |buffer| {
        if (buffer.read_only) {
            return;
        }

        // First we create the blob and get the oid
        var buffer_oid = std.mem.zeroes(cgit.git_oid);

        const buffer_data = buffer.contents();
        try git.git_try(cgit.git_blob_create_from_buffer(&buffer_oid, git.repo, buffer_data.ptr, buffer_data.len));

        // Grab our active target tree and setup the builder
        const active_tree = try git.get_active_tree();
        const reference = try git.get_reference();

        // Find the sequence of trees to the path
        var trees = std.ArrayList(*cgit.git_tree).init(ally);
        var paths = std.ArrayList([]const u8).init(ally);
        defer trees.deinit();
        defer paths.deinit();

        var it = std.mem.tokenizeSequence(u8, path, "/");

        var current_tree: ?*cgit.git_tree = active_tree;

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

            const entry = cgit.git_tree_entry_byname(current_tree, subpath_z);
            if (entry == null)
                return error.NotFound;

            const entry_type = cgit.git_tree_entry_type(entry);
            const sub_oid = cgit.git_tree_entry_id(entry);

            if (entry_type != cgit.GIT_OBJ_TREE) {
                return error.ExpectedTree;
            }

            try git.git_try(cgit.git_tree_lookup(&current_tree, git.repo, sub_oid));
        }

        // Now recursively build up the updated tree
        var i: usize = trees.items.len;
        var new_oid = buffer_oid;
        var oid_mode: cgit.git_filemode_t = cgit.GIT_FILEMODE_BLOB;
        while (i > 0) {
            i -= 1;
            const tree = trees.items[i];
            const subpath = paths.items[i];
            const subpath_c = try ally.dupeZ(u8, subpath);
            defer ally.free(subpath_c);

            var builder: ?*cgit.git_treebuilder = null;
            try git.git_try(cgit.git_treebuilder_new(&builder, git.repo, tree));
            defer cgit.git_treebuilder_free(builder);

            try git.git_try(cgit.git_treebuilder_insert(null, builder, subpath_c, &new_oid, oid_mode));
            var tree_oid: cgit.git_oid = undefined;
            try git.git_try(cgit.git_treebuilder_write(&tree_oid, builder));

            new_oid = tree_oid;
            oid_mode = cgit.GIT_FILEMODE_TREE;
        }

        // Now the new tree id is new_oid
        // Set up the commit
        const target_branch = git.active_branch;

        const new_tree_oid = new_oid;

        var new_tree: ?*cgit.git_tree = null;
        try git.git_try(cgit.git_tree_lookup(&new_tree, git.repo, &new_tree_oid));
        _ = try git.create_commit(
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
    const active_tree = try git.get_active_tree();
    const reference = try git.get_reference();

    // Find the sequence of trees to the path
    var trees = std.ArrayList(*cgit.git_tree).init(ally);
    var paths = std.ArrayList([]const u8).init(ally);
    defer trees.deinit();
    defer paths.deinit();

    var it = std.mem.tokenizeSequence(u8, path, "/");

    var current_tree: ?*cgit.git_tree = active_tree;

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

        const entry = cgit.git_tree_entry_byname(current_tree, subpath_z);
        if (entry == null)
            return error.NotFound;

        const entry_type = cgit.git_tree_entry_type(entry);
        const sub_oid = cgit.git_tree_entry_id(entry);

        if (entry_type != cgit.GIT_OBJ_TREE) {
            return error.ExpectedTree;
        }

        try git.git_try(cgit.git_tree_lookup(&current_tree, git.repo, sub_oid));
    }

    // Now recursively build up the updated tree
    var i: usize = trees.items.len;
    var new_oid: cgit.git_oid = undefined;
    var oid_mode: cgit.git_filemode_t = cgit.GIT_FILEMODE_BLOB;
    while (i > 0) {
        i -= 1;
        const tree = trees.items[i];
        const subpath = paths.items[i];
        const subpath_c = try ally.dupeZ(u8, subpath);
        defer ally.free(subpath_c);

        var builder: ?*cgit.git_treebuilder = null;
        try git.git_try(cgit.git_treebuilder_new(&builder, git.repo, tree));
        defer cgit.git_treebuilder_free(builder);

        const deepest_tree = (i == trees.items.len - 1);
        // on the deepest tree we remove the object, all other levels are updates of the trees, done with an overwriting insert
        if (deepest_tree) {
            try git.git_try(cgit.git_treebuilder_remove(builder, subpath_c));
        } else {
            try git.git_try(cgit.git_treebuilder_insert(null, builder, subpath_c, &new_oid, oid_mode));
        }
        var tree_oid: cgit.git_oid = undefined;
        try git.git_try(cgit.git_treebuilder_write(&tree_oid, builder));

        new_oid = tree_oid;
        oid_mode = cgit.GIT_FILEMODE_TREE;
    }

    // Now the new tree id is new_oid
    // Set up the commit
    const target_branch = git.active_branch;

    const new_tree_oid = new_oid;

    var new_tree: ?*cgit.git_tree = null;
    try git.git_try(cgit.git_tree_lookup(&new_tree, git.repo, &new_tree_oid));
    _ = try git.create_commit(
        new_tree.?,
        reference.commit,
        target_branch,
    );
}
