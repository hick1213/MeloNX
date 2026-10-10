// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Madeira; see distribution/legal/Madeira-JIT-EXCEPTION.md
//
// On-device remote pairing (iOS 27 and later): build/rppairing-ios, linked as
// libmelonx_rppairing.a. Keep in step with build/rppairing-ios/src/lib.rs.

#ifndef MELONX_RPPAIRING_H
#define MELONX_RPPAIRING_H

#include <stddef.h>
#include <stdint.h>

int32_t melonx_rppairing_validate_auth_tag(const uint8_t *alt_irk, size_t alt_irk_len, const char *identifier, const char *auth_tag);

typedef struct MeloNXRPPairing MeloNXRPPairing;
typedef void (*MeloNXRPPairingPinCallback)(const char *pin, void *context);

/// New host identity and a listener on all IPv4 interfaces. NULL on failure,
/// with *error set (free with melonx_rppairing_string_free).
MeloNXRPPairing *melonx_rppairing_new(const char *name, char **error);
uint16_t melonx_rppairing_port(const MeloNXRPPairing *session);
/// The Bonjour instance name to publish; owned by the session.
const char *melonx_rppairing_service_name(const MeloNXRPPairing *session);
size_t melonx_rppairing_txt_count(const MeloNXRPPairing *session);
const char *melonx_rppairing_txt_key(const MeloNXRPPairing *session, size_t index);
const char *melonx_rppairing_txt_value(const MeloNXRPPairing *session, size_t index);
/// Blocks until paired (0), failed (1, *error set) or cancelled (2). On success
/// *out_plist/*out_len hold the RPPairing plist (melonx_rppairing_bytes_free)
/// and *out_device_name the device's name (melonx_rppairing_string_free).
int32_t melonx_rppairing_accept(const MeloNXRPPairing *session,
                                 MeloNXRPPairingPinCallback pin_callback, void *pin_context,
                                 uint8_t **out_plist, size_t *out_len,
                                 char **out_device_name, char **error);
/// Ends a running or future accept with 2. Any thread.
void melonx_rppairing_cancel(const MeloNXRPPairing *session);
/// Only after accept has returned (or was never called).
void melonx_rppairing_free(MeloNXRPPairing *session);
void melonx_rppairing_bytes_free(uint8_t *bytes, size_t len);
void melonx_rppairing_string_free(char *string);

#endif
