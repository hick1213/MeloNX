#ifndef MELONX_SAVE_SYNC_H
#define MELONX_SAVE_SYNC_H
#include <stdint.h>
void *save_sync_create(const char *request_json, char **error);
int32_t save_sync_run(void *handle);
char *save_sync_result(void *handle);
char *save_sync_progress(void *handle);
void save_sync_request_stop(void *handle);
void save_sync_free(void *handle);
void save_sync_string_free(char *value);
#endif
