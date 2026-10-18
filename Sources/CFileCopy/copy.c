#include "CFileCopy.h"
#include <copyfile.h>
#include <errno.h>
#include <sys/types.h>

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
