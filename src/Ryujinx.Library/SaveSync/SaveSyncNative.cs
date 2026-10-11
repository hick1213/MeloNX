#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Ryujinx.SaveSync;

namespace Ryujinx.Library.SaveSync;

internal static class SaveSyncNative
{
    private sealed record Captured(SaveContext Context, SaveSelection Selection);
    private static readonly object Gate = new();
    private static readonly Dictionary<nint, SaveSyncJob> Jobs = [];
    private static readonly Dictionary<Guid, Captured> Selections = [];
    private static readonly HashSet<nint> Strings = [];
    private static long _nextHandle;

    private static nint Allocate(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > 65536) throw new SaveSyncException("invalid_result");
        nint pointer = Marshal.StringToCoTaskMemUTF8(text);
        lock (Gate) Strings.Add(pointer);
        return pointer;
    }
    [UnmanagedCallersOnly(EntryPoint = "save_sync_create")]
    public static unsafe nint Create(byte* json, nint* error)
    {
        if (error != null) *error = 0;
        try
        {
            if (json == null) throw new SaveSyncException("invalid_request");
            int size = 0; while (size <= 65536 && json[size] != 0) size++;
            if (size > 65536) throw new SaveSyncException("invalid_request");
            var request = SaveNativeJson.ParseRequest(new ReadOnlySpan<byte>(json, size));
            lock (Gate)
            {
                if (Jobs.Count != 0) throw new SaveSyncException("busy");
                nint handle = (nint)System.Threading.Interlocked.Increment(ref _nextHandle);
                Jobs.Add(handle, new SaveSyncJob(request, worker => Perform(request, worker))); return handle;
            }
        }
        catch (Exception exception)
        {
            try { if (error != null) *error = Allocate(exception is SaveSyncException known ? known.Code : "save_unavailable"); } catch { }
            return 0;
        }
    }
    [UnmanagedCallersOnly(EntryPoint = "save_sync_run")]
    public static int Run(nint handle)
    {
        try { SaveSyncJob? job; lock (Gate) Jobs.TryGetValue(handle, out job); return job?.Run() ?? 2; }
        catch { return 2; }
    }
    [UnmanagedCallersOnly(EntryPoint = "save_sync_request_stop")]
    public static void Stop(nint handle) { try { lock (Gate) { if (Jobs.TryGetValue(handle, out var job)) job.RequestSafeStop(); } } catch { } }
    [UnmanagedCallersOnly(EntryPoint = "save_sync_result")]
    public static nint Result(nint handle)
    {
        try { lock (Gate) { return Jobs.TryGetValue(handle, out var job) && job.ResultJson() is string json ? Allocate(json) : 0; } }
        catch { return 0; }
    }
    [UnmanagedCallersOnly(EntryPoint = "save_sync_progress")]
    public static nint Progress(nint handle)
    {
        try { lock (Gate) { return Jobs.TryGetValue(handle, out var job) ? Allocate(job.ProgressJson()) : 0; } }
        catch { return 0; }
    }
    [UnmanagedCallersOnly(EntryPoint = "save_sync_free")]
    public static void Free(nint handle) { try { lock (Gate) { if (Jobs.TryGetValue(handle, out var job) && job.TryFree()) Jobs.Remove(handle); } } catch { } }
    [UnmanagedCallersOnly(EntryPoint = "save_sync_string_free")]
    public static void StringFree(nint pointer) { try { lock (Gate) { if (Strings.Remove(pointer)) Marshal.FreeCoTaskMem(pointer); } } catch { } }

    private static SaveNativeResult Perform(SaveNativeRequest request, SaveSyncJob worker)
    {
        if (worker.StopRequested) throw new OperationCanceledException();
        if (request.Operation == "describe")
        {
            var context = Library.CreateSaveContext();
            var selection = context.ReadCurrentSaveSelection(request.TitleID, request.GamePath!);
            lock (Gate)
            {
                if (Selections.Count >= 64) Selections.Clear();
                Selections[selection.Id] = new(context, selection);
            }
            return new(1, request.Id, 0, new(selection.Id, selection.TitleId, selection.LocalUserId, selection.Keys, selection.Control is not null), null, null, [], [], null);
        }
        if (request.Operation is "recover" or "ack_binding")
        {
            var context = Library.CreateSaveContext();
            var transaction = new SaveRestoreTransaction(context.Repository, new DurableFileStore(Path.GetDirectoryName(Path.GetDirectoryName(context.OwnedRoot))!), context.OwnedRoot);
            worker.SetStopHandler(transaction.RequestSafeStop);
            if (request.Operation == "ack_binding")
            {
                transaction.CompleteBinding(request.TransactionID!.Value);
                return new(1, request.Id, 0, null, null, null, [], [], null);
            }
            worker.Progress("recovering", 0, 0);
            var outcomes = transaction.RecoverIncomplete();
            var blocked = outcomes.SelectMany(o => o.BlockedGames).Distinct().ToArray();
            var completed = outcomes.Where(o => o.CompletedBinding is not null).Select(o => new SaveCompletedBinding(o.TransactionId, o.CompletedBinding!)).ToArray();
            return new(1, request.Id, blocked.Length == 0 ? 0 : 3, null, null, null, completed, blocked, blocked.Length == 0 ? null : "rollbackRequired");
        }
        Captured captured;
        lock (Gate) { if (!request.SelectionID.HasValue || !Selections.TryGetValue(request.SelectionID.Value, out captured!)) throw new SaveSyncException("identityMismatch"); }
        string root = captured.Context.OwnedRoot;
        Guid generation = request.Operation == "export" ? request.ExportIdentity!.Generation : SaveNativePaths.ReadRestoreIntent(request, root).Generation;
        string expected = Path.Combine(root, "staging", generation.ToString("D"));
        if (Path.GetFullPath(request.SnapshotRoot!) != Path.GetFullPath(expected)) throw new SaveSyncException("invalid_request");
        if (request.Operation == "export")
        {
            worker.Progress("exporting", 0, 0);
            var snapshot = captured.Context.ExportSelection(captured.Selection, request.ExportIdentity!, request.SnapshotRoot!, worker.Cancellation);
            return new(1, request.Id, worker.StopRequested ? 1 : 0, null, request.SnapshotRoot, snapshot, [], [], null);
        }
        var intent = SaveNativePaths.ReadRestoreIntent(request, root);
        if (Path.GetFullPath(request.BindingIntentFile!) != Path.Combine(expected, "binding-intent.json")) throw new SaveSyncException("invalid_request");
        var current = captured.Context.ValidateCurrentSelection(captured.Selection);
        var restore = new SaveRestoreTransaction(captured.Context.Repository, new DurableFileStore(Path.GetDirectoryName(Path.GetDirectoryName(root))!), root,
            observer: (stage, key) => worker.Progress(stage.ToString(), key is null ? 0 : key.Index, current.Keys.Count));
        worker.SetStopHandler(restore.RequestSafeStop);
        var result = restore.Run(current, request.SnapshotRoot!, intent);
        lock (Gate) Selections.Remove(captured.Selection.Id);
        return new(1, request.Id, result.Status == RestoreStatus.Completed ? 0 : result.Status == RestoreStatus.RolledBack ? 1 : 3,
            null, null, null, result.CompletedBinding is null ? [] : [new(result.TransactionId, result.CompletedBinding)], result.BlockedGames.ToArray(),
            result.Status == RestoreStatus.RecoveryRequired ? "rollbackRequired" : null);
    }
}
