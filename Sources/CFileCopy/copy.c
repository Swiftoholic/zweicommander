#include "CFileCopy.h"
#include <copyfile.h>
#include <errno.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

struct zc_context { zc_copy_progress callback; void *user; };
static int status_callback(int what, int stage, copyfile_state_t state,
                           const char *src, const char *dst, void *opaque) {
    (void)src; (void)dst;
    struct zc_context *context = opaque;
    if (stage == COPYFILE_ERR) return COPYFILE_QUIT;
    off_t copied = 0;
    if (what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS)
        copyfile_state_get(state, COPYFILE_STATE_COPIED, &copied);
    return context->callback && context->callback(context->user, copied)
        ? COPYFILE_QUIT : COPYFILE_CONTINUE;
}
int zc_copy(const char *source, const char *destination, int metadata_only,
            zc_copy_progress callback, void *context) {
    copyfile_state_t state = copyfile_state_alloc();
    if (!state) return ENOMEM;
    struct zc_context bridge = {callback, context};
    uint32_t block_size = 1024 * 1024;
    if (copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, status_callback) ||
        copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, &bridge) ||
        copyfile_state_set(state, COPYFILE_STATE_BSIZE, &block_size)) {
        int error = errno; copyfile_state_free(state); return error ? error : EIO;
    }
    copyfile_flags_t flags = COPYFILE_NOFOLLOW | (metadata_only
        ? COPYFILE_METADATA : (COPYFILE_ALL | COPYFILE_EXCL));
    int result = copyfile(source, destination, state, flags);
    int error = result == 0 ? 0 : (errno ? errno : EIO);
    copyfile_state_free(state);
    return error;
}

int zc_copy_fd(int source_fd, int destination_fd, zc_copy_progress callback, void *context) {
    copyfile_state_t state = copyfile_state_alloc();
    if (!state) return ENOMEM;
    struct zc_context bridge = {callback, context};
    uint32_t block_size = 1024 * 1024;
    if (copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, status_callback) ||
        copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, &bridge) ||
        copyfile_state_set(state, COPYFILE_STATE_BSIZE, &block_size)) {
        int error = errno; copyfile_state_free(state); return error ? error : EIO;
    }
    int result = fcopyfile(source_fd, destination_fd, state, COPYFILE_ALL);
    int error = result == 0 ? 0 : (errno ? errno : EIO);
    copyfile_state_free(state);
    return error;
}

static ssize_t read_block(int fd, void *buffer, size_t size, off_t offset) {
    size_t count = 0;
    while (count < size) {
        ssize_t n = pread(fd, (char *)buffer + count, size - count, offset + count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        count += n;
    }
    return count;
}
int zc_verify_prefix_fd(int source_fd, int destination_fd, int64_t bytes,
                        zc_copy_progress callback, void *context) {
    if (bytes < 0) return EINVAL;
    const size_t block = 1024 * 1024;
    char *source = malloc(block), *destination = malloc(block);
    if (!source || !destination) { free(source); free(destination); return ENOMEM; }
    int error = 0;
    for (int64_t offset = 0; offset < bytes;) {
        size_t size = (size_t)(bytes - offset < (int64_t)block ? bytes - offset : block);
        if (read_block(source_fd, source, size, offset) < 0 ||
            read_block(destination_fd, destination, size, offset) < 0) { error = EIO; break; }
        if (memcmp(source, destination, size)) { error = EILSEQ; break; }
        offset += size;
        if (callback && callback(context, offset)) { error = ECANCELED; break; }
    }
    free(source); free(destination); return error;
}
int zc_resume_fd(int source_fd, int destination_fd, int64_t offset, int64_t total,
                 zc_copy_progress callback, void *context) {
    if (offset < 0 || total < offset) return EINVAL;
    const size_t block = 1024 * 1024;
    char *buffer = malloc(block);
    if (!buffer) return ENOMEM;
    int error = 0;
    if (callback && callback(context, offset)) { free(buffer); return ECANCELED; }
    while (offset < total) {
        size_t size = (size_t)(total - offset < (int64_t)block ? total - offset : block);
        if (read_block(source_fd, buffer, size, offset) < 0) { error = EIO; break; }
        size_t written = 0;
        while (written < size) {
            ssize_t n = pwrite(destination_fd, buffer + written, size - written, offset + written);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { error = errno ? errno : EIO; break; }
            written += n;
        }
        if (error) break;
        offset += size;
        if (callback && callback(context, offset)) { error = ECANCELED; break; }
    }
    free(buffer); return error;
}
int zc_metadata_fd(int source_fd, int destination_fd) {
    return fcopyfile(source_fd, destination_fd, NULL, COPYFILE_METADATA) == 0 ? 0 : (errno ? errno : EIO);
}
