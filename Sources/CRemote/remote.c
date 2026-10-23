#include "CRemote.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
struct transfer { int fd, upload; int64_t expected, written; char *data; size_t length; zr_progress progress; void *context; };
static size_t receive(char *data, size_t unit, size_t count, void *raw) {
    struct transfer *t = raw;
    if (unit && count > SIZE_MAX / unit) return 0;
    size_t size = unit * count;
    if (t->fd < 0 || t->upload) {
        if (size > 8 * 1024 * 1024 - t->length) return 0;
        char *next = realloc(t->data, t->length + size + 1);
        if (!next) return 0;
        t->data = next; memcpy(next + t->length, data, size); t->length += size; next[t->length] = 0;
    } else {
        if (t->expected < t->written || size > (uint64_t)(t->expected - t->written)) return 0;
        size_t offset = 0;
        while (offset < size) {
            ssize_t n = write(t->fd, data + offset, size - offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return 0;
            offset += n;
        }
        t->written += size;
    }
    return size;
}
static size_t send_data(char *data, size_t unit, size_t count, void *raw) {
    struct transfer *t = raw;
    if (unit && count > SIZE_MAX / unit) return CURL_READFUNC_ABORT;
    ssize_t n;
    do { n = read(t->fd, data, unit * count); } while (n < 0 && errno == EINTR);
    return n < 0 ? CURL_READFUNC_ABORT : (size_t)n;
}
static int progress(void *raw, curl_off_t total_down, curl_off_t down, curl_off_t total_up, curl_off_t up) {
    (void)total_down; (void)total_up;
    struct transfer *t = raw;
    return t->progress ? t->progress(t->context, t->upload ? up : down) : 0;
}
int zr_request(const char *url, const char *user, const char *password, int tls,
               const char *ca, int operation, const char *command, const char *second_command, int fd, int64_t size,
               char **text, size_t *length, char *error, size_t error_size,
               zr_progress callback, void *context) {
    pthread_once(&once, initialize);
    CURL *curl = curl_easy_init();
    if (!curl) return CURLE_FAILED_INIT;
    struct transfer t = {fd, operation == 2, size, 0, NULL, 0, callback, context};
    char detail[CURL_ERROR_SIZE] = {0};
    struct curl_slist *quote = NULL;
    CURLcode result = CURLE_OK;
#define SET(option,value) do { result = curl_easy_setopt(curl,option,value); if (result) goto finish; } while (0)
    SET(CURLOPT_URL, url); SET(CURLOPT_USERNAME, user); SET(CURLOPT_PASSWORD, password);
    SET(CURLOPT_ERRORBUFFER, detail); SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_CONNECTTIMEOUT, 15L); SET(CURLOPT_FTP_RESPONSE_TIMEOUT, 30L);
    SET(CURLOPT_LOW_SPEED_LIMIT, 1L); SET(CURLOPT_LOW_SPEED_TIME, 60L);
    SET(CURLOPT_FOLLOWLOCATION, 0L); SET(CURLOPT_FAILONERROR, 1L);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    SET(CURLOPT_PROTOCOLS, (long)(CURLPROTO_FTP | CURLPROTO_FTPS));
#pragma clang diagnostic pop
    SET(CURLOPT_SSL_VERIFYPEER, 1L); SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_USE_SSL, (long)(tls ? CURLUSESSL_ALL : CURLUSESSL_NONE));
    if (ca && *ca) { SET(CURLOPT_CAINFO, ca); }
    SET(CURLOPT_NOPROGRESS, 0L); SET(CURLOPT_XFERINFOFUNCTION, progress); SET(CURLOPT_XFERINFODATA, &t);
    SET(CURLOPT_WRITEFUNCTION, receive); SET(CURLOPT_WRITEDATA, &t);
    if (operation == 0 && command && *command) { SET(CURLOPT_CUSTOMREQUEST, command); }
    if (operation == 2) {
        SET(CURLOPT_UPLOAD, 1L); SET(CURLOPT_READFUNCTION, send_data); SET(CURLOPT_READDATA, &t);
        SET(CURLOPT_INFILESIZE_LARGE, (curl_off_t)size);
    }
    if (operation == 3) {
        quote = curl_slist_append(NULL, command);
        if (!quote) { result = CURLE_OUT_OF_MEMORY; goto finish; }
        if (second_command && *second_command) {
            struct curl_slist *next = curl_slist_append(quote, second_command);
            if (!next) { result = CURLE_OUT_OF_MEMORY; goto finish; }
            quote = next;
        }
        SET(CURLOPT_QUOTE, quote); SET(CURLOPT_NOBODY, 1L);
    }
    result = curl_easy_perform(curl);
finish:
    if (text) { *text = t.data; } else { free(t.data); }
    if (length) *length = t.length;
    if (error && error_size) snprintf(error, error_size, "%s", *detail ? detail : curl_easy_strerror(result));
    curl_slist_free_all(quote); curl_easy_cleanup(curl);
    return result;
}
void zr_free(void *pointer) { free(pointer); }
