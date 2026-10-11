using System.Runtime.InteropServices;

namespace Ryujinx.SaveSync;

internal static class DarwinDurability
{
    [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint = "open", SetLastError = true)]
    private static extern int Open([MarshalAs(UnmanagedType.LPUTF8Str)] string path, int flags);
    [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint = "fsync", SetLastError = true)]
    private static extern int Sync(int fd);
    [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint = "close", SetLastError = true)]
    private static extern int Close(int fd);
    public static void SyncDirectory(string path)
    {
        if (!DarwinFileNodes.RequireFileOrDirectory(path)) throw new IOException("Directory synchronization failed.");
        int fd = Open(path, 0x00100000 | 0x00000100); // O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        if (fd < 0) throw new IOException("Directory synchronization failed.");
        try { if (Sync(fd) != 0) throw new IOException("Directory synchronization failed."); }
        finally { _ = Close(fd); }
    }
    public static void SyncFile(string path)
    {
        DarwinFileNodes.RequireRegular(path);
        int fd = Open(path, 0x00000100); // O_RDONLY | O_NOFOLLOW
        if (fd < 0) throw new IOException("File synchronization failed.");
        try { if (Sync(fd) != 0) throw new IOException("File synchronization failed."); }
        finally { _ = Close(fd); }
    }
}
