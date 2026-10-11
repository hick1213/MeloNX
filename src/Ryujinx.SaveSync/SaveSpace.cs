namespace Ryujinx.SaveSync;

public static class SaveSpace
{
    public const long Margin = 256L * 1024 * 1024;
    public static long Available(string path)
    {
        string full = Path.GetFullPath(path);
        var drive = DriveInfo.GetDrives().Where(d => full.StartsWith(d.Name.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            .OrderByDescending(d => d.Name.Length).FirstOrDefault();
        if (drive is null) throw new SaveSyncException("insufficientSpace");
        return drive.AvailableFreeSpace;
    }
    public static void Require(long available, long needed)
    {
        if (needed < 0 || needed > long.MaxValue - Margin || available < needed + Margin) throw new SaveSyncException("insufficientSpace");
    }
}
