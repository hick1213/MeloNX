using Ryujinx.Graphics.Shader;
using System.Reflection;
using NUnit.Framework;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Memory.Range;
using GpuTexture = Ryujinx.Graphics.Gpu.Image.Texture;

namespace Ryujinx.SaveSync.Tests;

[NonParallelizable]
public class TextureScalingStateTests
{
    private sealed class PipelineRecorder : IPipeline
    {
        public int RenderTargetSets;
        public ITexture[] Colors = [];
        public ITexture? Depth;
        public ITexture? SampledTexture;
        public ITexture? Image;
        public int TextureSets;
        public int ImageSets;
        public void Barrier() => throw new NotSupportedException();
        public void BeginTransformFeedback(PrimitiveTopology topology) => throw new NotSupportedException();
        public void ClearBuffer(BufferHandle destination, int offset, int size, uint value) => throw new NotSupportedException();
        public void ClearRenderTargetColor(int index, int layer, int layerCount, uint componentMask, ColorF color) => throw new NotSupportedException();
        public void ClearRenderTargetDepthStencil(int layer, int layerCount, float depthValue, bool depthMask, int stencilValue, int stencilMask) => throw new NotSupportedException();
        public void CommandBufferBarrier() => throw new NotSupportedException();
        public void CopyBuffer(BufferHandle source, BufferHandle destination, int srcOffset, int dstOffset, int size) => throw new NotSupportedException();
        public void DispatchCompute(int groupsX, int groupsY, int groupsZ) => throw new NotSupportedException();
        public void Draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance) => throw new NotSupportedException();
        public void DrawIndexed(int indexCount, int instanceCount, int firstIndex, int firstVertex, int firstInstance) => throw new NotSupportedException();
        public void DrawIndexedIndirect(BufferRange indirectBuffer) => throw new NotSupportedException();
        public void DrawIndexedIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride) => throw new NotSupportedException();
        public void DrawIndirect(BufferRange indirectBuffer) => throw new NotSupportedException();
        public void DrawIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride) => throw new NotSupportedException();
        public void DrawTexture(ITexture texture, ISampler sampler, Extents2DF srcRegion, Extents2DF dstRegion) => throw new NotSupportedException();
        public void EndTransformFeedback() => throw new NotSupportedException();
        public void SetAlphaTest(bool enable, float reference, CompareOp op) => throw new NotSupportedException();
        public void SetBlendState(AdvancedBlendDescriptor blend) => throw new NotSupportedException();
        public void SetBlendState(int index, BlendDescriptor blend) => throw new NotSupportedException();
        public void SetDepthBias(PolygonModeMask enables, float factor, float units, float clamp) => throw new NotSupportedException();
        public void SetDepthClamp(bool clamp) => throw new NotSupportedException();
        public void SetDepthMode(DepthMode mode) => throw new NotSupportedException();
        public void SetDepthTest(DepthTestDescriptor depthTest) => throw new NotSupportedException();
        public void SetFaceCulling(bool enable, Face face) => throw new NotSupportedException();
        public void SetFrontFace(FrontFace frontFace) => throw new NotSupportedException();
        public void SetIndexBuffer(BufferRange buffer, IndexType type) => throw new NotSupportedException();
        public void SetImage(ShaderStage stage, int binding, ITexture texture) { ImageSets++; Image = texture; }
        public void SetImageArray(ShaderStage stage, int binding, IImageArray array) => throw new NotSupportedException();
        public void SetImageArraySeparate(ShaderStage stage, int setIndex, IImageArray array) => throw new NotSupportedException();
        public void SetLineParameters(float width, bool smooth) => throw new NotSupportedException();
        public void SetLogicOpState(bool enable, LogicalOp op) => throw new NotSupportedException();
        public void SetMultisampleState(MultisampleDescriptor multisample) => throw new NotSupportedException();
        public void SetPatchParameters(int vertices, ReadOnlySpan<float> defaultOuterLevel, ReadOnlySpan<float> defaultInnerLevel) => throw new NotSupportedException();
        public void SetPointParameters(float size, bool isProgramPointSize, bool enablePointSprite, Origin origin) => throw new NotSupportedException();
        public void SetPolygonMode(PolygonMode frontMode, PolygonMode backMode) => throw new NotSupportedException();
        public void SetPrimitiveRestart(bool enable, int index) => throw new NotSupportedException();
        public void SetPrimitiveTopology(PrimitiveTopology topology) => throw new NotSupportedException();
        public void SetProgram(IProgram program) => throw new NotSupportedException();
        public void SetRasterizerDiscard(bool discard) => throw new NotSupportedException();
        public void SetRenderTargetColorMasks(ReadOnlySpan<uint> componentMask) => throw new NotSupportedException();
        public void SetRenderTargets(Span<ITexture> colors, ITexture depthStencil) { RenderTargetSets++; Colors = colors.ToArray(); Depth = depthStencil; }
        public void SetScissors(ReadOnlySpan<Rectangle<int>> regions) => throw new NotSupportedException();
        public void SetStencilTest(StencilTestDescriptor stencilTest) => throw new NotSupportedException();
        public void SetStorageBuffers(ReadOnlySpan<BufferAssignment> buffers) => throw new NotSupportedException();
        public void SetTextureAndSampler(ShaderStage stage, int binding, ITexture texture, ISampler sampler) { TextureSets++; SampledTexture = texture; }
        public void SetTextureArray(ShaderStage stage, int binding, ITextureArray array) => throw new NotSupportedException();
        public void SetTextureArraySeparate(ShaderStage stage, int setIndex, ITextureArray array) => throw new NotSupportedException();
        public void SetTransformFeedbackBuffers(ReadOnlySpan<BufferRange> buffers) => throw new NotSupportedException();
        public void SetUniformBuffers(ReadOnlySpan<BufferAssignment> buffers) => throw new NotSupportedException();
        public void SetUserClipDistance(int index, bool enableClip) => throw new NotSupportedException();
        public void SetVertexAttribs(ReadOnlySpan<VertexAttribDescriptor> vertexAttribs) => throw new NotSupportedException();
        public void SetVertexBuffers(ReadOnlySpan<VertexBufferDescriptor> vertexBuffers) => throw new NotSupportedException();
        public void SetViewports(ReadOnlySpan<Viewport> viewports) => throw new NotSupportedException();
        public void TextureBarrier() => throw new NotSupportedException();
        public void TextureBarrierTiled() => throw new NotSupportedException();
        public bool TryHostConditionalRendering(ICounterEvent value, ulong compare, bool isEqual) => throw new NotSupportedException();
        public bool TryHostConditionalRendering(ICounterEvent value, ICounterEvent compare, bool isEqual) => throw new NotSupportedException();
        public void EndHostConditionalRendering() => throw new NotSupportedException();
    }

    private sealed class Renderer : BufferCacheBindingTests.BufferRenderer, IRenderer
    {
        public readonly PipelineRecorder RecordedPipeline = new();
        IPipeline IRenderer.Pipeline => RecordedPipeline;
        public override ITexture CreateTexture(TextureCreateInfo info) => new HostTexture(info.Width, info.Height);
    }

    private sealed class HostTexture(int width, int height) : ITexture
    {
        public int Width => width;
        public int Height => height;
        public bool Released;
        public int Copies;
        public void CopyTo(ITexture destination, int firstLayer, int firstLevel) { Copies++; }
        public void CopyTo(ITexture destination, int srcLayer, int dstLayer, int srcLevel, int dstLevel) { Copies++; }
        public void CopyTo(ITexture destination, Extents2D srcRegion, Extents2D dstRegion, bool linearFilter) { Copies++; }
        public void CopyTo(BufferRange range, int layer, int level, int stride) => throw new NotSupportedException();
        public ITexture CreateView(TextureCreateInfo info, int firstLayer, int firstLevel) => new HostTexture(info.Width, info.Height);
        public PinnedSpan<byte> GetData() => throw new NotSupportedException();
        public PinnedSpan<byte> GetData(int layer, int level) => throw new NotSupportedException();
        public void SetData(MemoryOwner<byte> data) => data.Dispose();
        public void SetData(MemoryOwner<byte> data, int layer, int level) => data.Dispose();
        public void SetData(MemoryOwner<byte> data, int layer, int level, Rectangle<int> region) => data.Dispose();
        public void SetStorage(BufferRange buffer) => throw new NotSupportedException();
        public void Release() => Released = true;
    }

    [TestCase(1.5f, false)]
    [TestCase(2f, false)]
    [TestCase(1.5f, true)]
    [TestCase(2f, true)]
    public void RenderTargetScaleMismatchRemainsVisibleUntilScaleIsUpdated(float scale, bool depth)
    {
        float previousScale = GraphicsConfig.ResScale;
        try
        {
            GraphicsConfig.ResScale = 1f;
            var renderer = new Renderer();
            using var context = new GpuContext(renderer, default);
            using var physical = new PhysicalMemory(context, new BufferCacheBindingTests.TrackedMemory());
            using var manager = new TextureManager(context, null!);
            var format = new FormatInfo(depth ? Format.D32Float : Format.R8G8B8A8Unorm, 1, 1, 4, (byte)(depth ? 1 : 4));
            var info = new TextureInfo(0x1000, 64, 64, 1, 1, 1, 1, 256, true, 1, 1, 1, Target.Texture2D, format);
            var texture = new GpuTexture(context, physical, info, info.CalculateSizeInfo(), new MultiRange(0x1000, 16384), TextureScaleMode.Eligible);
            texture.InitializeGroup(false, false, []);
            texture.InitializeData(false);
            try
            {
                if (depth) manager.SetRenderTargetDepthStencil(texture);
                else manager.SetRenderTargetColor(0, texture);
                Assert.That(manager.UpdateRenderTargets(), Is.False);
                var original = (HostTexture)texture.HostTexture;
                texture.SetScale(scale);
                Assert.That(original.Copies, Is.EqualTo(1), "Use the production resize/copy path.");
                Assert.That(texture.HostTexture, Is.Not.SameAs(original));
                Assert.That(manager.RenderTargetScale, Is.EqualTo(1f));
                Assert.That(manager.UpdateRenderTargets(), Is.True);
                int bound = ((PipelineRecorder)renderer.RecordedPipeline).RenderTargetSets;
                Assert.That(manager.UpdateRenderTargets(), Is.True, "Reading host attachments must not consume an unresolved scale mismatch.");
                Assert.That(((PipelineRecorder)renderer.RecordedPipeline).RenderTargetSets, Is.EqualTo(bound));
                GraphicsConfig.ResScale = scale;
                manager.UpdateRenderTargetScale(-1);
                Assert.That(manager.RenderTargetScale, Is.EqualTo(scale));
                Assert.That(manager.UpdateRenderTargets(), Is.False);
            }
            finally
            {
                if (depth) manager.SetRenderTargetDepthStencil(null!);
                else manager.SetRenderTargetColor(0, null!);
            }
        }
        finally
        {
            GraphicsConfig.ResScale = previousScale;
        }
    }
}
