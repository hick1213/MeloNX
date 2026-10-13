using System;

namespace Ryujinx.Graphics.Gpu.Image
{
    internal static class UnifiedTextureCacheBudget
    {
        internal static ulong Calculate(ulong reportedUnifiedHeap, ulong fallbackCpuMemory)
        {
            const ulong mib = 1024 * 1024;
            // Apple exposes unified device memory as a GPU heap; this is not free memory.
            ulong memory = reportedUnifiedHeap != 0 ? reportedUnifiedHeap : fallbackCpuMemory;
            return Math.Clamp(memory / 16, 256 * mib, 768 * mib);
        }
    }
}
