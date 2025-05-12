const std = @import("std");

pub const cgit = @cImport({
    @cInclude("git2.h");
});

const app = @import("app.zig");
const ally = app.ally;
const ally_arena = app.ally_arena;

pub var repo: *cgit.git_repository = undefined;

/// Reference branch is base of changes
/// Active branch is the name of updated branch
/// 0-terminated to operate with C
pub var reference_branch: [:0]const u8 = "";
pub var active_branch: [:0]const u8 = "";

pub fn git_try(err_code: c_int) !void {
    if (err_code < 0) {
        const err: *const cgit.git_error = cgit.git_error_last();
        std.log.warn("Git error: {s}", .{err.message});
        return error.git_error;
    }
}

const Reference = struct {
    commit: *cgit.git_commit,
    tree: *cgit.git_tree,
};

pub fn init(repository_path: []const u8, reference_branch_: []const u8, active_branch_: []const u8) !void {
    try git_try(cgit.git_libgit2_init());

    {
        var repo_tmp: ?*cgit.git_repository = null;
        try git_try(cgit.git_repository_open(&repo_tmp, try ally_arena.dupeZ(u8, repository_path)));
        repo = repo_tmp.?;
    }

    reference_branch = try ally_arena.dupeZ(u8, reference_branch_);
    active_branch = try ally_arena.dupeZ(u8, active_branch_);

    //try to load ignore file
    if (try get_blob(".gitignore")) |blob| {
        defer cgit.git_blob_free(blob);

        const content = try get_blob_content(blob);
        const contentZ = try ally.dupeZ(u8, content);
        defer ally.free(contentZ);
        try git_try(cgit.git_ignore_add_rule(repo, contentZ));
    }
}

pub fn deinit() void {
    std.log.info("Closing application", .{});
    _ = cgit.git_libgit2_shutdown();

    cgit.git_repository_free(repo);
}

// get tree in active repository, corresponding to path
pub fn get_dir(path: []const u8) !*cgit.git_tree {
    const tree = try get_active_tree();

    var current_tree: ?*cgit.git_tree = tree;
    var it = std.mem.tokenizeSequence(u8, path, "/");

    while (it.next()) |subpath| {
        const subpath_z = try ally.dupeZ(u8, subpath);
        defer ally.free(subpath_z);

        const entry = cgit.git_tree_entry_byname(current_tree, subpath_z);
        if (entry == null)
            return error.NotFound;

        const entry_type = cgit.git_tree_entry_type(entry);
        if (entry_type != cgit.GIT_OBJ_TREE) {
            return error.ExpectedTree;
        }

        const oid = cgit.git_tree_entry_id(entry);
        try git_try(cgit.git_tree_lookup(&current_tree, repo, oid));
    }

    return current_tree.?;
}

pub fn get_blob(path: []const u8) !?*cgit.git_blob {
    const object = get_object(path) catch return null;

    const o_type = cgit.git_object_type(object);
    if (o_type != cgit.GIT_OBJECT_BLOB)
        return error.ObjectNotBlob;

    return @ptrCast(object);
}

// get object from active repository, corresponding to path
pub fn get_object(path: []const u8) !*cgit.git_object {
    const tree = try get_active_tree();

    var current_tree: ?*cgit.git_tree = tree;
    var it = std.mem.tokenizeSequence(u8, path, "/");

    while (it.next()) |subpath| {
        const subpath_z = try ally.dupeZ(u8, subpath);
        defer ally.free(subpath_z);

        const entry = cgit.git_tree_entry_byname(current_tree, subpath_z);
        if (entry == null)
            return error.NotFound;

        const entry_type = cgit.git_tree_entry_type(entry);
        const oid = cgit.git_tree_entry_id(entry);

        const last_comparison = it.peek() == null;
        if (last_comparison) {
            var obj_c: ?*cgit.git_object = null;
            try git_try(cgit.git_object_lookup(&obj_c, repo, oid, cgit.GIT_OBJECT_ANY));
            if (obj_c == null) {
                return error.FailedLookup;
            }
            return obj_c.?;
        }
        if (entry_type != cgit.GIT_OBJ_TREE) {
            return error.ExpectedTree;
        }
        try git_try(cgit.git_tree_lookup(&current_tree, repo, oid));
    }

    return error.NotFound;
}

pub fn create_commit(tree: *cgit.git_tree, parent: *cgit.git_commit, reference_opt: ?[]const u8) !cgit.git_oid {
    var oid = std.mem.zeroes(cgit.git_oid);

    const author: cgit.git_signature = .{
        .name = @constCast(active_branch),
        .email = @constCast(""),
        .when = .{
            .time = std.time.timestamp(),
            .offset = 0,
            .sign = 0,
        },
    };

    const parents: [1]*cgit.git_commit = .{parent};

    try git_try(cgit.git_commit_create(&oid, repo, null, &author, &author, "UTF-8", "GitFuse", tree, parents.len, @constCast(@ptrCast(&parents))));

    var commit: ?*cgit.git_commit = null;
    try git_try(cgit.git_commit_lookup(&commit, repo, &oid));

    if (reference_opt) |reference| {
        const reference_c = try ally.dupeZ(u8, reference);
        defer ally.free(reference_c);

        var git_reference: ?*cgit.git_reference = null;
        const force = 1;
        try git_try(cgit.git_branch_create(&git_reference, repo, reference_c, commit, force));
    }

    return oid;
}

pub fn get_reference() !Reference {
    var reference_treeish: ?*cgit.git_object = null;
    try git_try(cgit.git_revparse_single(&reference_treeish, repo, reference_branch));

    var ref_commit: ?*cgit.git_commit = null;
    try git_try(cgit.git_commit_lookup(&ref_commit, repo, cgit.git_object_id(reference_treeish)));

    var ref_tree: ?*cgit.git_tree = null;
    try git_try(cgit.git_commit_tree(&ref_tree, ref_commit));

    return .{
        .commit = ref_commit.?,
        .tree = ref_tree.?,
    };
}

pub fn get_active_tree() !*cgit.git_tree {
    var treeish: ?*cgit.git_object = null;
    git_try(cgit.git_revparse_single(&treeish, repo, active_branch)) catch {
        std.log.debug("Didn't find target branch, creating it", .{});

        const ref = try get_reference();

        _ = try create_commit(ref.tree, ref.commit, active_branch);

        // Finally the treeish is gonna point to the ref tree
        return ref.tree;
    };

    var ref_commit: ?*cgit.git_commit = null;
    try git_try(cgit.git_commit_lookup(&ref_commit, repo, cgit.git_object_id(treeish)));

    var ref_tree: ?*cgit.git_tree = null;
    try git_try(cgit.git_commit_tree(&ref_tree, ref_commit));

    return ref_tree.?;
}

pub fn get_blob_content(blob: *cgit.git_blob) ![]const u8 {
    const content_c = cgit.git_blob_rawcontent(blob);
    if (content_c == null) {
        return error.NoContent;
    }
    const content_ptr: [*c]const u8 = @ptrCast(content_c.?);
    const size = cgit.git_blob_rawsize(blob);
    return content_ptr[0..size];
}

pub fn list_git_dir(tree: *cgit.git_tree) void {
    const N = cgit.git_tree_entrycount(tree);
    for (0..N) |n| {
        const entry = cgit.git_tree_entry_byindex(tree, n);
        const name = cgit.git_tree_entry_name(entry);
        std.log.info("entry: {s}", .{name});
    }
}

pub fn insert_empty_tree(path: []const u8) !void {
    std.log.debug("Make Tree: {s}", .{path});

    // Grab our active target tree and setup the builder
    const active_tree = try get_active_tree();
    const reference = try get_reference();

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

        try git_try(cgit.git_tree_lookup(&current_tree, repo, sub_oid));
    }

    var new_oid = std.mem.zeroes(cgit.git_oid);
    {
        var builder: ?*cgit.git_treebuilder = null;
        try git_try(cgit.git_treebuilder_new(&builder, repo, null));
        defer cgit.git_treebuilder_free(builder);

        try git_try(cgit.git_treebuilder_write(&new_oid, builder));
    }

    // Now recursively build up the updated tree
    var i: usize = trees.items.len;
    while (i > 0) {
        i -= 1;
        const tree = trees.items[i];
        const subpath = paths.items[i];
        const subpath_c = try ally.dupeZ(u8, subpath);
        defer ally.free(subpath_c);

        var builder: ?*cgit.git_treebuilder = null;
        try git_try(cgit.git_treebuilder_new(&builder, repo, tree));
        defer cgit.git_treebuilder_free(builder);

        std.log.debug("Print path: {s} {}", .{ subpath_c, new_oid });
        try git_try(cgit.git_treebuilder_insert(null, builder, subpath_c, &new_oid, cgit.GIT_FILEMODE_TREE));
        var tree_oid: cgit.git_oid = undefined;
        try git_try(cgit.git_treebuilder_write(&tree_oid, builder));

        new_oid = tree_oid;
    }

    const new_tree_oid = new_oid;

    var new_tree: ?*cgit.git_tree = null;
    try git_try(cgit.git_tree_lookup(&new_tree, repo, &new_tree_oid));
    _ = try create_commit(
        new_tree.?,
        reference.commit,
        active_branch,
    );
    std.log.debug("Done Making Tree: {s}", .{path});
}

pub fn is_ignored(path: []const u8) !bool {
    const c_path = try app.ally.dupeZ(u8, path);
    defer app.ally.free(c_path);
    var ignored: c_int = 0;
    try git_try(cgit.git_ignore_path_is_ignored(&ignored, repo, c_path));
    return ignored > 0;
}
