using System;

namespace Ryujinx.Graphics.Gpu.Image
{
    internal static class UnifiedTextureCacheBudget
    {
        internal static ulong Calculate(ulong reportedUnifiedHeap, ulong fallbackCpuMemory, int requestedMiB = 0)
        {
            const ulong mib = 1024 * 1024;
            if (requestedMiB >= 256 && requestedMiB <= 4096)
            {
                ulong hostMemory = reportedUnifiedHeap != 0 ? reportedUnifiedHeap : fallbackCpuMemory;
                // Larger known Apple heaps permit an explicit 4 GiB retention cap.
                // Smaller and unknown heaps keep the previous manual device budget.
                ulong deviceLimit = reportedUnifiedHeap >= 10UL * 1024 * mib
                    ? Math.Clamp(hostMemory / 2, 256 * mib, 4096 * mib)
                    : Math.Clamp(hostMemory / 4, 256 * mib, 2048 * mib);
                return Math.Min((ulong)requestedMiB * mib, deviceLimit);
            }

            // Apple exposes unified device memory as a GPU heap; this is not free memory.
            // Larger known heaps may retain up to 1 GiB. This is a retention cap,
            // not a reservation; small devices and unknown heaps keep the old policy.
            if (reportedUnifiedHeap >= 10UL * 1024 * mib)
            {
                return Math.Clamp(reportedUnifiedHeap / 10, 256 * mib, 1024 * mib);
            }

            ulong memory = reportedUnifiedHeap != 0 ? reportedUnifiedHeap : fallbackCpuMemory;
            return Math.Clamp(memory / 16, 256 * mib, 768 * mib);
        }
    }
}
