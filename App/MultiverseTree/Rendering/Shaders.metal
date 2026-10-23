// Multiverse Tree — cosmic branch renderer shaders.
// Layouts mirror BranchVertex / NodeInstance in MultiverseCore (four/three float4s).
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4x4 view;
    float4 cameraPos;   // xyz = camera position, w = time (s)
    float4 viewport;    // x = width, y = height, z = 1/width, w = 1/height
    float4 params;      // x = focus distance, y = depth-of-field strength, z = global dim, w = bloom intensity
    float4 cameraRight; // xyz
    float4 cameraUp;    // xyz
};

struct BranchVertex { float4 position; float4 tangent; float4 color; float4 params; };
struct NodeInstance { float4 position; float4 color; float4 params; };

// MARK: - Background

struct FullscreenOut { float4 position [[position]]; float2 uv; };

vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * valueNoise(p); p *= 2.03; a *= 0.5; }
    return v;
}

fragment float4 background_fragment(FullscreenOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float t = u.cameraPos.w;
    float2 uv = in.uv;
    float2 c = uv - 0.5;
    c.x *= u.viewport.x * u.viewport.w;
    float r = length(c);
    // Deep navy → black radial gradient.
    float3 col = mix(float3(0.020, 0.035, 0.090), float3(0.002, 0.004, 0.012), smoothstep(0.0, 0.9, r));
    // Slow violet / blue nebula haze.
    float n = fbm(c * 2.2 + float2(t * 0.004, -t * 0.003));
    float n2 = fbm(c * 4.0 - float2(t * 0.006, t * 0.002) + 7.0);
    col += float3(0.10, 0.04, 0.22) * pow(n, 3.0) * 0.9;
    col += float3(0.02, 0.10, 0.25) * pow(n2, 4.0) * 0.8;
    return float4(col * (1.0 - u.params.z * 0.5), 1.0);
}

// MARK: - Branches

struct BranchOut {
    float4 position [[position]];
    float4 color;
    float side;
    float t;
    float kind;
    float established;
    float highlight;
    float growth;
    float pulseStart;
    float dim;
    float seed;
};

vertex BranchOut branch_vertex(uint vid [[vertex_id]],
                               const device BranchVertex* verts [[buffer(0)]],
                               constant Uniforms& u [[buffer(1)]],
                               const device float4* edgeState [[buffer(2)]]) {
    BranchVertex v = verts[vid];
    float4 st = edgeState[int(v.params.y)];   // x highlight, y growth, z pulse start, w dim
    float3 p = v.position.xyz;
    float t = v.position.w;
    float3 viewDir = normalize(u.cameraPos.xyz - p);
    float3 sideDir = normalize(cross(v.tangent.xyz, viewDir) + 1e-5);
    float taper = v.params.z > 0.5 ? (1.0 - t * 0.9) : (0.75 + 0.25 * sin(t * 3.14159));
    float width = v.params.x * taper * (1.0 + st.x * 1.2);
    // Keep distant branches at least ~1.2 px wide so the network never aliases away.
    float dist = length(u.cameraPos.xyz - p);
    float minWorld = dist * 1.2 * u.viewport.w * 1.6;
    width = max(width, minWorld);
    float3 world = p + sideDir * width * v.tangent.w;

    BranchOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.color = v.color;
    o.side = v.tangent.w;
    o.t = t;
    o.kind = v.params.z;
    o.established = v.params.w;
    o.highlight = st.x;
    o.growth = st.y;
    o.pulseStart = st.z;
    o.dim = max(st.w, u.params.z * (1.0 - st.x));
    o.seed = fract(v.params.y * 0.6180339);
    return o;
}

fragment float4 branch_fragment(BranchOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float time = u.cameraPos.w;
    if (in.t > in.growth) discard_fragment();
    float d = abs(in.side);
    // Bright white core + coloured glow falloff.
    float core = exp(-d * d * 22.0);
    float glow = exp(-d * d * 3.0);
    float3 accent = in.color.rgb;
    float intensity = in.color.a;

    // Ambient electrical pulses flowing along every branch.
    float flow = pow(0.5 + 0.5 * sin(in.t * 18.0 - time * 2.4 + in.seed * 40.0), 10.0);
    // Targeted pulse for revealed / selected paths.
    float pulse = 0.0;
    if (in.pulseStart > -100.0) {
        float head = (time - in.pulseStart) * 0.9;
        float dt = in.t - fract(head);
        pulse = exp(-dt * dt * 260.0) * 2.5;
    }
    // Leading edge of a growing branch blazes white.
    float g = (in.growth - in.t) * 30.0;
    float tip = in.growth < 0.999 ? exp(-g * g) * 3.0 : 0.0;

    float3 col = accent * glow * (0.55 + in.highlight * 1.4) + float3(1.0) * core * (0.45 + in.highlight * 1.2);
    col += mix(accent, float3(0.75, 0.95, 1.0), 0.5) * flow * glow * 0.6;
    col += float3(0.8, 0.95, 1.0) * (pulse + tip) * glow;
    if (in.kind > 0.5) col *= 0.55;   // tendrils are thinner, fainter
    if (in.established < 0.5) {
        // Candidate edges: dashed and faint — "possible connection, research required".
        col *= step(0.5, fract(in.t * 24.0)) * 0.35 + 0.05;
    }
    col *= intensity * mix(1.0, 0.08, in.dim);
    return float4(col, 1.0);
}

// MARK: - Nodes (instanced billboards)

struct NodeOut {
    float4 position [[position]];
    float2 local;
    float4 color;
    float highlight;
    float blur;
    float dim;
    float phase;
};

constant float2 kQuad[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };

vertex NodeOut node_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device NodeInstance* nodes [[buffer(0)]],
                           constant Uniforms& u [[buffer(1)]]) {
    NodeInstance n = nodes[iid];
    float2 q = kQuad[vid];
    float3 center = n.position.xyz;
    float depth = length(u.cameraPos.xyz - center);
    // Depth of field: out-of-focus nodes grow softer and larger, keeping total energy roughly constant.
    float blur = clamp(abs(depth - u.params.x) / max(u.params.x, 1.0) * u.params.y, 0.0, 1.5);
    float size = n.position.w * (1.0 + n.params.x * 0.8) * (1.0 + blur * 0.8) * 1.6;
    float3 world = center + (u.cameraRight.xyz * q.x + u.cameraUp.xyz * q.y) * size;
    NodeOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.local = q;
    o.color = n.color;
    o.highlight = n.params.x;
    o.blur = blur;
    o.dim = max(n.params.w, u.params.z * (1.0 - n.params.x));
    o.phase = n.params.z;
    return o;
}

fragment float4 node_fragment(NodeOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float r = length(in.local);
    if (r > 1.0) discard_fragment();
    float sharp = 1.0 / (1.0 + in.blur * 3.0);
    float core = exp(-r * r * 60.0 * sharp) * 2.2;
    float halo = exp(-r * r * 6.0) * 0.6;
    float breathe = 0.85 + 0.15 * sin(u.cameraPos.w * 1.7 + in.phase * 6.283);
    float3 col = float3(1.0) * core + in.color.rgb * halo * breathe;
    if (in.highlight > 0.01) {
        float rr = (r - 0.62 - 0.05 * sin(u.cameraPos.w * 3.0)) * 18.0;
        float ring = exp(-rr * rr);
        col += mix(in.color.rgb, float3(1.0), 0.4) * ring * in.highlight * 1.5;
        col *= 1.0 + in.highlight;
    }
    col *= sharp * 0.6 + 0.4;
    col *= mix(1.0, 0.1, in.dim);
    return float4(col, 1.0);
}

// MARK: - Particles: starfield and drifting energy motes

struct ParticleOut { float4 position [[position]]; float2 local; float4 color; };

vertex ParticleOut particle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device float4* particles [[buffer(0)]],
                                   constant Uniforms& u [[buffer(1)]],
                                   constant float& isMote [[buffer(2)]]) {
    float4 pdata = particles[iid];
    float3 p = pdata.xyz;
    float time = u.cameraPos.w;
    float seed = fract(float(iid) * 0.1234567);
    if (isMote > 0.5) {
        p += float3(sin(time * 0.11 + seed * 50.0), cos(time * 0.07 + seed * 31.0), sin(time * 0.09 + seed * 17.0)) * 3.0;
    }
    float2 q = kQuad[vid];
    float size = pdata.w;
    float3 world = p + (u.cameraRight.xyz * q.x + u.cameraUp.xyz * q.y) * size;
    ParticleOut o;
    o.position = u.viewProj * float4(world, 1.0);
    o.local = q;
    float twinkle = 0.6 + 0.4 * sin(time * (0.5 + seed * 2.0) + seed * 100.0);
    float3 tint = isMote > 0.5 ? mix(float3(0.4, 0.7, 1.0), float3(0.85, 0.45, 1.0), seed) : mix(float3(0.7, 0.8, 1.0), float3(1.0), seed);
    o.color = float4(tint * twinkle * (isMote > 0.5 ? 0.35 : 0.8), 1.0);
    return o;
}

fragment float4 particle_fragment(ParticleOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float r = length(in.local);
    if (r > 1.0) discard_fragment();
    return float4(in.color.rgb * exp(-r * r * 8.0) * (1.0 - u.params.z * 0.6), 1.0);
}

// MARK: - Post-processing: bright pass + composite (bloom blur is MPSImageGaussianBlur)

fragment float4 bright_fragment(FullscreenOut in [[stage_in]], texture2d<float> hdr [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = hdr.sample(s, in.uv).rgb;
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    float k = smoothstep(0.35, 1.2, l);
    return float4(c * k, 1.0);
}

static float3 aces(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

fragment float4 composite_fragment(FullscreenOut in [[stage_in]],
                                   texture2d<float> hdr [[texture(0)]],
                                   texture2d<float> bloom [[texture(1)]],
                                   constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 scene = hdr.sample(s, in.uv).rgb;
    float3 b = bloom.sample(s, in.uv).rgb;
    float3 col = scene + b * u.params.w;
    // Slight blue lift in the shadows, vignette, tonemap.
    float2 c = in.uv - 0.5;
    col *= 1.0 - dot(c, c) * 0.9;
    col = aces(col * 1.1);
    col = pow(col, float3(1.0 / 1.05));
    return float4(col, 1.0);
}
