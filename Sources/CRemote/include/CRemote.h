#ifndef ZWEI_REMOTE_H
#define ZWEI_REMOTE_H
#include <stdint.h>
#include <stddef.h>
typedef int (*zr_progress)(void *, int64_t);
/* operation: 0 LIST/MLSD, 1 download, 2 upload, 3 MKD. No credentials in URLs or logs. */
int zr_request(const char *url, const char *user, const char *password, int tls,
               const char *ca, int operation, const char *command, int fd, int64_t size,
               char **text, size_t *length, char *error, size_t error_size,
               zr_progress progress, void *context);
void zr_free(void *pointer);
#endif
