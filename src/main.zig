const std = @import("std");
const fuse = @cImport({
    @cDefine("FUSE_USE_VERSION", "31");
    @cInclude("fuse3/fuse.h");
});
const git = @cImport({
    @cInclude("git2.h");
});

pub fn tree_callback(root: [*c]const u8, entry: ?*const git.git_tree_entry, payload: ?*anyopaque) callconv(.C) c_int {
    std.debug.print("{s}{s}\n", .{ root, git.git_tree_entry_name(entry) });

    // _ = entry;
    _ = payload;
    return 0;
}

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Hello.\n", .{});

    _ = git.git_libgit2_init();
    defer _ = git.git_libgit2_shutdown();

    var repo: ?*git.git_repository = null;
    var err = git.git_repository_open(&repo, ".");
    if (err < 0) {
        return error.Failed;
    }
    defer git.git_repository_free(repo);

    var treeish: ?*git.git_object = null;
    err = git.git_revparse_single(&treeish, repo, "refs/heads/master");
    if (err < 0) {
        return error.Failed;
    }
    defer git.git_object_free(treeish);

    var commit: ?*git.git_commit = null;
    err = git.git_commit_lookup(&commit, repo, git.git_object_id(treeish));
    if (err < 0) {
        return error.Failed;
    }

    var tree: ?*git.git_tree = null;
    err = git.git_commit_tree(&tree, commit);
    if (err < 0) {
        return error.Failed;
    }

    {
        const entry = git.git_tree_entry_byname(tree, "doc");
        std.debug.print("found: {any}\n", .{entry});

        // std.debug.print("found: {s}\n", .{git.git_tree_entry_name(entry)});
    }

    _ = git.git_tree_walk(tree, git.GIT_TREEWALK_PRE, tree_callback, null);

    // const operations: fuse.fuse_operations = undefined;

    // const argc: c_int = 0;
    // const argv: [*c][*c]u8 = undefined;
    // _ = fuse.fuse_main_real(argc, argv, &operations, @sizeOf(@TypeOf(operations)), null);

    try bw.flush(); // don't forget to flush!
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
