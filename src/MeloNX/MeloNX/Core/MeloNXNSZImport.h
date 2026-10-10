#ifndef MELONX_NSZ_IMPORT_H
#define MELONX_NSZ_IMPORT_H
#include <stdint.h>
typedef struct {
    uint32_t version;
    int32_t phase;
    int64_t completed;
    int64_t total;
    int32_t status;
    int32_t kind;
    uint64_t application_id;
    uint64_t content_id;
} MeloNXNSZProgress;
_Static_assert(sizeof(MeloNXNSZProgress) == 48, "NSZ ABI layout mismatch");
void *nsz_import_create(const char *request_json, char **error);
int32_t nsz_import_run(void *handle);
int32_t nsz_import_progress(void *handle, MeloNXNSZProgress *snapshot);
void nsz_import_cancel(void *handle);
char *nsz_import_result(void *handle);
void nsz_import_free(void *handle);
void nsz_import_string_free(char *value);
#if DEBUG
char *nsz_conversion_probe(const char *source_path, const char *output_path);
#endif
#endif
