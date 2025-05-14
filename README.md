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

## Status of Project
GitFuse is very much an experimental project. Don't use it on your only copy of your favourite repository! Also don't mount it on directories with other important files in them!

## Functionality
Many of the basic functionalities are there, but there might be bugs!:
- Mount a branch of your (bare) repository of choice on your chosen mount point.
- Make changes to the branch (I.e. add, remove, edit existing files or directories). This creates a new 'active' branch with your reference branch as a parent, that includes your changes).
- Next time you mount the repository, this 'active' branch will be loaded and your changes are persisted! If you remove the branch from your repository, you will automatically get back to your reference branch.
- To merge your changes to your reference branch, you would have to manually use git commands to merge the changes to your reference branch.

## Todo
[] Streaming API: currently any file that is opened is fully read into memory, until it is closed. This could lead to excessive memory usage. Using the streaming API, files could be read in a streaming manner directly from the file-system on demand.
[] Multi-threading: Currently FUSE is set in a single-threaded mode because of the absence of any thread-safety in the current code. Supporting multi-threading can be done, but needs to be done carefully to actually make it efficient and safe.
[] Multi-mount: An interesting added functionality would be to mount several branches in different mount points from a single repository at the same time. This corresponds to quite a few development workflows where you work on a few feature-branches at the same time.
