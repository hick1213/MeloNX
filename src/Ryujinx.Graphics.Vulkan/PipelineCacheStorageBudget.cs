using System;

namespace Ryujinx.Graphics.Vulkan
{
    internal static class PipelineCacheStorageBudget
    {
        public static long GetMaximumSize(bool isApple, ulong deviceLocalMemory)
        {
            // The shared cache can exceed 128 MiB after several games. Keep its
            // serialized copies bounded, with extra room only on known large Apple heaps.
            return isApple && deviceLocalMemory >= 10UL * 1024 * 1024 * 1024
                ? Math.Min(2L * 1024 * 1024 * 1024, Array.MaxLength)
                : 128L * 1024 * 1024;
        }

        public static bool IsSizeAllowed(ulong size, long maximumSize)
        {
            return size > 0 && size <= (ulong)maximumSize && size <= (ulong)Array.MaxLength;
        }
    }
}
