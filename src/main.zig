const std = @import("std");

const zargs = @import("zargs");

const app = @import("app.zig");
const fuse = @import("fuse.zig");

const ally = app.ally;
const ally_arena = app.ally_arena;

pub fn main() !void {
    const cmd = zargs.Command.new("GitFuse")
        .about("GitFuse -- Mount your Git repository like a filesystem.")
        .author("Marijn Stollenga")
        .homepage("")
        .optArg("repository", []const u8, .{ .short = 'r', .long = "repository" })
        .optArg("mount", []const u8, .{ .short = 'm', .long = "mount" })
        .optArg("reference", ?[]const u8, .{ .long = "reference" })
        .optArg("active", ?[]const u8, .{ .long = "active" });

    const args = cmd.parse(ally) catch |e|
        zargs.exitf(e, 1, "\n{s}\n", .{cmd.usage()});
    defer cmd.destroy(&args, ally);

    std.debug.print("Store log into {s}\n", .{args.repository});

    const reference = args.reference orelse "master";
    const active = args.active orelse "gitfuse";

    try app.init(args.repository, reference, active);
    defer app.deinit();

    const operations: fuse.fuse.fuse_operations = .{
        .getattr = &fuse.getattr,
        .readdir = &fuse.readdir,
        .open = &fuse.open,
        .read = &fuse.read,
        .release = &fuse.release,
        .create = &fuse.create,
        .flush = &fuse.flush,
        .fsync = &fuse.fsync,
        .write = &fuse.write,
        .unlink = &fuse.unlink,
        .rename = &fuse.rename,
    };

    var fuse_args = std.ArrayList(?[:0]u8).init(ally_arena);
    try fuse_args.append(try ally_arena.dupeZ(u8, "<program>"));
    try fuse_args.append(try ally_arena.dupeZ(u8, args.mount));
    try fuse_args.append(try ally_arena.dupeZ(u8, "-f")); //run in foreground
    try fuse_args.append(try ally_arena.dupeZ(u8, "-s")); //run single threaded

    // This seems necessary to pass arguments properly
    var c_strings = try ally_arena.alloc([*c]u8, fuse_args.items.len);
    for (0..fuse_args.items.len) |i| {
        c_strings[i] = fuse_args.items[i].?;
    }

    // fuse_main is supposed to be called instead of fuse_main_fn, but it is a #define and not a proper function
    _ = fuse.fuse.fuse_main_passthrough(@intCast(c_strings.len), @ptrCast(c_strings.ptr), &operations, null);
}
