shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_opaque;

// Basic properties
uniform vec4 grass_color_base : source_color = vec4(0.2, 0.5, 0.1, 1.0);
uniform vec4 grass_color_tip : source_color = vec4(0.4, 0.7, 0.2, 1.0);

// Transmission/Translucency properties
uniform float transmission_strength : hint_range(0.0, 2.0) = 1.0;
uniform vec4 transmission_color : source_color = vec4(0.6, 0.9, 0.3, 1.0);
uniform float transmission_falloff : hint_range(0.1, 5.0) = 2.0;
uniform float backlight_strength : hint_range(0.0, 2.0) = 1.0;

// Specular highlight properties
uniform float normal_tip_blend : hint_range(0.0, 1.0) = 0.8;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.2;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.8;
uniform float roughness_tip : hint_range(0.0, 1.0) = 0.3;

// Wind animation
uniform float wind_strength : hint_range(0.0, 2.0) = 0.5;
uniform float wind_speed : hint_range(0.0, 5.0) = 1.0;
uniform float wave_size : hint_range(1.0, 20.0) = 10.0;
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float variation_amount : hint_range(0.0, 1.0) = 0.3;
uniform float gust_strength : hint_range(0.0, 1.0) = 0.4;
uniform float turbulence : hint_range(0.0, 2.0) = 0.6;

// Normal depth effect
uniform float blade_curve : hint_range(0.0, 2.0) = 1.0;

// HEIGHT MAP UNIFORMS
uniform sampler2D height_map : filter_nearest;
uniform vec3 chunk_world_pos;
uniform float chunk_size;
uniform float height_scale = 10.0;
uniform float min_terrain_height = 0.3;

// LoD and grass height controls
uniform float lod_height_ratio = 1.0;

// Terrain filtering
uniform float water_level = 0.2;
uniform float sand_level = 0.3;
uniform float grass_level = 0.6;
uniform float rock_level = 0.8;

varying float height_factor;
varying vec3 world_position;
varying vec2 blade_uv;
varying float terrain_height_normalized;
varying float should_render;

// Noise functions for wind only
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;

    for(int i = 0; i < 4; i++) {
        value += amplitude * noise(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

void vertex() {
    // Get world position before transformation
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    blade_uv = UV;
    height_factor = UV.y;
    
    // Sample height map based on position within chunk
    vec3 local_pos = world_position - chunk_world_pos;
    vec2 chunk_uv = (local_pos.xz + vec2(chunk_size * 0.5)) / chunk_size;
    chunk_uv = clamp(chunk_uv, 0.0, 1.0);
    
    // Sample height from the height map (stored in red channel)
    float sampled_height = texture(height_map, chunk_uv).r;
    terrain_height_normalized = sampled_height;
    
    // Calculate actual world height
    float terrain_world_height = sampled_height * height_scale;
    
    // Determine if this grass blade should be rendered
    should_render = 1.0;
    
    // Filter based on terrain type
    if (sampled_height < min_terrain_height) {
        should_render = 0.0;
    }
    
    // Only render on grass-appropriate terrain (between sand and rock)
    if (sampled_height < sand_level || sampled_height >= rock_level) {
        should_render = 0.0;
    }
    
    // Apply ONLY LoD height scaling - NO random variation
    VERTEX.y *= lod_height_ratio;
    
    // Position the grass blade at the terrain height
    VERTEX.y += terrain_world_height;
    
    // Update world position after height adjustment
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    
    // Apply wind animation (keeping blade variation only for wind, not height)
    float blade_variation = hash(world_position.xz * 0.1);

    vec2 wind_dir_norm = normalize(wind_direction);
    vec2 wind_pos = world_position.xz + TIME * wind_speed * wind_dir_norm;

    float base_wind = fbm(wind_pos * 0.02) * 2.0 - 1.0;

    float wave_distance = dot(world_position.xz, wind_dir_norm);
    float wave_phase = wave_distance / wave_size - TIME * wind_speed * 0.5;
    float rolling_wave = sin(wave_phase + blade_variation * 3.14159) * 0.3;

    float turb_x = fbm(wind_pos * 0.1 + vec2(0.0, TIME * 2.0)) * 2.0 - 1.0;
    float turb_z = fbm(wind_pos * 0.1 + vec2(100.0, TIME * 1.5)) * 2.0 - 1.0;

    float gust_phase = TIME * 0.3 + blade_variation * 6.28;
    float gust = (sin(gust_phase) * 0.5 + 0.5) * gust_strength;
    gust = smoothstep(0.6, 1.0, gust);

    float main_wind = (base_wind + rolling_wave) * (1.0 + gust);
    vec2 turbulence_wind = vec2(turb_x, turb_z) * turbulence * 0.3;

    float wind_height_factor = height_factor * height_factor;

    vec3 wind_offset = vec3(
        wind_dir_norm.x * main_wind * wind_strength * wind_height_factor,
        0.0,
        wind_dir_norm.y * main_wind * wind_strength * wind_height_factor
    );

    wind_offset.x += turbulence_wind.x * wind_strength * wind_height_factor;
    wind_offset.z += turbulence_wind.y * wind_strength * wind_height_factor;

    vec3 local_wind_offset = (inverse(MODEL_MATRIX) * vec4(wind_offset, 0.0)).xyz;

    VERTEX += local_wind_offset;
    
    // Scale down or hide grass that shouldn't be rendered
    if (should_render < 0.5) {
        VERTEX *= 0.0; // Make it invisible
    }
}

void fragment() {
    // Discard fragments that shouldn't render
    if (should_render < 0.5) {
        discard;
    }
    
    // Create curved normal for blade depth
    float blade_center = abs(UV.x - 0.5) * 2.0;
    float curve_factor = (1.0 - blade_center) * blade_curve;

    vec3 blade_normal = vec3(
        (UV.x - 0.5) * curve_factor,
        0.0,
        sqrt(1.0 - min(1.0, curve_factor * curve_factor * (UV.x - 0.5) * (UV.x - 0.5) * 4.0))
    );

    blade_normal = normalize(blade_normal);

    // Blend normal with upward-facing normal at tips for specular highlights
    vec3 upward_normal = vec3(0.0, 1.0, 0.0);
    blade_normal = mix(blade_normal, upward_normal, height_factor * normal_tip_blend);

    NORMAL = blade_normal;

    // Enhanced color based on terrain height
    vec3 grass_color = mix(grass_color_base.rgb, grass_color_tip.rgb, height_factor);
    
    // Slightly adjust color based on terrain height for variation
    float height_variation = terrain_height_normalized * 0.1;
    grass_color *= (1.0 + height_variation);

    // Manual transmission calculation
    vec3 view_dir = normalize(VIEW);

    // Calculate transmission factor based on height
    float transmission_factor = height_factor * transmission_strength;

    // Rim lighting for transmission effect
    float rim = 1.0 - max(0.0, dot(NORMAL, view_dir));
    rim = pow(rim, transmission_falloff) * transmission_factor;

    // Backlight transmission
    float backlight_factor = max(0.0, dot(NORMAL, -view_dir)) * transmission_factor;

    // Enhanced backlight effect
    BACKLIGHT = transmission_color.rgb * backlight_strength;

    // Emission for transmission glow
    vec3 transmission_glow = transmission_color.rgb * rim * 0.3;
    transmission_glow += transmission_color.rgb * backlight_factor * 0.2;

    EMISSION = transmission_glow;

    // Basic lighting with center highlight
    float center_highlight = 1.0 - blade_center * 0.2;
    grass_color *= (0.7 + 0.3 * height_factor) * center_highlight;

    // Variable roughness - smoother at tips for better specular highlights
    ROUGHNESS = mix(roughness_base, roughness_tip, height_factor);

    // Lower specular value for more defined highlights
    SPECULAR = specular_strength;

    // No metallic for grass
    METALLIC = 0.0;

    ALBEDO = grass_color;
}
