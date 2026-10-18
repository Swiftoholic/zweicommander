#include <stdint.h>
typedef int (*zc_copy_progress)(void *context, int64_t bytes);
/* Returns a POSIX error number, or zero. The callback returns nonzero to stop. */
int zc_copy(const char *source, const char *destination, int metadata_only,
            zc_copy_progress callback, void *context);

/* Copies between already opened regular file descriptors. */
int zc_copy_fd(int source_fd, int destination_fd, zc_copy_progress callback, void *context);
