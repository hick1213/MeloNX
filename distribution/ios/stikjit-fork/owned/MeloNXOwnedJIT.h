// SPDX-License-Identifier: MPL-2.0
#include <stddef.h>
#include <stdint.h>
typedef struct MeloNXOwnedDebugSession MeloNXOwnedDebugSession;
MeloNXOwnedDebugSession *melonx_owned_debug_new(const uint8_t *, size_t, const char *, uint16_t);
MeloNXOwnedDebugSession *melonx_owned_debug_diagnostic_new(void);
int32_t melonx_owned_debug_command(const MeloNXOwnedDebugSession *, uint8_t, const char *, char **);
int32_t melonx_owned_debug_cancel(const MeloNXOwnedDebugSession *);
int32_t melonx_owned_debug_finish(const MeloNXOwnedDebugSession *);
void melonx_owned_debug_free(MeloNXOwnedDebugSession *);
void melonx_owned_debug_string_free(char *);
