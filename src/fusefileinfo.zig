// Zig version of the c struct fuse_file_info, which has bitfields and can't be imported automatically
//
pub const FuseFileInfo = packed struct {
    flags: i32,
    writepage: bool,
    direct_io: bool,
    keep_cache: bool,
    flush: bool,
    nonseekable: bool,
    flock_release: bool,
    cache_readdir: bool,
    noflush: bool,
    parallel_direct_writes: bool,
    padding: u23,
    padding2: u32,
    padding3: u32,
    fh: u64,
    lock_owner: u64,
    poll_events: u32,
    backing_id: u32,
    compat_flags: u64,
    reserved: u64,
    reserved2: u64,
};
