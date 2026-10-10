using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Ryujinx.Common.Configuration;
using Ryujinx.Nsz;

namespace Ryujinx.Library.Compression;

internal static class NszImportNative
{
    private sealed class Entry(NszImportSession session, NszPackageValidator validator)
    {
        public readonly NszImportSession Session = session;
        public readonly NszPackageValidator Validator = validator;
        public GCHandle Handle;
        public bool Active;
    }
    private static readonly object Gate = new();
    private static readonly Dictionary<nint, Entry> Entries = new();

    [UnmanagedCallersOnly(EntryPoint = "nsz_import_create")]
    public static unsafe nint Create(byte* requestJson, nint* error)
    {
        if (error != null) *error = 0;
        try
        {
            if (requestJson == null) throw new ArgumentException();
            int length = 0;
            while (length <= 65536 && requestJson[length] != 0) length++;
            if (length > 65536) throw new ArgumentException();
            var request = NszRequestJson.Parse(new UTF8Encoding(false, true).GetString(new ReadOnlySpan<byte>(requestJson, length)));
            string expected = request.ExpectedKind switch
            {
                NszPackageKind.Application => Path.Combine(AppDataManager.BaseDirPath, "roms"),
                NszPackageKind.Patch => Path.Combine(AppDataManager.BaseDirPath, "updates", request.ExpectedApplicationId!.Value.ToString("x16")),
                NszPackageKind.AddOnContent => Path.Combine(AppDataManager.BaseDirPath, "dlc", request.ExpectedApplicationId!.Value.ToString("x16")),
                _ => throw new ArgumentException()
            };
            if (Path.GetFullPath(request.TargetRoot).TrimEnd(Path.DirectorySeparatorChar) != Path.GetFullPath(expected).TrimEnd(Path.DirectorySeparatorChar))
                throw new ArgumentException();
            lock (Gate)
            {
                if (Entries.Count != 0) { if (error != null) *error = NszUtf8Buffers.Allocate("busy"); return 0; }
                NszImportJob.CleanupStaleImports(expected);
                var validator = new NszPackageValidator(Library.SnapshotImportKeys());
                try
                {
                    var job = new NszImportJob(request, validator, new(), () => new DriveInfo(AppDataManager.BaseDirPath).AvailableFreeSpace);
                    var entry = new Entry(new NszImportSession(job), validator);
                    entry.Handle = GCHandle.Alloc(entry); nint pointer = GCHandle.ToIntPtr(entry.Handle);
                    Entries.Add(pointer, entry); return pointer;
                }
                catch { validator.Dispose(); throw; }
            }
        }
        catch (Exception exception)
        {
            if (error != null) *error = NszUtf8Buffers.Allocate(exception is ArgumentException or DecoderFallbackException ? "invalid_request" : "import_unavailable");
            return 0;
        }
    }
    [UnmanagedCallersOnly(EntryPoint = "nsz_import_run")]
    public static int Run(nint handle)
    {
        Entry entry;
        try
        {
            lock (Gate)
            {
                if (!Entries.TryGetValue(handle, out entry) || entry.Active) return 2;
                entry.Active = true;
            }
            try { return entry.Session.Run(); }
            finally { lock (Gate) entry.Active = false; }
        }
        catch { return 2; }
    }
    [UnmanagedCallersOnly(EntryPoint = "nsz_import_progress")]
    public static unsafe int Progress(nint handle, NszNativeProgress* progress)
    {
        if (progress == null) return 2;
        try { lock (Gate) { if (!Entries.TryGetValue(handle, out var entry)) return 2; *progress = entry.Session.Progress(); return 0; } }
        catch { return 2; }
    }
    [UnmanagedCallersOnly(EntryPoint = "nsz_import_cancel")]
    public static void Cancel(nint handle)
    {
        try { lock (Gate) { if (Entries.TryGetValue(handle, out var entry)) entry.Session.Cancel(); } }
        catch { }
    }
    [UnmanagedCallersOnly(EntryPoint = "nsz_import_result")]
    public static nint Result(nint handle)
    {
        try { lock (Gate) { if (!Entries.TryGetValue(handle, out var entry)) return 0; string json = entry.Session.ResultJson(); return json == null ? 0 : NszUtf8Buffers.Allocate(json); } }
        catch { return 0; }
    }
    [UnmanagedCallersOnly(EntryPoint = "nsz_import_free")]
    public static void Free(nint handle)
    {
        try
        {
            lock (Gate)
            {
                if (!Entries.TryGetValue(handle, out var entry) || entry.Active) return;
                entry.Session.Dispose(); entry.Validator.Dispose(); Entries.Remove(handle); entry.Handle.Free();
            }
        }
        catch { }
    }
    [UnmanagedCallersOnly(EntryPoint = "nsz_import_string_free")]
    public static void StringFree(nint value) { try { NszUtf8Buffers.Free(value); } catch { } }
}
