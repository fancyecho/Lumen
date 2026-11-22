// Metal Shading Language sources for generative wallpapers.
//
// Every wallpaper is a single fragment function named `lumen_fragment`.
// The shared header below provides the vertex stage, the uniform layout,
// and noise / palette helpers. Sources are compiled at runtime, which keeps
// the build free of the offline Metal toolchain and lets users write their own.

enum ShaderSources {
    static let header = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float time;
        float speed;
        float intensity;
        float scale;
        float2 padding;
        float4 color0;
        float4 color1;
        float4 color2;
        float4 color3;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // One oversized triangle covers the whole target; uv is 0...1 with y up.
    vertex VertexOut lumen_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = p;
        return out;
    }

    // Sine-free hashes (after Dave Hoskins). Multipliers below 1 keep
    // neighbouring lattice cells uncorrelated, so noise shows no grid.
    inline float hash21(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    inline float2 hash22(float2 p) {
        float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.xx + p3.yz) * p3.zy);
    }

    // Quintic gradient noise, roughly 0...1.
    inline float gradientNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        float2 ga = hash22(i) * 2.0 - 1.0;
        float2 gb = hash22(i + float2(1.0, 0.0)) * 2.0 - 1.0;
        float2 gc = hash22(i + float2(0.0, 1.0)) * 2.0 - 1.0;
        float2 gd = hash22(i + float2(1.0, 1.0)) * 2.0 - 1.0;
        float va = dot(ga, f);
        float vb = dot(gb, f - float2(1.0, 0.0));
        float vc = dot(gc, f - float2(0.0, 1.0));
        float vd = dot(gd, f - float2(1.0, 1.0));
        return mix(mix(va, vb, u.x), mix(vc, vd, u.x), u.y) * 0.5 + 0.5;
    }

    inline float fbm(float2 p, int octaves) {
        float value = 0.0;
        float amplitude = 0.5;
        float2x2 rotation = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
        for (int i = 0; i < octaves; i++) {
            value += amplitude * gradientNoise(p);
            p = rotation * p * 2.03 + float2(1.7, 9.2);
            amplitude *= 0.5;
        }
        return value;
    }

    // Smooth four-stop gradient across the user palette.
    inline float3 palette(float t, constant Uniforms& u) {
        t = clamp(t, 0.0, 1.0) * 3.0;
        float3 a = mix(u.color0.rgb, u.color1.rgb, smoothstep(0.0, 1.0, t));
        float3 b = mix(a, u.color2.rgb, smoothstep(1.0, 2.0, t));
        return mix(b, u.color3.rgb, smoothstep(2.0, 3.0, t));
    }

    // Aspect-correct coordinates centred on the screen, unit height.
    inline float2 centered(float2 uv, float2 resolution) {
        return (uv - 0.5) * float2(resolution.x / resolution.y, 1.0);
    }

    // Temporal dither hides 8-bit banding in slow gradients.
    inline float3 dither(float3 color, float2 fragCoord, float time) {
        float n = hash21(fragCoord + fract(time * 7.13) * 61.0) - 0.5;
        return color + n / 255.0;
    }

    inline float vignette(float2 uv, float strength) {
        float2 d = uv - 0.5;
        return 1.0 - strength * dot(d, d) * 2.0;
    }

    inline float starField(float2 p, float time, float threshold, float size) {
        float2 cell = floor(p);
        float2 f = fract(p) - 0.5;
        float h = hash21(cell);
        float2 offset = (hash22(cell + 13.1) - 0.5) * 0.7;
        float d = length(f - offset);
        float radius = size * (0.5 + hash21(cell + 4.7));
        float star = smoothstep(radius, 0.0, d) * step(threshold, h);
        float twinkle = 0.65 + 0.35 * sin(time * (0.8 + 2.0 * h) + h * 80.0);
        return star * twinkle * (0.4 + 2.0 * (h - threshold) / (1.0 - threshold));
    }
    """#

    // MARK: - Presets

    static let silk = #"""
    fragment float4 lumen_fragment(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 p = centered(in.uv, u.resolution) * (1.15 / max(u.scale, 0.05));
        float t = u.time * 0.05;
        float2 q = float2(fbm(p + float2(0.0, t), 3),
                          fbm(p + float2(5.2, 1.3) - t * 0.8, 3));
        float2 r = float2(fbm(p + 3.0 * q + float2(1.7, 9.2) + t * 0.6, 3),
                          fbm(p + 3.0 * q + float2(8.3, 2.8) - t * 0.5, 3));
        float f = fbm(p + 2.6 * r, 4);

        float tone = saturate((f - 0.3) / 0.36 + (r.x - 0.5) * 0.45);
        tone = tone * tone * (3.0 - 2.0 * tone);
        float3 color = palette(tone, u);

        // Folds: light the height field using its screen-space slope.
        float2 slope = float2(dfdx(f), dfdy(f)) * u.resolution.y * 0.55;
        float light = saturate(0.5 + dot(slope, float2(-0.55, 0.83)));
        color *= 0.78 + 0.4 * light;
        color += u.color3.rgb * pow(light, 6.0) * 0.18 * u.intensity;

        float luma = dot(color, float3(0.299, 0.587, 0.114));
        color = mix(float3(luma), color, 0.75 + 0.3 * u.intensity);
        color *= vignette(in.uv, 0.35);
        return float4(dither(color, in.uv * u.resolution, u.time), 1.0);
    }
    """#

    static let aurora = #"""
    fragment float4 lumen_fragment(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = float2(uv.x * aspect, uv.y);
        float t = u.time * 0.05;

        float3 color = mix(u.color0.rgb * 1.7, u.color0.rgb * 0.4, smoothstep(0.0, 1.0, uv.y));

        float stars = starField(p * 90.0, u.time, 0.975, 0.10);
        color += stars * smoothstep(0.3, 0.75, uv.y) * 0.8;

        float3 aurora = float3(0.0);
        float invScale = 1.0 / max(u.scale, 0.05);
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float x = p.x * invScale * (0.8 + fi * 0.3) + t * (1.0 + fi * 0.4) + fi * 3.7;
            float wave = 0.13 * sin(x * 1.1 + t * 2.0 + fi)
                       + 0.22 * (fbm(float2(x * 0.6, t * 0.6 + fi * 5.0), 3) - 0.47);
            float center = 0.55 + fi * 0.08 + wave;
            float dy = uv.y - center;
            float band = dy < 0.0 ? exp(-dy * dy * 420.0) : exp(-dy * 4.5);
            float rays = smoothstep(0.32, 0.72, fbm(float2(x * 9.0, t * 2.5 + fi * 11.0), 3));
            float3 tint = (i == 0) ? u.color1.rgb : ((i == 1) ? u.color2.rgb : u.color3.rgb);
            tint = mix(tint, u.color3.rgb, smoothstep(0.02, 0.3, dy) * 0.55);
            aurora += tint * band * (0.3 + 0.7 * rays);
        }
        color += aurora * 0.5 * u.intensity;
        color += u.color1.rgb * exp(-uv.y * 7.0) * 0.07 * u.intensity;

        float peaks = 1.0 - abs(gradientNoise(float2(p.x * 2.4 + 7.0, 2.0)) * 2.0 - 1.0);
        float ridge = 0.07 + 0.2 * (fbm(float2(p.x * 1.5 + 3.0, 1.0), 5) - 0.25) + 0.05 * peaks;
        float aa = fwidth(uv.y) * 1.5;
        float mountain = smoothstep(ridge + aa, ridge - aa, uv.y);
        color = mix(color, u.color0.rgb * 0.2, mountain);

        color *= vignette(uv, 0.3);
        return float4(dither(color, uv * u.resolution, u.time), 1.0);
    }
    """#

    static let nebula = #"""
    fragment float4 lumen_fragment(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 p = centered(in.uv, u.resolution) * (2.2 / max(u.scale, 0.05));
        float t = u.time * 0.03;
        float2 drift = float2(t * 0.6, -t * 0.25);

        float n1 = fbm(p + drift, 6);
        float n2 = fbm(p * 1.8 + n1 * 2.2 - drift * 1.4 + 4.0, 5);
        float density = smoothstep(0.42, 0.78, n1 * 0.6 + n2 * 0.6);

        float3 color = u.color0.rgb;
        float3 gas = palette(saturate(n2 * 1.5 - 0.3), u);
        color = mix(color, gas, saturate(density * 0.85 * u.intensity));
        color += u.color3.rgb * pow(saturate(density * n2 * 1.4), 4.0) * 0.6 * u.intensity;

        float dust = smoothstep(0.5, 0.68, fbm(p * 3.0 - drift * 2.0 + 9.0, 4));
        color *= 1.0 - dust * 0.45 * density;

        color += starField(p * 14.0, u.time, 0.93, 0.05) * 0.9;
        color += starField(p * 40.0 + 3.0, u.time, 0.95, 0.07) * 0.55;

        color *= vignette(in.uv, 0.45);
        return float4(dither(color, in.uv * u.resolution, u.time), 1.0);
    }
    """#

    static let bloom = #"""
    fragment float4 lumen_fragment(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = float2(uv.x * aspect, uv.y);
        float t = u.time * 0.12;
        p += 0.035 * float2(sin(p.y * 3.1 + t * 1.3), cos(p.x * 2.7 - t * 1.1));

        float2 c0 = float2(aspect * (0.25 + 0.15 * sin(t * 0.9)), 0.30 + 0.20 * cos(t * 0.7));
        float2 c1 = float2(aspect * (0.75 + 0.15 * cos(t * 0.8 + 1.0)), 0.25 + 0.18 * sin(t * 1.1 + 2.0));
        float2 c2 = float2(aspect * (0.70 + 0.18 * sin(t * 0.6 + 4.0)), 0.75 + 0.15 * cos(t * 0.9 + 1.5));
        float2 c3 = float2(aspect * (0.28 + 0.16 * cos(t * 1.0 + 3.0)), 0.72 + 0.18 * sin(t * 0.75 + 0.5));

        float s = max(u.scale, 0.05) * 0.6;
        float w0 = 1.0 / (pow(length(p - c0) / s, 2.2) + 0.05);
        float w1 = 1.0 / (pow(length(p - c1) / s, 2.2) + 0.05);
        float w2 = 1.0 / (pow(length(p - c2) / s, 2.2) + 0.05);
        float w3 = 1.0 / (pow(length(p - c3) / s, 2.2) + 0.05);
        float3 color = (u.color0.rgb * w0 + u.color1.rgb * w1 + u.color2.rgb * w2 + u.color3.rgb * w3)
                     / (w0 + w1 + w2 + w3);

        float sweep = 0.5 + 0.5 * sin((p.x + p.y) * 2.0 - t * 1.5);
        color += 0.05 * u.intensity * sweep;

        float grain = hash21(uv * u.resolution + fract(u.time) * 100.0) - 0.5;
        color += grain * 0.03 * u.intensity;
        return float4(color, 1.0);
    }
    """#

    static let contour = #"""
    fragment float4 lumen_fragment(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 p = centered(in.uv, u.resolution) * (2.0 / max(u.scale, 0.05));
        float t = u.time * 0.04;
        float h = fbm(p * 0.9 + float2(t, t * 0.6), 5);
        h += 0.15 * fbm(p * 2.0 - float2(t * 0.7, -t), 3);

        float v = h * 26.0;
        float line = 1.0 - smoothstep(0.0, fwidth(v) * 1.2, abs(fract(v + 0.5) - 0.5));
        float vm = v / 5.0;
        float major = 1.0 - smoothstep(0.0, fwidth(vm) * 1.6, abs(fract(vm + 0.5) - 0.5));

        float tone = saturate((h - 0.3) / 0.5);
        float3 color = mix(u.color0.rgb, u.color1.rgb, tone);
        float3 ink = mix(u.color2.rgb, u.color3.rgb, smoothstep(0.3, 0.8, tone));
        color = mix(color, ink, saturate(line * 0.4 * u.intensity));
        color = mix(color, ink, saturate(major * 0.85 * u.intensity));

        color *= vignette(in.uv, 0.4);
        return float4(dither(color, in.uv * u.resolution, u.time), 1.0);
    }
    """#

    static let lava = #"""
    fragment float4 lumen_fragment(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = float2(uv.x * aspect, uv.y);
        float t = u.time * 0.15;

        float field = 0.0;
        for (int i = 0; i < 7; i++) {
            float fi = float(i);
            float2 c = float2(aspect * (0.5 + 0.38 * sin(t * (0.5 + fi * 0.13) + fi * 1.7)),
                              0.5 + 0.42 * sin(t * (0.37 + fi * 0.11) + fi * 2.9));
            float r = (0.09 + 0.04 * sin(fi * 3.3 + t)) * max(u.scale, 0.05);
            float2 d = p - c;
            field += r * r / (dot(d, d) + 1e-4);
        }

        float3 background = mix(u.color0.rgb * 0.6, u.color0.rgb * 1.6 + 0.02, uv.y);
        float fw = max(fwidth(field), 1e-4);
        float body = smoothstep(1.0 - fw, 1.0 + fw, field);

        float3 blob = mix(u.color1.rgb, u.color3.rgb, saturate((field - 1.0) * 0.3));
        blob = mix(blob, u.color2.rgb, smoothstep(0.2, 0.95, uv.y) * 0.55);

        float glow = saturate(field * 0.55) * (1.0 - body);
        float3 color = background + blob * glow * 0.4 * u.intensity;
        color = mix(color, blob, body);
        float rim = body * (1.0 - smoothstep(1.0, 1.7, field));
        color += rim * 0.22 * u.color3.rgb * u.intensity;

        color *= vignette(uv, 0.35);
        return float4(dither(color, uv * u.resolution, u.time), 1.0);
    }
    """#

    /// Starting point for a user-authored shader in the Studio editor.
    static let customTemplate = #"""
    // Available: u.time (seconds, already scaled by speed), u.resolution,
    // u.intensity, u.scale, u.color0...u.color3, plus helpers from the header:
    // fbm(), gradientNoise(), palette(), centered(), dither(), vignette().
    fragment float4 lumen_fragment(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 p = centered(in.uv, u.resolution) * (2.0 / max(u.scale, 0.05));
        float wave = fbm(p + float2(u.time * 0.1, 0.0), 5);
        float3 color = palette(wave * 1.3 - 0.15, u);
        color *= vignette(in.uv, 0.4);
        return float4(dither(color, in.uv * u.resolution, u.time), 1.0);
    }
    """#
}
