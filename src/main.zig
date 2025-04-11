const std = @import("std");
const fuse = @cImport({
    @cDefine("FUSE_USE_VERSION", "31");
    @cInclude("fuse3/fuse.h");
});
const git = @cImport({
    @cInclude("git2.h");
});

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

    const operations: fuse.fuse_operations = undefined;

    const argc: c_int = 0;
    const argv: [*c][*c]u8 = undefined;
    _ = fuse.fuse_main_real(argc, argv, &operations, @sizeOf(@TypeOf(operations)), null);

    try bw.flush(); // don't forget to flush!
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
