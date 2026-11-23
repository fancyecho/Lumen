import Foundation

/// Supplies runtime declarations used by Wallpaper Engine's stock lighting materials.
/// This happens before the common translator so the app and shader corpus compile the same source.
enum WESceneShader {
    static let pointLightLimit = 4
    private static let lightingDirective = #"(?m)^[\t ]*#[\t ]*require[\t ]+LightingV1\b[^\r\n]*"#
    private static let lightingInclude = "__lumen_lighting_v1.h"

    static func translate(vertex: String, fragment: String, combos: [String: Int],
                          resolveInclude: @escaping (String) -> String?) -> WEShaderProgram {
        var fragment = fragment
        var engineDefines: [String: String] = [:]
        if fragment.range(of: lightingDirective, options: .regularExpression) != nil {
            fragment = fragment.replacingOccurrences(of: lightingDirective, with: "#include \"\(lightingInclude)\"",
                                                     options: .regularExpression)
            // A Metal thread reference needs a local scalar when the original call passes a swizzle.
            fragment = fragment.replacingOccurrences(
                of: "ApplyAlphaToCoverage(gl_FragColor.a);",
                with: "float lumenCoverageAlpha = gl_FragColor.a;\nApplyAlphaToCoverage(lumenCoverageAlpha);\ngl_FragColor.a = lumenCoverageAlpha;"
            )
            if fragment.contains("ConvertTextureFormat(TEX8FORMAT,") { engineDefines["TEX8FORMAT"] = "0" }
        }
        // The volume utility uses normalized coordinates for both reads. Its render targets
        // are unpadded, and the depth-limit read addresses the nearest texel at mip zero.
        fragment = fragment.replacingOccurrences(
            of: "texSample2DBackBuffer(g_Texture1, screenUV.xy, g_Texture1Resolution.xy)",
            with: "texSample2D(g_Texture1, screenUV.xy)"
        )
        fragment = fragment.replacingOccurrences(
            of: "texLoad2D(g_Texture3, screenUV.xy, g_Texture3Resolution.xy)",
            with: "texLoad2D(g_Texture3, int2(clamp(screenUV.xy * g_Texture3Resolution.xy, vec2(0.0), g_Texture3Resolution.xy - vec2(1.0))), 0)"
        )
        return WEShaderTranslator.translate(vertex: vertex, fragment: fragment, combos: combos, engineDefines: engineDefines) { name in
            name == lightingInclude ? lightingSource : resolveInclude(name)
        }
    }

    private static let lightingSource = """
    #if LIGHTING
    uniform vec4 g_LumenPointLightPositionRadius[\(pointLightLimit)];
    uniform vec4 g_LumenPointLightColorFalloff[\(pointLightLimit)];

    vec3 PerformLighting_V1(vec3 world, vec3 albedo, vec3 normal, vec3 view, vec3 specularTint,
                           vec3 reflectance, float roughness, float metallic)
    {
        vec3 radiance = vec3(0.0);
        for (int index = 0; index < \(pointLightLimit); ++index) {
            vec4 light = g_LumenPointLightPositionRadius[index];
            if (light.w <= 0.0) break;
            vec3 toLight = light.xyz - world;
            float distanceSquared = dot(toLight, toLight);
            if (distanceSquared < 1e-6 || distanceSquared >= light.w * light.w) continue;
            vec4 lightColor = g_LumenPointLightColorFalloff[index];
            radiance += ComputePBRLightShadow(normal, toLight, view, albedo, lightColor.rgb, light.w, lightColor.w,
                                              specularTint, reflectance, max(roughness, 0.02), metallic, 1.0);
        }
        return radiance;
    }
    #endif
    """
}
