using System.Buffers.Binary;
using ZstdSharp;
using ZstdSharp.Unsafe;

namespace Ryujinx.Nsz;

internal sealed class NczPayloadStream : Stream
{
    private readonly Stream _entry;
    private readonly NczLayout _layout;
    private readonly NszLimits _limits;
    private Stream? _current;
    private int _block;
    private long _storedOffset;
    private long _remainingBlock;
    private long _totalRead;
    private readonly CancellationToken _cancellation;
    public NczPayloadStream(Stream entry, NczLayout layout, NszLimits limits, CancellationToken cancellation)
    {
        _entry = entry; _layout = layout; _limits = limits; _cancellation = cancellation; _storedOffset = layout.PayloadOffset;
        if (layout.Blocks == null) _current = Zstd(new BoundedReadStream(entry, layout.PayloadOffset, entry.Length - layout.PayloadOffset), layout.PayloadSize);
    }
    private Stream Zstd(Stream stream, long expected)
    {
        ZstdFrameValidation.Validate(stream, expected, _limits, _cancellation);
        var decoded = new DecompressionStream(stream, bufferSize: 1 << 20, checkEndOfStream: true, leaveOpen: false);
        decoded.SetParameter(ZSTD_dParameter.ZSTD_d_windowLogMax, _limits.WindowLog);
        return decoded;
    }
    private void OpenBlock()
    {
        var b = _layout.Blocks!;
        _entry.Position = b.TableOffset + _block * 4L;
        Span<byte> size = stackalloc byte[4]; _entry.ReadExactly(size);
        uint stored = BinaryPrimitives.ReadUInt32LittleEndian(size);
        _remainingBlock = Math.Min(1L << b.Exponent, _layout.PayloadSize - _totalRead);
        var slice = new BoundedReadStream(_entry, _storedOffset, stored);
        _storedOffset += stored;
        _current = stored == _remainingBlock ? slice : Zstd(slice, _remainingBlock);
        _block++;
    }
    public override int Read(Span<byte> buffer)
    {
        if (buffer.Length == 0) return 0;
        if (_layout.Blocks == null) return _current!.Read(buffer);
        int copied = 0;
        while (copied < buffer.Length)
        {
            if (_current == null)
            {
                if (_block == _layout.Blocks.Count) break;
                OpenBlock();
            }
            int wanted = (int)Math.Min(buffer.Length - copied, _remainingBlock);
            int read = _current!.Read(buffer.Slice(copied, wanted));
            if (read == 0 && _remainingBlock > 0) throw new InvalidDataException("NCZ block output is truncated.");
            _remainingBlock -= read; _totalRead += read; copied += read;
            if (_remainingBlock == 0)
            {
                if (_current.ReadByte() != -1) throw new InvalidDataException("NCZ block produced excessive output.");
                _current.Dispose(); _current = null;
            }
        }
        return copied;
    }
    protected override void Dispose(bool disposing) { if (disposing) _current?.Dispose(); base.Dispose(disposing); }
    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => _layout.PayloadSize;
    public override long Position { get => _totalRead; set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
