float linear_depth = get_linear_depth(depth);
vec2 texel_size = 1.0 / vec2(size);

// Depth edges
float depth_difference = 0.0;
for (int i = 0; i < 4; i++) {
    depth_difference += linear_depth - get_linear_depth(neighbor_depths[i]);
}
float depth_edge = step(params.depth_threshold, depth_difference);

// Normal edges using G-buffer normals (view-space, packed into [0,1])
vec3 center_normal = texture(normal_roughness_buffer, texel).rgb * 2.0 - 1.0;
float normal_difference = 0.0;
vec2[4] neighbor_texels = vec2[4](
    (vec2(snapped_uv) + vec2( pixel_size,  0.0) + 0.5) / vec2(size),
    (vec2(snapped_uv) + vec2(-pixel_size,  0.0) + 0.5) / vec2(size),
    (vec2(snapped_uv) + vec2( 0.0,  pixel_size) + 0.5) / vec2(size),
    (vec2(snapped_uv) + vec2( 0.0, -pixel_size) + 0.5) / vec2(size)
);
for (int i = 0; i < 4; i++) {
    vec3 neighbor_normal = texture(normal_roughness_buffer, neighbor_texels[i]).rgb * 2.0 - 1.0;
    normal_difference += 1.0 - dot(center_normal, neighbor_normal);
}
float normal_edge = step(params.normal_threshold, normal_difference);

// Skip normal edges on skybox/background (depth == 1.0 means nothing was drawn)
float edge = depth < 1.0 ? max(depth_edge, normal_edge) : 0.0;

// Palette quantization
vec3 color_lab = rgb_to_oklab(color.rgb);
vec4 nearest = palette.colors[0];
float nearest_dist = distance(color_lab, rgb_to_oklab(nearest.rgb));
for (int i = 1; i < palette.colors.length(); i++) {
    float d = distance(color_lab, rgb_to_oklab(palette.colors[i].rgb));
    if (d < nearest_dist) {
        nearest_dist = d;
        nearest = palette.colors[i];
    }
}

color = nearest;
color.rgb = color.rgb * (1.0 - edge * 0.9);

vec3 normal = texture(normal_roughness_buffer, texel).rgb * 2.0 - 1.0;
color = vec4(normal * 0.5 + 0.5, 1.0);