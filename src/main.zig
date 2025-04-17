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

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    const ally = std.heap.page_allocator;
    var args = std.ArrayList([:0]const u8).init(ally);
    {
        var iterator = try std.process.argsWithAllocator(ally);
        while (iterator.next()) |arg| {
            try args.append(arg);
        }
    }
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
        const path = args.items[1];

        var iterator = std.mem.tokenize(u8, path, "/");
        while (iterator.next()) |name| {
            if (std.mem.eql(u8, name, ".")) {
                continue;
            }
            std.log.info("looking up: {s}", .{name});
            const namez = try ally.dupeZ(u8, name);
            const entry = git.git_tree_entry_byname(tree, namez);
            if (entry == null)
                return error.NotFound;

            const entry_type = git.git_tree_entry_type(entry);

            if (entry_type == git.GIT_OBJ_BLOB) {
                return error.FoundBlob;
            }

            if (entry_type == git.GIT_OBJ_TREE) {
                const oid = git.git_tree_entry_id(entry);
                err = git.git_tree_lookup(&tree, repo, oid);
                if (err < 0) {
                    return error.Failed;
                }
            }
        }
        // std.debug.print("found: {any}\n", .{entry});

        // std.debug.print("found: {s}\n", .{git.git_tree_entry_name(entry)});
    }

    // _ = git.git_tree_walk(tree, git.GIT_TREEWALK_PRE, tree_callback, null);

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
