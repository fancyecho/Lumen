import Foundation
import simd

/// The authored camera for models in a 3D project.
struct SceneModelCamera {
    let eye: SIMD3<Float>
    let viewProjection: simd_float4x4

    init?(json: [String: Any], values: SceneValues, canvas: SIMD2<Float>) {
        guard let camera = json["camera"] as? [String: Any] else { return nil }
        let eye = values.vec3(camera["eye"], default: .zero)
        let center = values.vec3(camera["center"], default: SIMD3(0, 0, -1))
        let up = values.vec3(camera["up"], default: SIMD3(0, 1, 0))
        let general = json["general"] as? [String: Any] ?? [:]
        let near = values.float(general["nearz"], default: 0.1)
        let far = values.float(general["farz"], default: 10_000)
        let fov = values.float(general["fov"], default: 50)
        let forward = center - eye
        let right = simd_cross(forward, up)
        let forwardLength = simd_length(forward)
        let rightLength = simd_length(right)
        guard forwardLength.isFinite, forwardLength > 0, rightLength.isFinite, rightLength > 0,
              near.isFinite, near > 0, far.isFinite, far > near, fov > 0, fov < 180 else { return nil }

        let z = -forward / forwardLength
        let x = right / rightLength
        let y = simd_cross(z, x)
        let view = simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0),
            SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
        let focalLength = 1 / tan(fov * .pi / 360)
        let aspect = canvas.x / canvas.y
        // The translated vertex shader maps signed clip-space Z to Metal's depth range.
        let zScale = (far + near) / (near - far)
        let projection = simd_float4x4(columns: (
            SIMD4(focalLength / aspect, 0, 0, 0),
            SIMD4(0, focalLength, 0, 0),
            SIMD4(0, 0, zScale, -1),
            SIMD4(0, 0, near * (zScale - 1), 0)
        ))
        self.eye = eye
        viewProjection = projection * view
    }
}
