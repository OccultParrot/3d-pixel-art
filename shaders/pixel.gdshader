// Constants
float linear_depth = get_linear_depth(depth);
vec2 texel_size = 1.0 / vec2(size);
vec3 current_normal = get_normal(texel, texel_size);

// Edges
float depth_difference = 0.0;
float normal_difference = 0.0;
for (int i = 0; i < 4; i++) {
    // The neighbors linear depth
    float n_linear = get_linear_depth(neighbor_depths[i]);
    // Outside edges
    depth_difference += linear_depth - n_linear;

    // Normal edges, only compare on continuous surfaces to avoid corrupted normals causing ghost edges
    if (abs(linear_depth - n_linear) < params.depth_threshold) {
        vec2 n_texel = (vec2(snapped_uv) + neighbor_offsets[i] + 0.5) / vec2(size);
        vec3 n_normal = get_normal(n_texel, texel_size);
        normal_difference += 1.0 - dot(current_normal, n_normal);
    }
}

float depth_edge = step(params.depth_threshold, depth_difference);
float normal_edge = step(params.normal_threshold, normal_difference);
float edge = max(depth_edge, normal_edge);


color.rgb = color.rgb * (1.0 - edge * 0.9);