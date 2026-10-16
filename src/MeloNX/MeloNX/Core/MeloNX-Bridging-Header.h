//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//


#ifndef MeloNX_BridgingHeader_h
#define MeloNX_BridgingHeader_h

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <Foundation/Foundation.h>
#include <setjmp.h>
#include <stdbool.h>
#include <signal.h>
#include <stdint.h>
#include "MeloNXRPPairing.h"
#include "MeloNXNSZImport.h"
#include "MeloNXSaveSync.h"
#include "../Dependencies/BreakpointJIT.framework/Headers/BreakJIT.h"
#include <sys/sysctl.h>
#include <sys/proc.h>
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
static inline int melonx_jit_code_debugged(void) {
    uint32_t flags = 0;
    return csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & 0x10000000u) != 0;
}
// -1 is unknown, never treated as an untraced process.
static inline int melonx_jit_tracing_state(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info = {0};
    size_t length = sizeof(info);
    if (sysctl(mib, 4, &info, &length, NULL, 0) != 0 || length == 0) return -1;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}
#include "Models/Options/NativeOptions.h" 
#include "Memory/MLXRamDonor.h"
#include <IOKit/IOKitLib.h>

struct GameInfoC {
    long FileSize;
    char TitleName[512];
    char TitleId[32];
    char Developer[256];
    char Version[16];
    unsigned char* ImageData;
    unsigned int ImageSize;
};

struct DlcNcaListItemC {
    char Path[256];
    unsigned long long TitleId;
};

struct DlcNcaListC {
    bool success;
    unsigned int size;
    struct DlcNcaListItemC* items;
};

struct SaveDataPathC {
    bool success;
    char* value;
};

struct AvatarArrayC {
    int Count;
    struct AvatarInfoC* Avatars;
};

struct AvatarInfoC {
    unsigned char* ImageData;
    int ImageSize;
    char* FileName;
};



typedef void (*DataCallbackFn)(const void* data, void* userData);

typedef struct {
    void*   ptr;
    int32_t len;
} CallbackData;

void RegisterCallback(const char* name, DataCallbackFn callback, void* userData);
void UnregisterCallback(const char* name);

uint8_t InvokeCallback(const char* name, const void* data, int32_t len);

uint64_t execute_function_pointer(void* functionPtr);

void report_memory_pressure(uint8_t critical);

void offer_donated_memory(void* baseAddress, uint64_t size);

void withdraw_donated_memory(void);

uint8_t offer_donated_gpu_memory(void* baseAddress, uint64_t size);
uint8_t withdraw_donated_gpu_memory(void);
uint64_t execute_guest_function_pointer(void* functionPtr, void* nativeContextPtr);

#endif /* MeloNX_BridgingHeader_h */
