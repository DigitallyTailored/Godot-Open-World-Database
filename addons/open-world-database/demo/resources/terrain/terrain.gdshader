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

varying vec3 world_position;
varying vec4 vertex_color;

void vertex() {
    world_position = VERTEX;
    vertex_color = COLOR;
}

void fragment() {
    // Calculate UV coordinates based on world position for texture tiling
    vec2 tiled_uv = world_position.xz / texture_scale;

    // Sample all textures
    vec4 water_tex = texture(water_texture, tiled_uv, -1.0);
    vec4 sand_tex = texture(sand_texture, tiled_uv, -1.0);
    vec4 grass_tex = texture(grass_texture, tiled_uv, -1.0);
    vec4 rock_tex = texture(rock_texture, tiled_uv, -1.0);
    vec4 snow_tex = texture(snow_texture, tiled_uv, -1.0);

    // Extract color components for blending weights
    // We'll use the vertex color to determine which texture to use
    vec3 vc = vertex_color.rgb;

    // Calculate blend weights based on how close the vertex color is to each terrain color
    // You can adjust these reference colors to match your terrain colors
    vec3 water_ref = vec3(0.0, 0.0, 1.0);   // Blue
    vec3 sand_ref = vec3(0.96, 0.64, 0.38);  // Sandy brown
    vec3 grass_ref = vec3(0.0, 1.0, 0.0);    // Green
    vec3 rock_ref = vec3(0.5, 0.5, 0.5);     // Gray
    vec3 snow_ref = vec3(1.0, 1.0, 1.0);     // White

    // Calculate similarity to each terrain type (inverse distance)
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
