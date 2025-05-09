GitFuse
=======
Author: Marijn Stollenga

Mount your Git repository as a filesystem!
GitFuse is written in Zig!

## Build Instructions:
- Make sure you have libgit2 and libfuse installed!
- Make sure you get Zig 0.14.0
- Type make (translates to zig build)

## Usage
Define the (typically bare) repository you want to mount, and the mount point to mount it on.
`./zig-out/bin/gitfuse -r /path/to/your/repo -m /path/to/mount/point`

