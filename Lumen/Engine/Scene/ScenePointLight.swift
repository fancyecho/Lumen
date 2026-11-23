import simd

struct ScenePointLight {
    let id: Int
    let radius: Float
    let intensity: Float
    let falloff: Float
    let density: Float
    let volumeFalloff: Float
    let parallaxDepth: SIMD2<Float>

    init?(object: SceneDocument.Object, values: SceneValues) {
        let raw = object.raw
        guard raw["light"] as? String == "lpoint" else { return nil }
        let radius = values.float(raw["radius"], default: 100)
        let intensity = values.float(raw["intensity"], default: 1)
        guard radius.isFinite, radius > 0, intensity.isFinite, intensity > 0 else { return nil }
        self.id = object.id
        self.radius = radius
        self.intensity = intensity
        func nonnegative(_ key: String) -> Float {
            let value = values.float(raw[key], default: 1)
            return value.isFinite ? max(0, value) : 1
        }
        falloff = nonnegative("exponent")
        density = values.bool(raw["castvolumetrics"], default: false) ? nonnegative("density") : 0
        volumeFalloff = nonnegative("volumetricsexponent")
        parallaxDepth = object.parallaxDepth
    }
}

struct ScenePointLightSample {
    let positionRadius: SIMD4<Float>
    let colorFalloff: SIMD4<Float>
    let density: Float
    let volumeFalloff: Float
    let parallaxDepth: SIMD2<Float>
}
