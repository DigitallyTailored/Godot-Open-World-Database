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

// LoD height control
uniform float lod_height_ratio = 1.0;
uniform float grass_height_min = 0.3;
uniform float grass_height_max = 0.8;

// Distance-based fade (both width and ground sinking)
uniform float fade_start_distance : hint_range(0.0, 200.0) = 0.0;
uniform float fade_end_distance : hint_range(1.0, 300.0) = 16.0;

varying float height_factor;
varying vec3 world_position;
varying vec2 blade_uv;

// Noise functions for wind
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
    height_factor = UV.y;
    blade_uv = UV;
    
    // Get world position for wind calculations and distance
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    
    // Calculate distance from camera
    vec3 camera_position = INV_VIEW_MATRIX[3].xyz;
    float distance_to_camera = length(world_position - camera_position);
    
    // Calculate distance-based fade factor
    float distance_fade = 1.0;
    if (distance_to_camera > fade_start_distance) {
        distance_fade = 1.0 - smoothstep(fade_start_distance, fade_end_distance, distance_to_camera);
    }
    
    // Apply normal height scaling
    float final_height_scale = mix(grass_height_min, grass_height_max, lod_height_ratio);
    VERTEX.y *= final_height_scale;
    
    // EFFECT 1: Scale blade width based on distance (X axis controls width)
    VERTEX.x *= distance_fade;
    
    // EFFECT 2: Offset grass downward along world Y axis based on distance
    float ground_offset = final_height_scale * (1.0 - distance_fade);
    
    // Transform world Y offset to local space
    vec3 world_offset = vec3(0.0, -ground_offset, 0.0);
    vec3 local_offset = (inverse(MODEL_MATRIX) * vec4(world_offset, 0.0)).xyz;
    VERTEX += local_offset;
    
    // Apply enhanced wind animation to upper vertices (only if grass is visible)
    if (height_factor > 0.01 && distance_fade > 0.01) {
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
        
        // Scale wind effect by distance fade to avoid popping
        wind_offset *= distance_fade;
        
        VERTEX += wind_offset;
    }
}

void fragment() {
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

    // Enhanced color based on height with some variation
    vec3 grass_color = mix(grass_color_base.rgb, grass_color_tip.rgb, height_factor);
    
    // Add subtle variation based on world position
    float position_variation = hash(world_position.xz * 0.1) * 0.1;
    grass_color *= (1.0 + position_variation);

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
