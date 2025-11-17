@tool
extends Node3D
class_name GrassManager

## Simplified Dynamic Grass System with terrain height positioning

@export_group("Grass Settings")
@export var grass_density: int = 200
@export var grass_height_min: float = 0.3
@export var grass_height_max: float = 0.8
@export var grass_width: float = 0.15

@export_group("Generation Settings")
@export var chunk_size: float = 8.0
@export var view_distance: float = 64.0
@export var update_frequency: float = 1.0
@export var min_terrain_height: float = 0.3

@export_group("Performance")
@export var max_chunks_per_frame: int = 2

@export_group("Shader Settings")
@export var grass_shader: ShaderMaterial

@export_group("Grass Variation")
@export var max_tilt_angle: float = 15.0
@export var tilt_probability: float = 0.7

@export var terrain_generator: Node3D
@export var camera: Camera3D

# Internal variables
var active_chunks: Dictionary = {}
var chunk_generation_queue: Array = []
var last_camera_pos: Vector3
var update_timer: float = 0.0
var grass_mesh_cache: ArrayMesh

func _ready():
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
	
	process_chunk_queue()

func update_grass_around_camera():
	if not camera:
		return
	
	var camera_pos = camera.global_position
	var chunks_to_keep: Dictionary = {}
	
	# Get all chunks in range
	var chunks_in_range = get_chunks_in_range(camera_pos, view_distance)
	
	for chunk_coord in chunks_in_range:
		var chunk_key = str(chunk_coord)
		var chunk_world_pos = chunk_coord_to_world_pos(chunk_coord)
		var distance_to_camera = camera_pos.distance_to(Vector3(chunk_world_pos.x, camera_pos.y, chunk_world_pos.z))
		
		chunks_to_keep[chunk_key] = true
		
		# Check if chunk needs to be created
		if not active_chunks.has(chunk_key):
			# Check if already queued
			var already_queued = false
			for queued_chunk in chunk_generation_queue:
				if queued_chunk.coord == chunk_coord:
					already_queued = true
					break
			
			if not already_queued:
				chunk_generation_queue.append({
					"coord": chunk_coord,
					"world_pos": chunk_world_pos,
					"distance": distance_to_camera
				})
	
	# Remove chunks that are out of range
	var chunks_to_remove = []
	for chunk_key in active_chunks.keys():
		if not chunks_to_keep.has(chunk_key):
			chunks_to_remove.append(chunk_key)
	
	for chunk_key in chunks_to_remove:
		remove_grass_chunk(chunk_key)

func get_chunks_in_range(center: Vector3, max_range: float) -> Array:
	var chunks = []
	var chunk_range = int(ceil(max_range / chunk_size))
	var center_chunk = world_pos_to_chunk_coord(center)
	
	for x in range(-chunk_range, chunk_range + 1):
		for z in range(-chunk_range, chunk_range + 1):
			var chunk_coord = Vector2i(center_chunk.x + x, center_chunk.y + z)
			var chunk_world_pos = chunk_coord_to_world_pos(chunk_coord)
			var distance = center.distance_to(Vector3(chunk_world_pos.x, center.y, chunk_world_pos.z))
			
			if distance <= max_range:
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

func process_chunk_queue():
	var chunks_generated = 0
	
	# Sort queue by distance (closest first)
	chunk_generation_queue.sort_custom(func(a, b): return a.distance < b.distance)
	
	while chunk_generation_queue.size() > 0 and chunks_generated < max_chunks_per_frame:
		var chunk_data = chunk_generation_queue.pop_front()
		create_grass_chunk(chunk_data.coord, chunk_data.world_pos, chunk_data.distance)
		chunks_generated += 1

func create_grass_chunk(chunk_coord: Vector2i, world_pos: Vector3, distance_to_camera: float = 0.0):
	var chunk_key = str(chunk_coord)
	
	# Generate grass positions with proper terrain height sampling
	var grass_positions = generate_grass_positions_with_terrain_height(world_pos)
	
	if grass_positions.is_empty():
		return
	
	# Create MultiMeshInstance3D
	var multi_mesh_instance = MultiMeshInstance3D.new()
	multi_mesh_instance.name = "GrassChunk_" + str(chunk_coord)
	add_child(multi_mesh_instance)
	
	# Create MultiMesh
	var multi_mesh = MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.instance_count = grass_positions.size()
	multi_mesh.mesh = get_grass_mesh()
	
	# Use consistent random seed for this chunk
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(str(chunk_coord))
	
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
		
		var scale_xz = rng.randf_range(0.8, 1.2)
		transform = transform.scaled(Vector3(scale_xz, 1.0, scale_xz))
		
		transform.origin = pos
		multi_mesh.set_instance_transform(i, transform)
	
	multi_mesh_instance.multimesh = multi_mesh
	
	# Create material
	var material = create_grass_material()
	multi_mesh_instance.material_override = material
	
	# Store chunk reference
	active_chunks[chunk_key] = {
		"multimesh": multi_mesh_instance,
		"position": world_pos,
		"coord": chunk_coord,
		"distance": distance_to_camera,
		"density": grass_density
	}

func generate_grass_positions_with_terrain_height(chunk_world_pos: Vector3) -> Array:
	var positions = []
	var half_chunk = chunk_size * 0.5
	
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(str(Vector2i(chunk_world_pos.x, chunk_world_pos.z)))
	
	for i in range(grass_density):
		var local_x = rng.randf_range(-half_chunk, half_chunk)
		var local_z = rng.randf_range(-half_chunk, half_chunk)
		var world_x = chunk_world_pos.x + local_x
		var world_z = chunk_world_pos.z + local_z
		
		# Sample terrain height directly using terrain generator
		var terrain_height = 0.0
		if terrain_generator and terrain_generator.has_method("get_height_at_position"):
			terrain_height = terrain_generator.get_height_at_position(Vector3(world_x, 0, world_z))
			
			# Filter based on terrain height
			var normalized_height = terrain_height / terrain_generator.height_scale
			if normalized_height >= terrain_generator.sand_level and normalized_height < terrain_generator.rock_level:
				positions.append(Vector3(world_x, terrain_height, world_z))
	
	return positions

func get_grass_mesh() -> ArrayMesh:
	if grass_mesh_cache == null:
		grass_mesh_cache = create_grass_mesh()
	return grass_mesh_cache

func create_grass_mesh() -> ArrayMesh:
	var surface_tool = SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var height = 1.0
	var width = grass_width
	var half_width = width * 0.5
	
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

func add_vertex_to_surface(surface_tool: SurfaceTool, vertex_data: Dictionary):
	if vertex_data.has("uv"):
		surface_tool.set_uv(vertex_data.uv)
	if vertex_data.has("color"):
		surface_tool.set_color(vertex_data.color)
	surface_tool.add_vertex(vertex_data.position)

func create_grass_material() -> ShaderMaterial:
	var material = ShaderMaterial.new()
	
	if grass_shader:
		material.shader = grass_shader.shader
		# Copy existing shader parameters
		var shader_params = grass_shader.get_property_list()
		for param in shader_params:
			if param.name.begins_with("shader_parameter/"):
				var param_name = param.name.replace("shader_parameter/", "")
				material.set_shader_parameter(param_name, grass_shader.get_shader_parameter(param_name))
	
	# Set basic shader parameters
	material.set_shader_parameter("grass_height_min", grass_height_min)
	material.set_shader_parameter("grass_height_max", grass_height_max)
	
	return material

func remove_grass_chunk(chunk_key: String):
	if active_chunks.has(chunk_key):
		var chunk_data = active_chunks[chunk_key]
		chunk_data.multimesh.queue_free()
		active_chunks.erase(chunk_key)

func clear_all_grass():
	for chunk_key in active_chunks.keys():
		remove_grass_chunk(chunk_key)
	chunk_generation_queue.clear()
	grass_mesh_cache = null

func get_debug_info() -> String:
	var info = "Grass System Status:\n"
	info += "Chunk Size: %.1f, View Distance: %.1f\n" % [chunk_size, view_distance]
	info += "Active Chunks: %d, Queued: %d, Density: %d\n" % [
		active_chunks.size(), chunk_generation_queue.size(), grass_density
	]
	return info
