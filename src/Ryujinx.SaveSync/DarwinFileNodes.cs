using System.Runtime.InteropServices;

namespace Ryujinx.SaveSync;

internal static class DarwinFileNodes
{
    // Darwin stat64: dev_t at0, mode_t at4. Extra storage accommodates the
    // complete native stat structure; no platform-sized fields are marshalled.
    [StructLayout(LayoutKind.Explicit, Size = 256)]
    private struct StatBuffer { [FieldOffset(4)] public ushort Mode; }
    [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint = "lstat$INODE64", SetLastError = true)]
    private static extern int MacStat([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out StatBuffer info);
    [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint = "lstat", SetLastError = true)]
    private static extern int IosStat([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out StatBuffer info);
    public static bool RequireFileOrDirectory(string path)
    {
        StatBuffer info;
        int result = OperatingSystem.IsMacOS() && RuntimeInformation.ProcessArchitecture == Architecture.X64 ? MacStat(path, out info) :
            OperatingSystem.IsMacOS() || OperatingSystem.IsIOS() ? IosStat(path, out info) : throw new SaveSyncException("unsupportedPlatform");
        if (result != 0) throw new SaveSyncException("malformedSnapshot");
        int type = info.Mode & 0xf000;
        return type switch { 0x4000 => true, 0x8000 => false, _ => throw new SaveSyncException("malformedSnapshot") };
    }
    public static void RequireRegular(string path)
    {
        if (RequireFileOrDirectory(path)) throw new SaveSyncException("malformedSnapshot");
    }
}
