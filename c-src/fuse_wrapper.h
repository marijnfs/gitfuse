#include <fuse3/fuse.h>

// fuse_main is a #define macro, so we need some c-code to call it
static inline int fuse_main_passthrough(int argc, char *argv[],
			       const struct fuse_operations *op,
			       void *user_data)
{
	return fuse_main(argc, argv, op, user_data);
}

