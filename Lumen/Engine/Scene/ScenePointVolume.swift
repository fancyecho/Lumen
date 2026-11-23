import Metal
import simd

/// Projects a point light's scattering over the opaque 2D canvas. The orthographic rays
/// end at z=0 and have no model shadows, perspective view, or projected cookies.
final class ScenePointVolume {
    private struct Uniforms {
        let viewProjection: simd_float4x4
        let positionRadius: SIMD4<Float>
        let radianceDensity: SIMD4<Float>
        let eyeZ: Float
        let falloff: Float
        let footprintRadius: Float
    }

    private enum PipelineError: Error {
        case missingShaderFunction
    }

    private let pipeline: MTLRenderPipelineState

    init(device: MTLDevice) throws {
        let options = MTLCompileOptions()
        options.languageVersion = .version3_2
        let library = try device.makeLibrary(source: Self.shader, options: options)
        guard let vertex = library.makeFunction(name: "pointVolumeVertex"),
              let fragment = library.makeFunction(name: "pointVolumeFragment")
        else { throw PipelineError.missingShaderFunction }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Lumen point volume"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .rgba8Unorm
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .one
        color.writeMask = [.red, .green, .blue]
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func draw(encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4,
              positionRadius: SIMD4<Float>, radiance: SIMD3<Float>, density: Float,
              falloff: Float, eyeZ: Float) {
        let radius = positionRadius.w
        guard radius.isFinite, radius > 0, density.isFinite, density > 0, eyeZ.isFinite, eyeZ > 0,
              positionRadius.x.isFinite, positionRadius.y.isFinite, positionRadius.z.isFinite,
              radiance.x.isFinite, radiance.y.isFinite, radiance.z.isFinite, falloff.isFinite
        else { return }

        // A sphere that crosses either end of the ray has a smaller footprint on the visible segment.
        let slabDistance = max(0, -positionRadius.z, positionRadius.z - eyeZ) / radius
        guard slabDistance < 1 else { return }
        let footprintRadius = radius * sqrt(max(0, 1 - slabDistance * slabDistance))
        let rgb = simd_max(radiance, .zero)
        var uniforms = Uniforms(viewProjection: viewProjection, positionRadius: positionRadius,
                                radianceDensity: SIMD4(rgb.x, rgb.y, rgb.z, density), eyeZ: eyeZ,
                                falloff: max(falloff, 0), footprintRadius: footprintRadius)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewProjection;
        float4 positionRadius;
        float4 radianceDensity;
        float eyeZ;
        float falloff;
        float footprintRadius;
    };

    struct RasterData {
        float4 position [[position]];
        float2 radialOffset;
    };

    vertex RasterData pointVolumeVertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        float2 corner = float2((id & 2) ? 1.0 : -1.0, (id & 1) ? -1.0 : 1.0);
        float2 offset = corner * u.footprintRadius;
        float2 world = u.positionRadius.xy + offset;
        return { u.viewProjection * float4(world, 0, 1), offset / u.positionRadius.w };
    }

    fragment float4 pointVolumeFragment(RasterData in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float radialDistanceSquared = dot(in.radialOffset, in.radialOffset);
        if (radialDistanceSquared >= 1.0) discard_fragment();

        // Clip the sphere's ray interval at the canvas and the viewer in radius units.
        float halfChord = sqrt(1.0 - radialDistanceSquared);
        float inverseRadius = 1.0 / u.positionRadius.w;
        float first = max(-halfChord, -u.positionRadius.z * inverseRadius);
        float last = min(halfChord, (u.eyeZ - u.positionRadius.z) * inverseRadius);
        if (first >= last) discard_fragment();

        // Integrate scattering along the short ray with fixed-cost midpoint quadrature.
        constexpr uint sampleCount = 4;
        float stepSize = (last - first) / float(sampleCount);
        float integral = 0.0;
        for (uint i = 0; i < sampleCount; ++i) {
            float z = first + (float(i) + 0.5) * stepSize;
            float radiusFraction = sqrt(radialDistanceSquared + z * z);
            integral += pow(saturate(1.0 - radiusFraction), u.falloff);
        }

        // Keep the approximation in the existing unorm scene buffer’s intensity range.
        float scattering = integral * stepSize * u.radianceDensity.w * 0.05;
        return float4(u.radianceDensity.rgb * scattering, 0.0);
    }
    """
}
