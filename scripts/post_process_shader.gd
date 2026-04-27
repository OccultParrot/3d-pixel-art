@tool
extends CompositorEffect
class_name PostProcessShader

const template_shader: String = """
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// binding 0: depth, binding 1: color, binding 2: palette, binding 3: normal/roughness
layout(set = 0, binding = 0) uniform sampler2D depth_buffer;
layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;

// Our push constant
layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float pixel_size;
	float depth_threshold;
	float normal_threshold;
} params;

// The palette constant
layout(set = 0, binding = 2) readonly buffer Palette {
    vec4 colors[];
} palette;

layout(set = 0, binding = 3) uniform sampler2D normal_roughness_buffer;

vec3 rgb_to_oklab(vec3 c) {
    // Linear RGB to LMS cone responses
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;

    // Cube root
    float l_ = pow(l, 1.0 / 3.0);
    float m_ = pow(m, 1.0 / 3.0);
    float s_ = pow(s, 1.0 / 3.0);

    return vec3(
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    );
}

float get_linear_depth(float raw_depth) {
    float z_near = 0.05;
    float z_far = 100.0;
    return (1.0 - raw_depth) * (z_far - z_near) + z_near;
}

vec3 get_raw_normal(vec2 texel) {
	return texture(normal_roughness_buffer, texel).rgb * 2.0 - 1.0;
}

vec3 get_clean_normal(vec3 raw_normal) {
	return raw_normal * 0.5 + 0.5;
}

// The code we want to execute in each invocation
void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	int pixel_size = int(params.pixel_size);
	ivec2 snapped_uv = (uv / pixel_size) * pixel_size;
	vec2 texel = (vec2(snapped_uv) + 0.5) / vec2(size);
	float depth = texture(depth_buffer, texel).r;

	vec4 color = imageLoad(color_image, snapped_uv);

    vec2 neighbor_offsets[4] = vec2[4](
        vec2( pixel_size,  0),
        vec2(-pixel_size,  0),
        vec2( 0,  pixel_size),
        vec2( 0, -pixel_size)
    );

    float neighbor_depths[4];
    for (int i = 0; i < 4; i++) {
        vec2 neighbor_texel = (vec2(snapped_uv) + neighbor_offsets[i] + 0.5) / vec2(size);
        neighbor_depths[i] = texture(depth_buffer, neighbor_texel).r;
    }

	vec3 neighbor_normals[4];
	for (int i = 0; i < 4; i++) {
		vec2 neighbor_texel = (vec2(snapped_uv) + neighbor_offsets[i] + 0.5) / vec2(size);
		neighbor_normals[i] = get_raw_normal(neighbor_texel);
	}

	#COMPUTE_CODE

	imageStore(color_image, uv, color);
}
"""


@export_multiline var shader_code: String = "":
	set(value):
		mutex.lock()
		shader_code = value
		shader_is_dirty = true
		mutex.unlock()


var rd: RenderingDevice
var shader: RID
var pipeline: RID

var mutex: Mutex = Mutex.new()
var shader_is_dirty = true

@export var pixel_size: int = 4:
	set(value):
		pixel_size = value

@export_range(0.0, 1.0) var depth_threshold: float = 0.05:
	set(value):
		depth_threshold = value

@export_range(0.0, 1.0) var normal_threshold: float = 0.05:
	set(value):
		normal_threshold = value

@export var palette: Array[Color] = []:
	set(value):
		palette = value
		palette_is_dirty = true

var palette_buffer: RID
var palette_is_dirty = true
var depth_sampler: RID
var normal_sampler: RID


func _update_palette_buffer():
	if not rd:
		return
	if palette_buffer.is_valid():
		rd.free_rid(palette_buffer)
	
	var data = PackedFloat32Array()
	var colors_to_use = palette if not palette.is_empty() else [Color.WHITE]
	for c in colors_to_use:
		var linear = c.srgb_to_linear()
		data.push_back(linear.r)
		data.push_back(linear.g)
		data.push_back(linear.b)
		data.push_back(linear.a)

	palette_buffer = rd.storage_buffer_create(data.size() * 4, data.to_byte_array())
	palette_is_dirty = false


# Hex file import stuff

@export_file("*.hex") var hex_file_path: String = ""

@export_tool_button("Import Hex Palette") var _import_button = _import_hex_palette

func _import_hex_palette():
	if hex_file_path.is_empty():
		push_error("No hex file path set")

	var file = FileAccess.open(hex_file_path, FileAccess.READ)
	if not file:
		push_error("Could not open file: " + hex_file_path)
		return
	
	var new_palette: Array[Color] = []

	while not file.eof_reached():
		var line = file.get_line().strip_edges()
		if line.is_empty():
			continue
		if not line.begins_with("#"):
			line = "#" + line
		
		new_palette.append(Color(line))
	
	palette = new_palette
	palette_is_dirty = true

func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE
	access_resolved_depth = true
	needs_normal_roughness = true
	rd = RenderingServer.get_rendering_device()

	
func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if shader.is_valid():
			rd.free_rid(shader)
		if palette_buffer.is_valid():
			rd.free_rid(palette_buffer)
		if depth_sampler.is_valid():
			rd.free_rid(depth_sampler)
		if normal_sampler.is_valid():
			rd.free_rid(normal_sampler)

func _check_shader() -> bool:
	if not rd:
		return false
	
	var new_shader_code: String = ""

	mutex.lock()
	if shader_is_dirty:
		new_shader_code = shader_code
		shader_is_dirty = false
	mutex.unlock()

	if new_shader_code.is_empty():
		return pipeline.is_valid()
	
	new_shader_code = template_shader.replace("#COMPUTE_CODE", new_shader_code);

	if shader.is_valid():
		rd.free_rid(shader)
		shader = RID()
		pipeline = RID()

	var shader_source: RDShaderSource = RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = new_shader_code
	var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source)

	if shader_spirv.compile_error_compute != "":
		push_error(shader_spirv.compile_error_compute)
		push_error("In: " + new_shader_code)
		return false

	shader = rd.shader_create_from_spirv(shader_spirv)
	if not shader.is_valid():
		return false

	pipeline = rd.compute_pipeline_create(shader)
	return pipeline.is_valid()

func _render_callback(p_effect_callback_type, p_render_data):
	if rd and p_effect_callback_type == EFFECT_CALLBACK_TYPE_POST_OPAQUE and _check_shader():
		# Create samplers lazily the first time they're needed
		if not depth_sampler.is_valid():
			depth_sampler = rd.sampler_create(RDSamplerState.new())
		if not normal_sampler.is_valid():
			normal_sampler = rd.sampler_create(RDSamplerState.new())

		var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()

		if render_scene_buffers:
			var size = render_scene_buffers.get_internal_size()
			if size.x == 0 and size.y == 0:
				return
			
			var x_groups = (size.x - 1) / 8 + 1
			var y_groups = (size.y - 1) / 8 + 1
			var z_groups = 1

			var push_constant: PackedFloat32Array = PackedFloat32Array()

			push_constant.push_back(size.x)
			push_constant.push_back(size.y)
			push_constant.push_back(float(pixel_size))
			push_constant.push_back(depth_threshold)
			push_constant.push_back(normal_threshold)
			push_constant.push_back(0.0)
			push_constant.push_back(0.0)
			push_constant.push_back(0.0)

			if palette_is_dirty:
				_update_palette_buffer()

			var view_count = render_scene_buffers.get_view_count()
			for view in range(view_count):
				# binding 0: depth buffer
				var depth_image = render_scene_buffers.get_depth_layer(view)
				var depth_uniform: RDUniform = RDUniform.new()
				depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				depth_uniform.binding = 0
				depth_uniform.add_id(depth_sampler)
				depth_uniform.add_id(depth_image)

				# binding 1: color image
				var color_uniform: RDUniform = RDUniform.new()
				color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				color_uniform.binding = 1
				color_uniform.add_id(render_scene_buffers.get_color_layer(view))

				# binding 2: palette
				var palette_uniform: RDUniform = RDUniform.new()
				palette_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				palette_uniform.binding = 2
				palette_uniform.add_id(palette_buffer)

				# binding 3: normal roughness
				# binding 3: normal roughness
				var normal_image = render_scene_buffers.get_texture_slice("forward_clustered", "normal_roughness", view, 0, 1, 1)
				if not normal_image.is_valid():
					push_error("Could not get normal_roughness texture - is the renderer set to Forward+?")
					return
				var normal_uniform: RDUniform = RDUniform.new()
				normal_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				normal_uniform.binding = 3
				normal_uniform.add_id(normal_sampler)
				normal_uniform.add_id(normal_image)

				var uniform_set = UniformSetCacheRD.get_cache(shader, 0, [depth_uniform, color_uniform, palette_uniform, normal_uniform])

				var compute_list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
				rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
				rd.compute_list_end()