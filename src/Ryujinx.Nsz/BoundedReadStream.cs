namespace Ryujinx.Nsz;

internal sealed class BoundedReadStream : Stream
{
    private readonly Stream _source;
    private readonly long _start;
    private readonly long _length;
    private long _position;
    public BoundedReadStream(Stream source, long start, long length)
    {
        if (!source.CanRead || !source.CanSeek || start < 0 || length < 0 || start > source.Length || length > source.Length - start)
            throw new InvalidDataException("Invalid bounded input range.");
        _source = source; _start = start; _length = length;
    }
    public override int Read(Span<byte> buffer)
    {
        int amount = (int)Math.Min(buffer.Length, _length - _position);
        if (amount == 0) return 0;
        long absolute = checked(_start + _position);
        if (_source.Position != absolute) _source.Position = absolute;
        int read = _source.Read(buffer[..amount]);
        _position += read;
        return read;
    }
    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
    public override long Position {
        get => _position;
        set { if (value < 0 || value > _length) throw new InvalidDataException("Seek exceeds input range."); _position = value; }
    }
    public override long Seek(long offset, SeekOrigin origin) {
        Position = checked((origin switch { SeekOrigin.Begin => 0, SeekOrigin.Current => _position, SeekOrigin.End => _length, _ => throw new ArgumentException("Invalid seek origin.") }) + offset);
        return Position;
    }
    public override long Length => _length;
    public override bool CanRead => true;
    public override bool CanSeek => true;
    public override bool CanWrite => false;
    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    // Underlying source belongs to the caller, including for nested entry slices.
}
