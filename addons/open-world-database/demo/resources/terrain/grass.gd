@tool
extends Node3D
class_name GrassManager

## Dynamic Grass System with Height Map-based positioning
## Uses height maps per chunk instead of individual height sampling

@export_group("Grass Settings")
@export var grass_density: int = 200
@export var grass_height_min: float = 0.3
@export var grass_height_max: float = 0.8
@export var grass_width: float = 0.15

@export_group("Generation Settings")
@export var chunk_size: float = 8.0
@export var view_distance: float = 64.0
@export var update_frequency: float = 1.0
@export var height_map_resolution: int = 32  # Resolution of height map per chunk
@export var min_terrain_height: float = 0.3

@export_group("Performance")
@export var max_chunks_per_frame: int = 2

@export_group("LoD Settings")
@export var enable_lod: bool = true

@export_group("Shader Settings")
@export var grass_shader: ShaderMaterial

@export_group("Grass Variation")
@export var max_tilt_angle: float = 15.0
@export var tilt_probability: float = 0.7

@export var terrain_generator: Node3D
@export var camera: Camera3D

# LoD level configurations
var lod_configs = [
	{
		"name": "High",
		"density_ratio": 1.0,
		"height_ratio": 0.25,
		"range_end": 0.4,
		"color": Color.GREEN
	},
	{
		"name": "Medium", 
		"density_ratio": 0.6,
		"height_ratio": 0.5,
		"range_end": 0.75,
		"color": Color.YELLOW
	},
	{
		"name": "Low",
		"density_ratio": 0.3,
		"height_ratio": 1.0,
		"range_end": 1.0,
		"color": Color.RED
	}
]

# Internal variables
var active_chunks_by_lod: Array[Dictionary] = []
var chunk_generation_queues: Array[Array] = []
var last_camera_pos: Vector3
var update_timer: float = 0.0

# Cache for grass meshes by LoD level to avoid regenerating them
var grass_mesh_cache: Array[ArrayMesh] = []

func _ready():
	# Initialize arrays for each LoD level
	active_chunks_by_lod.resize(lod_configs.size())
	chunk_generation_queues.resize(lod_configs.size())
	grass_mesh_cache.resize(lod_configs.size())
	
	for i in range(lod_configs.size()):
		active_chunks_by_lod[i] = {}
		chunk_generation_queues[i] = []
		grass_mesh_cache[i] = null
	
	if not camera:
		if Engine.is_editor_hint():
			var viewport = EditorInterface.get_editor_viewport_3d(0)
			camera = viewport.get_camera_3d()
		else:
			camera = get_viewport().get_camera_3d()
	
	if camera:
		last_camera_pos = camera.global_position
		call_deferred("update_grass_around_camera")

func _process(delta):
	if not camera or not terrain_generator:
		return
	
	update_timer += delta
	
	var camera_pos = camera.global_position
	var camera_moved = last_camera_pos.distance_squared_to(camera_pos) > pow(chunk_size * 0.25, 2)

	if camera_moved or update_timer >= update_frequency:
		update_grass_around_camera()
		last_camera_pos = camera_pos
		update_timer = 0.0
	
	process_all_chunk_queues()

func get_density_for_lod(lod_level: int) -> int:
	return int(grass_density * lod_configs[lod_level].density_ratio)

func get_height_ratio_for_lod(lod_level: int) -> float:
	return lod_configs[lod_level].height_ratio

func get_view_distance_for_lod(lod_level: int) -> float:
	return view_distance * lod_configs[lod_level].range_end

func update_grass_around_camera():
	if not camera or not enable_lod:
		return
	
	var camera_pos = camera.global_position
	
	# Process each LoD level separately
	for lod_level in range(lod_configs.size()):
		update_lod_level(lod_level, camera_pos)

func update_lod_level(lod_level: int, camera_pos: Vector3):
	var config = lod_configs[lod_level]
	var lod_view_distance = get_view_distance_for_lod(lod_level)
	var range_end = view_distance * config.range_end
	
	var chunks_to_keep: Dictionary = {}
	var active_chunks = active_chunks_by_lod[lod_level]
	var generation_queue = chunk_generation_queues[lod_level]
	
	# Get chunks from camera position to the LoD's max range
	var chunks_in_range = get_chunks_in_range_for_lod(camera_pos, lod_view_distance, range_end)
	
	for chunk_coord in chunks_in_range:
		var chunk_key = str(chunk_coord) + "_lod" + str(lod_level)
		var chunk_world_pos = chunk_coord_to_world_pos(chunk_coord)
		var distance_to_camera = camera_pos.distance_to(Vector3(chunk_world_pos.x, camera_pos.y, chunk_world_pos.z))
		
		chunks_to_keep[chunk_key] = true
		
		# Check if chunk needs to be created
		if not active_chunks.has(chunk_key):
			# Check if already queued
			var already_queued = false
			for queued_chunk in generation_queue:
				if queued_chunk.coord == chunk_coord:
					already_queued = true
					break
			
			if not already_queued:
				generation_queue.append({
					"coord": chunk_coord,
					"world_pos": chunk_world_pos,
					"distance": distance_to_camera,
					"lod_level": lod_level
				})
	
	# Remove chunks that are out of range for this LoD level
	var chunks_to_remove = []
	for chunk_key in active_chunks.keys():
		if not chunks_to_keep.has(chunk_key):
			chunks_to_remove.append(chunk_key)
	
	for chunk_key in chunks_to_remove:
		remove_grass_chunk_from_lod(lod_level, chunk_key)

func get_chunks_in_range_for_lod(center: Vector3, max_range: float, range_end: float) -> Array:
	var chunks = []
	var chunk_range = int(ceil(range_end / chunk_size))
	var center_chunk = world_pos_to_chunk_coord(center)
	
	for x in range(-chunk_range, chunk_range + 1):
		for z in range(-chunk_range, chunk_range + 1):
			var chunk_coord = Vector2i(center_chunk.x + x, center_chunk.y + z)
			var chunk_world_pos = chunk_coord_to_world_pos(chunk_coord)
			var distance = center.distance_to(Vector3(chunk_world_pos.x, center.y, chunk_world_pos.z))
			
			# Each LoD level renders from 0 to its max range (stacking/additive)
			if distance <= range_end:
				chunks.append(chunk_coord)
	
	return chunks

func world_pos_to_chunk_coord(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(world_pos.x / chunk_size)),
		int(floor(world_pos.z / chunk_size))
	)

func chunk_coord_to_world_pos(chunk_coord: Vector2i) -> Vector3:
	return Vector3(
		chunk_coord.x * chunk_size + chunk_size * 0.5,
		0,
		chunk_coord.y * chunk_size + chunk_size * 0.5
	)

func process_all_chunk_queues():
	var total_chunks_generated = 0
	
	# Process queues in order of priority (closest LoD first)
	for lod_level in range(lod_configs.size()):
		if total_chunks_generated >= max_chunks_per_frame:
			break
			
		var generation_queue = chunk_generation_queues[lod_level]
		
		# Sort queue by distance (closest first)
		generation_queue.sort_custom(func(a, b): return a.distance < b.distance)
		
		while generation_queue.size() > 0 and total_chunks_generated < max_chunks_per_frame:
			var chunk_data = generation_queue.pop_front()
			create_grass_chunk_for_lod(chunk_data.lod_level, chunk_data.coord, chunk_data.world_pos, chunk_data.distance)
			total_chunks_generated += 1

func create_grass_chunk_for_lod(lod_level: int, chunk_coord: Vector2i, world_pos: Vector3, distance_to_camera: float = 0.0):
	var config = lod_configs[lod_level]
	var chunk_key = str(chunk_coord) + "_lod" + str(lod_level)
	var chunk_density = get_density_for_lod(lod_level)
	var height_ratio = get_height_ratio_for_lod(lod_level)
	
	# Generate uniform grass positions (no terrain height sampling here)
	var grass_positions = generate_uniform_grass_positions_in_chunk(world_pos, chunk_density, lod_level)
	
	if grass_positions.is_empty():
		return
	
	# Generate height map for this chunk
	var height_map = generate_height_map_for_chunk(world_pos)
	
	# Create MultiMeshInstance3D with LoD-specific naming
	var multi_mesh_instance = MultiMeshInstance3D.new()
	multi_mesh_instance.name = "GrassChunk_" + config.name + "_" + str(chunk_coord) + "_D" + str(chunk_density) + "_H" + str(height_ratio)
	add_child(multi_mesh_instance)
	
	# Create MultiMesh with cached mesh for this LoD level
	var multi_mesh = MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.instance_count = grass_positions.size()
	multi_mesh.mesh = get_grass_mesh_for_lod(lod_level)
	
	# Use consistent random seed for this chunk
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(str(chunk_coord) + str(lod_level))
	
	# Set transforms for each grass instance
	for i in range(grass_positions.size()):
		var pos = grass_positions[i]
		var transform = Transform3D()
		
		# Random Y-axis rotation
		var rotation_y = rng.randf() * TAU
		transform = transform.rotated(Vector3.UP, rotation_y)
		
		# Random tilting
		if rng.randf() < tilt_probability:
			var tilt_direction = Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
			var tilt_angle = rng.randf_range(0, deg_to_rad(max_tilt_angle))
			
			var tilt_x = tilt_direction.y * tilt_angle
			var tilt_z = tilt_direction.x * tilt_angle
			
			transform = transform.rotated(Vector3.RIGHT, tilt_x)
			transform = transform.rotated(Vector3.FORWARD, tilt_z)
		
		# FIXED: Only apply XZ scaling, NO Y scaling - let shader handle height
		var scale_xz = rng.randf_range(0.8, 1.2)  # Simplified XZ variation
		transform = transform.scaled(Vector3(scale_xz, 1.0, scale_xz))  # Y scale = 1.0 (no change)
		
		transform.origin = pos
		multi_mesh.set_instance_transform(i, transform)
	
	multi_mesh_instance.multimesh = multi_mesh
	
	# Create material and pass height map to shader
	var material = create_grass_material_with_height_map(height_map, world_pos, height_ratio)
	multi_mesh_instance.material_override = material
	
	# Store chunk reference
	active_chunks_by_lod[lod_level][chunk_key] = {
		"multimesh": multi_mesh_instance,
		"position": world_pos,
		"coord": chunk_coord,
		"lod_level": lod_level,
		"distance": distance_to_camera,
		"density": chunk_density,
		"height_ratio": height_ratio,
		"height_map": height_map
	}


# NEW: Generate uniform grass positions without terrain sampling
func generate_uniform_grass_positions_in_chunk(chunk_world_pos: Vector3, density: int, lod_level: int) -> Array:
	var positions = []
	var half_chunk = chunk_size * 0.5
	
	# Include LoD level in seed to ensure different positions per LoD
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(str(Vector2i(chunk_world_pos.x, chunk_world_pos.z)) + "_lod" + str(lod_level))
	
	# Generate uniform random positions - all at ground level (y=0)
	# The shader will handle height positioning
	for i in range(density):
		var local_x = rng.randf_range(-half_chunk, half_chunk)
		var local_z = rng.randf_range(-half_chunk, half_chunk)
		var world_x = chunk_world_pos.x + local_x
		var world_z = chunk_world_pos.z + local_z
		
		# Start all grass at y=0, shader will position them correctly
		positions.append(Vector3(world_x, 0, world_z))
	
	return positions

# NEW: Generate height map for a chunk
func generate_height_map_for_chunk(chunk_world_pos: Vector3) -> ImageTexture:
	if terrain_generator and terrain_generator.has_method("generate_height_map_for_chunk"):
		return terrain_generator.generate_height_map_for_chunk(chunk_world_pos, chunk_size, height_map_resolution)
	else:
		# Fallback: create a flat height map
		var image = Image.create(height_map_resolution, height_map_resolution, false, Image.FORMAT_RF)
		image.fill(Color(0.5, 0, 0, 1))  # Neutral height
		var texture = ImageTexture.new()
		texture.set_image(image)
		return texture

# NEW: Get or create grass mesh for specific LoD level (cached)
func get_grass_mesh_for_lod(lod_level: int) -> ArrayMesh:
	if grass_mesh_cache[lod_level] == null:
		grass_mesh_cache[lod_level] = create_consistent_grass_mesh()
	return grass_mesh_cache[lod_level]

# Helper function to add vertex data to surface tool
func add_vertex_to_surface(surface_tool: SurfaceTool, vertex_data: Dictionary):
	if vertex_data.has("uv"):
		surface_tool.set_uv(vertex_data.uv)
	if vertex_data.has("color"):
		surface_tool.set_color(vertex_data.color)
	surface_tool.add_vertex(vertex_data.position)

# UPDATED: Create perfectly consistent grass blade mesh
func create_consistent_grass_mesh() -> ArrayMesh:
	var surface_tool = SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Use fixed height - no randomization at all
	var height = grass_height_max  # Always use max height, shader handles scaling
	var width = grass_width
	var half_width = width * 0.5
	
	# Create exactly the same grass blade every time
	var vertex_data = [
		{"position": Vector3(-half_width, 0, 0), "uv": Vector2(0, 0)},
		{"position": Vector3(half_width, 0, 0), "uv": Vector2(1, 0)},
		{"position": Vector3(-half_width + width * 0.1, height * 0.33, 0), "uv": Vector2(0.1, 0.33)},
		{"position": Vector3(half_width - width * 0.1, height * 0.33, 0), "uv": Vector2(0.9, 0.33)},
		{"position": Vector3(-half_width + width * 0.2, height * 0.66, 0), "uv": Vector2(0.2, 0.66)},
		{"position": Vector3(half_width - width * 0.2, height * 0.66, 0), "uv": Vector2(0.8, 0.66)},
		{"position": Vector3(0, height, 0), "uv": Vector2(0.5, 1.0)}
	]
	
	# Front face triangles
	add_vertex_to_surface(surface_tool, vertex_data[0])
	add_vertex_to_surface(surface_tool, vertex_data[2])
	add_vertex_to_surface(surface_tool, vertex_data[1])
	
	add_vertex_to_surface(surface_tool, vertex_data[1])
	add_vertex_to_surface(surface_tool, vertex_data[2])
	add_vertex_to_surface(surface_tool, vertex_data[3])
	
	add_vertex_to_surface(surface_tool, vertex_data[2])
	add_vertex_to_surface(surface_tool, vertex_data[4])
	add_vertex_to_surface(surface_tool, vertex_data[3])
	
	add_vertex_to_surface(surface_tool, vertex_data[3])
	add_vertex_to_surface(surface_tool, vertex_data[4])
	add_vertex_to_surface(surface_tool, vertex_data[5])
	
	add_vertex_to_surface(surface_tool, vertex_data[4])
	add_vertex_to_surface(surface_tool, vertex_data[6])
	add_vertex_to_surface(surface_tool, vertex_data[5])
	
	# Back face triangles (reversed winding)
	var back_vertex_data = []
	for i in range(vertex_data.size()):
		var back_vertex = vertex_data[i].duplicate()
		back_vertex.position = Vector3(vertex_data[i].position.x, vertex_data[i].position.y, vertex_data[i].position.z - 0.001)
		back_vertex_data.push_back(back_vertex)
	
	add_vertex_to_surface(surface_tool, back_vertex_data[0])
	add_vertex_to_surface(surface_tool, back_vertex_data[1])
	add_vertex_to_surface(surface_tool, back_vertex_data[2])
	
	add_vertex_to_surface(surface_tool, back_vertex_data[1])
	add_vertex_to_surface(surface_tool, back_vertex_data[3])
	add_vertex_to_surface(surface_tool, back_vertex_data[2])
	
	add_vertex_to_surface(surface_tool, back_vertex_data[2])
	add_vertex_to_surface(surface_tool, back_vertex_data[3])
	add_vertex_to_surface(surface_tool, back_vertex_data[4])
	
	add_vertex_to_surface(surface_tool, back_vertex_data[3])
	add_vertex_to_surface(surface_tool, back_vertex_data[5])
	add_vertex_to_surface(surface_tool, back_vertex_data[4])
	
	add_vertex_to_surface(surface_tool, back_vertex_data[4])
	add_vertex_to_surface(surface_tool, back_vertex_data[5])
	add_vertex_to_surface(surface_tool, back_vertex_data[6])
	
	surface_tool.generate_normals()
	return surface_tool.commit()


# UPDATED: Create grass material with height map and height ratio
func create_grass_material_with_height_map(height_map: ImageTexture, chunk_world_pos: Vector3, height_ratio: float) -> ShaderMaterial:
	var material = ShaderMaterial.new()
	
	if grass_shader:
		material.shader = grass_shader.shader
		# Copy all existing shader parameters
		var shader_params = grass_shader.get_property_list()
		for param in shader_params:
			if param.name.begins_with("shader_parameter/"):
				var param_name = param.name.replace("shader_parameter/", "")
				material.set_shader_parameter(param_name, grass_shader.get_shader_parameter(param_name))
	
	# Set height map specific parameters
	material.set_shader_parameter("height_map", height_map)
	material.set_shader_parameter("chunk_world_pos", chunk_world_pos)
	material.set_shader_parameter("chunk_size", chunk_size)
	material.set_shader_parameter("height_scale", terrain_generator.height_scale if terrain_generator else 10.0)
	material.set_shader_parameter("min_terrain_height", min_terrain_height)
	material.set_shader_parameter("lod_height_ratio", height_ratio)  # NEW: Pass height ratio to shader
	material.set_shader_parameter("grass_height_min", grass_height_min)  # NEW
	material.set_shader_parameter("grass_height_max", grass_height_max)  # NEW
	
	# Terrain level thresholds for grass filtering
	if terrain_generator:
		material.set_shader_parameter("water_level", terrain_generator.water_level)
		material.set_shader_parameter("sand_level", terrain_generator.sand_level)
		material.set_shader_parameter("grass_level", terrain_generator.grass_level)
		material.set_shader_parameter("rock_level", terrain_generator.rock_level)
	
	return material

func remove_grass_chunk_from_lod(lod_level: int, chunk_key: String):
	var active_chunks = active_chunks_by_lod[lod_level]
	if active_chunks.has(chunk_key):
		var chunk_data = active_chunks[chunk_key]
		chunk_data.multimesh.queue_free()
		active_chunks.erase(chunk_key)

func clear_all_grass():
	for lod_level in range(lod_configs.size()):
		for chunk_key in active_chunks_by_lod[lod_level].keys():
			remove_grass_chunk_from_lod(lod_level, chunk_key)
		chunk_generation_queues[lod_level].clear()
		# Clear mesh cache
		grass_mesh_cache[lod_level] = null

# Debug function to show LoD levels
func get_debug_info() -> String:
	var info = "Height Map-based LoD System Status:\n"
	info += "Chunk Size: %.1f, View Distance: %.1f, Height Map Resolution: %d\n" % [chunk_size, view_distance, height_map_resolution]
	for i in range(lod_configs.size()):
		var config = lod_configs[i]
		var chunk_count = active_chunks_by_lod[i].size()
		var queue_count = chunk_generation_queues[i].size()
		var range_end = view_distance * config.range_end
		info += "LoD %d (%s): %d chunks, %d queued, density=%d, height=%.1fx, range=0.0-%.1f\n" % [
			i, config.name, chunk_count, queue_count, 
			get_density_for_lod(i), config.height_ratio, range_end
		]
	return info
