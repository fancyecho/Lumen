import simd

/// Mirrors `struct Uniforms` in `ShaderSources.header` byte for byte (96 bytes).
struct ShaderUniforms {
    var resolution: SIMD2<Float> = .zero
    var time: Float = 0
    var speed: Float = 1
    var intensity: Float = 1
    var scale: Float = 1
    var padding: SIMD2<Float> = .zero
    var color0: SIMD4<Float> = .zero
    var color1: SIMD4<Float> = .zero
    var color2: SIMD4<Float> = .zero
    var color3: SIMD4<Float> = .zero
}
