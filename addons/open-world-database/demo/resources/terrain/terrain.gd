@tool
extends Node3D

## Terrain Generator Demo
## Generates a terrain mesh with collision and vertex colors using Godot's built-in noise

@export_group("Terrain Settings")
@export var terrain_size: Vector2i = Vector2i(100, 100)
@export var terrain_scale: Vector2 = Vector2(50.0, 50.0)
@export var height_scale: float = 10.0

@export_group("Noise Settings")
@export var noise_seed: int = 12345
@export var noise_frequency: float = 0.1
@export var noise_octaves: int = 4
@export var noise_lacunarity: float = 2.0
@export var noise_gain: float = 0.5

@export_group("Colors")
@export var water_color: Color = Color.BLUE
@export var sand_color: Color = Color.SANDY_BROWN
@export var grass_color: Color = Color.GREEN
@export var rock_color: Color = Color.GRAY
@export var snow_color: Color = Color.WHITE
@export var material : Material

@export_group("Height Thresholds")
@export var water_level: float = 0.2
@export var sand_level: float = 0.3
@export var grass_level: float = 0.6
@export var rock_level: float = 0.8

@export_group("Generation")
@export var generate_on_ready: bool = true
@export var auto_regenerate: bool = false

var mesh_instance: MeshInstance3D
var collision_shape: CollisionShape3D
var static_body: StaticBody3D
var noise: FastNoiseLite

func _ready():
	if generate_on_ready:
		generate_terrain()

func _validate_property(property):
	if property.name == "auto_regenerate" and auto_regenerate:
		generate_terrain()

@export var regenerate: bool = false : set = _regenerate
func _regenerate(value):
	if value:
		generate_terrain()
		regenerate = false

func generate_terrain():
	#print(multiplayer.get_unique_id(), ": Generating terrain...")
	
	# Clean up existing terrain
	cleanup_terrain()
	
	# Setup noise
	setup_noise()
	
	# Generate mesh using SurfaceTool
	var array_mesh = create_terrain_mesh_with_surface_tool()
	
	# Create mesh instance
	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "TerrainMesh"
	mesh_instance.mesh = array_mesh
	
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Create a material that uses vertex colors
	mesh_instance.material_override = material
	
	add_child(mesh_instance)
	
	# Create collision
	create_collision(array_mesh)
	
	#print(multiplayer.get_unique_id(), ": Terrain generation complete!")

func cleanup_terrain():
	# Explicitly free terrain mesh
	if mesh_instance:
		mesh_instance.queue_free()
		mesh_instance = null
	
	# Explicitly free collision (static body contains the collision shape)
	if static_body:
		static_body.queue_free()
		static_body = null
		collision_shape = null  # Will be freed with static_body

func setup_noise():
	noise = FastNoiseLite.new()
	noise.seed = noise_seed
	noise.frequency = noise_frequency
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_octaves = noise_octaves
	noise.fractal_lacunarity = noise_lacunarity
	noise.fractal_gain = noise_gain
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM

# New function to calculate island mask based on distance from center
# Updated function to ensure edges are always exactly 0
func get_island_mask(x: int, z: int) -> float:
	# Calculate normalized coordinates from -1 to 1
	var norm_x = (float(x) / terrain_size.x) * 2.0 - 1.0
	var norm_z = (float(z) / terrain_size.y) * 2.0 - 1.0
	
	# Use the maximum distance to any edge (not corner)
	# This ensures that when we reach any edge, the mask becomes 0
	var distance_to_edge = max(abs(norm_x), abs(norm_z))
	
	# Return inverted distance (1 at center, 0 at all edges)
	return 1.0 - distance_to_edge

func create_terrain_mesh_with_surface_tool() -> ArrayMesh:
	var surface_tool = SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Create a 2D array to store vertex data for easy access
	var vertex_data = []
	vertex_data.resize(terrain_size.y + 1)
	for z in range(terrain_size.y + 1):
		vertex_data[z] = []
		vertex_data[z].resize(terrain_size.x + 1)
	
	# Generate vertex data
	for z in range(terrain_size.y + 1):
		for x in range(terrain_size.x + 1):
			var world_x = (x - terrain_size.x * 0.5) * terrain_scale.x / terrain_size.x
			var world_z = (z - terrain_size.y * 0.5) * terrain_scale.y / terrain_size.y
			
			# Get height from noise
			var noise_height = noise.get_noise_2d(world_x, world_z)
			noise_height = (noise_height + 1.0) * 0.5  # Normalize to 0-1
			
			# Get island mask (1 at center, 0 at edges)
			var island_mask = get_island_mask(x, z)
			
			# Apply island mask to create island effect
			# The center gets double height (2.0 * island_mask), edges get 0
			var height = noise_height * island_mask * 2.0
			var world_y = height * height_scale
			
			# Store vertex data
			vertex_data[z][x] = {
				"position": Vector3(world_x, world_y, world_z),
				"color": get_terrain_color(height),
				"uv": Vector2(float(x) / terrain_size.x, float(z) / terrain_size.y)
			}
	
	# Generate triangles using SurfaceTool
	for z in range(terrain_size.y):
		for x in range(terrain_size.x):
			# Get the four corners of the current quad
			var v00 = vertex_data[z][x]
			var v10 = vertex_data[z][x + 1]
			var v01 = vertex_data[z + 1][x]
			var v11 = vertex_data[z + 1][x + 1]
			
			# First triangle (counter-clockwise winding)
			add_vertex_to_surface(surface_tool, v00)
			add_vertex_to_surface(surface_tool, v10)
			add_vertex_to_surface(surface_tool, v01)
			
			# Second triangle (counter-clockwise winding)
			add_vertex_to_surface(surface_tool, v10)
			add_vertex_to_surface(surface_tool, v11)
			add_vertex_to_surface(surface_tool, v01)
	
	# Generate normals automatically
	surface_tool.generate_normals()
	
	# Optionally generate tangents if you need them for normal mapping
	# surface_tool.generate_tangents()
	
	# Create and return the mesh
	var array_mesh = surface_tool.commit()
	return array_mesh

func add_vertex_to_surface(surface_tool: SurfaceTool, vertex_info: Dictionary):
	# Set vertex attributes in the correct order
	surface_tool.set_color(vertex_info.color)
	surface_tool.set_uv(vertex_info.uv)
	surface_tool.add_vertex(vertex_info.position)

func get_terrain_color(height: float) -> Color:
	if height < water_level:
		return water_color
	elif height < sand_level:
		# Blend between water and sand
		var t = (height - water_level) / (sand_level - water_level)
		return water_color.lerp(sand_color, t)
	elif height < grass_level:
		# Blend between sand and grass
		var t = (height - sand_level) / (grass_level - sand_level)
		return sand_color.lerp(grass_color, t)
	elif height < rock_level:
		# Blend between grass and rock
		var t = (height - grass_level) / (rock_level - grass_level)
		return grass_color.lerp(rock_color, t)
	else:
		# Blend between rock and snow
		var t = (height - rock_level) / (1.0 - rock_level)
		return rock_color.lerp(snow_color, t)

func create_collision(array_mesh: ArrayMesh):
	# Create static body for collision
	static_body = StaticBody3D.new()
	static_body.name = "TerrainCollision"
	add_child(static_body)
	
	# Create collision shape
	collision_shape = CollisionShape3D.new()
	collision_shape.name = "TerrainShape"
	static_body.add_child(collision_shape)
	
	# Create trimesh collision shape from the mesh
	var shape = array_mesh.create_trimesh_shape()
	collision_shape.shape = shape
	
	#print(multiplayer.get_unique_id(), ": Collision shape created with ", shape.get_faces().size() / 3, " triangles")

# Updated utility function to get terrain height at world position
func get_height_at_position(world_pos: Vector3) -> float:
	if not noise:
		return 0.0
	
	# Convert world position back to grid coordinates for mask calculation
	var grid_x_float = (world_pos.x * terrain_size.x / terrain_scale.x) + terrain_size.x * 0.5
	var grid_z_float = (world_pos.z * terrain_size.y / terrain_scale.y) + terrain_size.y * 0.5
	
	var grid_x = int(grid_x_float)
	var grid_z = int(grid_z_float)
	
	# Clamp to valid range
	grid_x = clamp(grid_x, 0, terrain_size.x)
	grid_z = clamp(grid_z, 0, terrain_size.y)
	
	var noise_height = noise.get_noise_2d(world_pos.x, world_pos.z)
	noise_height = (noise_height + 1.0) * 0.5  # Normalize to 0-1
	
	var island_mask = get_island_mask(grid_x, grid_z)
	var height = noise_height * island_mask * 2.0
	
	return height * height_scale

# NEW FUNCTION: Generate height map for a specific chunk
func generate_height_map_for_chunk(chunk_world_pos: Vector3, chunk_size_param: float, resolution: int) -> ImageTexture:
	if not noise:
		setup_noise()
	
	var image = Image.create(resolution, resolution, false, Image.FORMAT_RF)
	var half_chunk = chunk_size_param * 0.5
	
	for y in range(resolution):
		for x in range(resolution):
			# Convert pixel coordinates to world position within the chunk
			var local_x = (float(x) / (resolution - 1)) * chunk_size_param - half_chunk
			var local_z = (float(y) / (resolution - 1)) * chunk_size_param - half_chunk
			var world_x = chunk_world_pos.x + local_x
			var world_z = chunk_world_pos.z + local_z
			
			# Get height from noise
			var noise_height = noise.get_noise_2d(world_x, world_z)
			noise_height = (noise_height + 1.0) * 0.5  # Normalize to 0-1
			
			# Convert world position back to grid coordinates for mask calculation
			var grid_x_float = (world_x * terrain_size.x / terrain_scale.x) + terrain_size.x * 0.5
			var grid_z_float = (world_z * terrain_size.y / terrain_scale.y) + terrain_size.y * 0.5
			
			var grid_x = int(grid_x_float)
			var grid_z = int(grid_z_float)
			
			# Clamp to valid range
			grid_x = clamp(grid_x, 0, terrain_size.x)
			grid_z = clamp(grid_z, 0, terrain_size.y)
			
			# Get island mask and apply it
			var island_mask = get_island_mask(grid_x, grid_z)
			var height = noise_height * island_mask * 2.0
			var world_y = height * height_scale
			
			# Store height as red channel (0-1 normalized)
			var normalized_height = height  # Already 0-1 from the calculation above
			image.set_pixel(x, y, Color(normalized_height, 0, 0, 1))
	
	var texture = ImageTexture.new()
	texture.set_image(image)
	return texture

# NEW FUNCTION: Get terrain type at normalized height (for shader)
func get_terrain_type_at_height(normalized_height: float) -> float:
	# Return a value that the shader can use to determine terrain type
	# 0.0 = water, 0.25 = sand, 0.5 = grass, 0.75 = rock, 1.0 = snow
	if normalized_height < water_level:
		return 0.0
	elif normalized_height < sand_level:
		return 0.25
	elif normalized_height < grass_level:
		return 0.5
	elif normalized_height < rock_level:
		return 0.75
	else:
		return 1.0
