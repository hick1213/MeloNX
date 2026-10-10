using System.Buffers.Binary;

namespace Ryujinx.Nsz;

// Checks frame boundaries before invoking the decoder. Data frames can concatenate,
// but extra empty frames, dictionaries and bytes outside frames are not NCZ payload.
internal static class ZstdFrameValidation
{
    public static void Validate(Stream input, long expectedOutput, NszLimits limits, CancellationToken cancellation)
    {
        input.Position = 0;
        long? declaredTotal = 0;
        int frames = 0;
        Span<byte> number = stackalloc byte[8];
        while (input.Position < input.Length)
        {
            cancellation.ThrowIfCancellationRequested();
            if (++frames > limits.MaxBlocks) throw new InvalidDataException("Too many Zstandard frames.");
            Read(input, number[..4]);
            if (BinaryPrimitives.ReadUInt32LittleEndian(number) != 0xfd2fb528)
                throw new InvalidDataException("Invalid or trailing Zstandard frame data.");
            int descriptor = Byte(input);
            if ((descriptor & 8) != 0) throw new InvalidDataException("Reserved Zstandard flag is set.");
            bool single = (descriptor & 32) != 0;
            if (!single)
            {
                int wd = Byte(input); int log = 10 + (wd >> 3);
                ulong window = (1UL << log) + ((1UL << log) / 8) * (uint)(wd & 7);
                if (window > (1UL << limits.WindowLog)) throw new InvalidDataException("Zstandard window exceeds memory limit.");
            }
            int dictionarySize = (descriptor & 3) switch { 0 => 0, 1 => 1, 2 => 2, _ => 4 };
            number.Clear(); Read(input, number[..dictionarySize]);
            if (BinaryPrimitives.ReadUInt64LittleEndian(number) != 0) throw new InvalidDataException("External Zstandard dictionaries are not supported.");
            int sizeLength = (descriptor >> 6) switch { 0 => single ? 1 : 0, 1 => 2, 2 => 4, _ => 8 };
            number.Clear(); Read(input, number[..sizeLength]);
            ulong size = BinaryPrimitives.ReadUInt64LittleEndian(number) + (sizeLength == 2 ? 256UL : 0UL);
            if (sizeLength != 0)
            {
                if (size == 0 || size > (ulong)expectedOutput || (single && size > (1UL << limits.WindowLog)))
                    throw new InvalidDataException("Invalid Zstandard output size or memory requirement.");
                if (declaredTotal.HasValue) declaredTotal = checked(declaredTotal.Value + (long)size);
            }
            else declaredTotal = null;
            bool last;
            do
            {
                cancellation.ThrowIfCancellationRequested();
                number.Clear(); Read(input, number[..3]);
                uint header = BinaryPrimitives.ReadUInt32LittleEndian(number);
                last = (header & 1) != 0;
                uint type = (header >> 1) & 3, length = header >> 3;
                if (type == 3 || length > 128 * 1024) throw new InvalidDataException("Invalid Zstandard block.");
                Skip(input, type == 1 ? 1 : length);
            } while (!last);
            if ((descriptor & 4) != 0) Skip(input, 4);
        }
        if (frames == 0 || (declaredTotal.HasValue && declaredTotal != expectedOutput))
            throw new InvalidDataException("Zstandard frames do not match expected output length.");
        input.Position = 0;
    }
    private static int Byte(Stream input) { int value = input.ReadByte(); return value >= 0 ? value : throw new InvalidDataException("Truncated Zstandard header."); }
    private static void Read(Stream input, Span<byte> bytes) {
        try { input.ReadExactly(bytes); } catch (EndOfStreamException) { throw new InvalidDataException("Truncated Zstandard frame."); }
    }
    private static void Skip(Stream input, long size) {
        if (size > input.Length - input.Position) throw new InvalidDataException("Zstandard block exceeds entry.");
        input.Position += size;
    }
}
