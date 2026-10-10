using System.Buffers.Binary;
using System.Security.Cryptography;

namespace Ryujinx.Nsz;

public sealed class AesCtrTransform : IDisposable
{
    private readonly Aes _aes;
    private readonly ICryptoTransform _encryptor;
    private readonly byte[] _prefix;
    private readonly byte[] _counters = new byte[16 * 1024];
    private readonly byte[] _stream = new byte[16 * 1024];
    public AesCtrTransform(byte[] key, byte[] counter)
    {
        if (key.Length != 16 || counter.Length != 16) throw new ArgumentException("AES-CTR requires 16-byte inputs.");
        _prefix = counter[..8]; _aes = Aes.Create(); _aes.Key = key;
        _aes.Mode = CipherMode.ECB; _aes.Padding = PaddingMode.None;
        _encryptor = _aes.CreateEncryptor();
    }
    public void Apply(Span<byte> bytes, long absoluteOffset)
    {
        if (absoluteOffset < 0 || absoluteOffset > long.MaxValue - bytes.Length) throw new ArgumentOutOfRangeException(nameof(absoluteOffset));
        int done = 0;
        while (done < bytes.Length)
        {
            long position = absoluteOffset + done; int skip = (int)(position % 16);
            int count = Math.Min(bytes.Length - done, _stream.Length - skip);
            int blocks = (skip + count + 15) / 16;
            for (int b = 0; b < blocks; b++)
            {
                _prefix.CopyTo(_counters, b * 16);
                BinaryPrimitives.WriteUInt64BigEndian(_counters.AsSpan(b * 16 + 8), (ulong)(position / 16 + b));
            }
            _encryptor.TransformBlock(_counters, 0, blocks * 16, _stream, 0);
            for (int i = 0; i < count; i++) bytes[done + i] ^= _stream[skip + i];
            done += count;
        }
    }
    public void Dispose() { _encryptor.Dispose(); _aes.Dispose(); CryptographicOperations.ZeroMemory(_counters); CryptographicOperations.ZeroMemory(_stream); }
}
