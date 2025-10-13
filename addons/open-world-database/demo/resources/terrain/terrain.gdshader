shader_type spatial;
render_mode depth_draw_opaque, cull_back;

// Texture uniforms - assign your terrain textures in the material
uniform sampler2D water_texture : source_color, hint_default_white;
uniform sampler2D sand_texture : source_color, hint_default_white;
uniform sampler2D grass_texture : source_color, hint_default_white;
uniform sampler2D rock_texture : source_color, hint_default_white;
uniform sampler2D snow_texture : source_color, hint_default_white;

// Texture tiling
uniform float texture_scale : hint_range(0.1, 100.0) = 10.0;

// Blend sharpness - higher values create sharper transitions
uniform float blend_sharpness : hint_range(0.1, 10.0) = 2.0;

// Anti-tiling controls
uniform bool enable_anti_tiling = true;
uniform float anti_tiling_strength : hint_range(0.0, 1.0) = 0.5;

// Simplified mipmap bias control
uniform float mipmap_bias : hint_range(-2.0, 2.0) = -0.5;

varying vec3 world_position;
varying vec4 vertex_color;
varying vec3 view_direction;

// Improved hash function for smoother results
vec4 hash4(ivec2 p) {
    vec4 p4 = fract(vec4(p.xyxy) * vec4(0.1031, 0.1030, 0.0973, 0.1099));
    p4 += dot(p4, p4.wzxy + 33.33);
    return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

// Fixed anti-tiling function with gentler blending
vec4 texture_no_tile(sampler2D samp, vec2 uv, float bias) {
    if (!enable_anti_tiling) {
        return texture(samp, uv, bias);
    }

    ivec2 iuv = ivec2(floor(uv));
    vec2 fuv = fract(uv);

    // Generate per-tile random values
    vec4 ofa = hash4(iuv + ivec2(0, 0));
    vec4 ofb = hash4(iuv + ivec2(1, 0));
    vec4 ofc = hash4(iuv + ivec2(0, 1));
    vec4 ofd = hash4(iuv + ivec2(1, 1));

    // Get derivatives for proper mipmapping
    vec2 ddx = dFdx(uv);
    vec2 ddy = dFdy(uv);

    // Apply bias to derivatives
    float bias_scale = pow(2.0, bias);
    ddx *= bias_scale;
    ddy *= bias_scale;

    // Create gentler random offsets and rotations
    // Convert random values to offsets in range [-0.5, 0.5]
    vec2 offset_a = (ofa.xy - 0.5) * anti_tiling_strength;
    vec2 offset_b = (ofb.xy - 0.5) * anti_tiling_strength;
    vec2 offset_c = (ofc.xy - 0.5) * anti_tiling_strength;
    vec2 offset_d = (ofd.xy - 0.5) * anti_tiling_strength;

    // Create gentle scale variations around 1.0
    float scale_range = 0.1; // Maximum 10% scale variation
    float scale_a = 1.0 + (ofa.z - 0.5) * scale_range * anti_tiling_strength;
    float scale_b = 1.0 + (ofb.z - 0.5) * scale_range * anti_tiling_strength;
    float scale_c = 1.0 + (ofc.z - 0.5) * scale_range * anti_tiling_strength;
    float scale_d = 1.0 + (ofd.z - 0.5) * scale_range * anti_tiling_strength;

    // Apply transformations
    vec2 uva = uv * scale_a + offset_a;
    vec2 uvb = uv * scale_b + offset_b;
    vec2 uvc = uv * scale_c + offset_c;
    vec2 uvd = uv * scale_d + offset_d;

    // Transform derivatives accordingly
    vec2 ddxa = ddx * scale_a;
    vec2 ddya = ddy * scale_a;
    vec2 ddxb = ddx * scale_b;
    vec2 ddyb = ddy * scale_b;
    vec2 ddxc = ddx * scale_c;
    vec2 ddyc = ddy * scale_c;
    vec2 ddxd = ddx * scale_d;
    vec2 ddyd = ddy * scale_d;

    // Improved blending with smoother transitions
    vec2 b = smoothstep(0.0, 1.0, fuv);
    // Apply additional smoothing
    b = b * b * (3.0 - 2.0 * b); // Hermite interpolation for even smoother blending

    // Sample textures with proper derivatives
    vec4 sample_a = textureGrad(samp, uva, ddxa, ddya);
    vec4 sample_b = textureGrad(samp, uvb, ddxb, ddyb);
    vec4 sample_c = textureGrad(samp, uvc, ddxc, ddyc);
    vec4 sample_d = textureGrad(samp, uvd, ddxd, ddyd);

    // Smooth blending between samples
    return mix(mix(sample_a, sample_b, b.x),
               mix(sample_c, sample_d, b.x), b.y);
}

void vertex() {
    world_position = VERTEX;
    vertex_color = COLOR;
    view_direction = (CAMERA_POSITION_WORLD - (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
    // Calculate UV coordinates based on world position for texture tiling
    vec2 tiled_uv = world_position.xz / texture_scale;

    // Sample all textures with improved anti-tiling
    vec4 water_tex = texture_no_tile(water_texture, tiled_uv, mipmap_bias);
    vec4 sand_tex = texture_no_tile(sand_texture, tiled_uv, mipmap_bias);
    vec4 grass_tex = texture_no_tile(grass_texture, tiled_uv, mipmap_bias);
    vec4 rock_tex = texture_no_tile(rock_texture, tiled_uv, mipmap_bias);
    vec4 snow_tex = texture_no_tile(snow_texture, tiled_uv, mipmap_bias);

    // Extract color components for blending weights
    vec3 vc = vertex_color.rgb;

    // Calculate blend weights based on vertex color similarity to terrain colors
    vec3 water_ref = vec3(0.0, 0.0, 1.0);   // Blue
    vec3 sand_ref = vec3(0.96, 0.64, 0.38);  // Sandy brown
    vec3 grass_ref = vec3(0.0, 1.0, 0.0);    // Green
    vec3 rock_ref = vec3(0.5, 0.5, 0.5);     // Gray
    vec3 snow_ref = vec3(1.0, 1.0, 1.0);     // White

    // Calculate similarity to each terrain type
    float water_weight = 1.0 - distance(vc, water_ref);
    float sand_weight = 1.0 - distance(vc, sand_ref);
    float grass_weight = 1.0 - distance(vc, grass_ref);
    float rock_weight = 1.0 - distance(vc, rock_ref);
    float snow_weight = 1.0 - distance(vc, snow_ref);

    // Apply sharpness to make transitions more defined
    water_weight = pow(max(0.0, water_weight), blend_sharpness);
    sand_weight = pow(max(0.0, sand_weight), blend_sharpness);
    grass_weight = pow(max(0.0, grass_weight), blend_sharpness);
    rock_weight = pow(max(0.0, rock_weight), blend_sharpness);
    snow_weight = pow(max(0.0, snow_weight), blend_sharpness);

    // Normalize weights
    float total_weight = water_weight + sand_weight + grass_weight + rock_weight + snow_weight;
    if (total_weight > 0.0) {
        water_weight /= total_weight;
        sand_weight /= total_weight;
        grass_weight /= total_weight;
        rock_weight /= total_weight;
        snow_weight /= total_weight;
    }

    // Blend textures
    vec4 final_color = water_tex * water_weight +
                      sand_tex * sand_weight +
                      grass_tex * grass_weight +
                      rock_tex * rock_weight +
                      snow_tex * snow_weight;

    final_color *= 0.5;
    ALBEDO = final_color.rgb;
}
