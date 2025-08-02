#open_world_database.gd
@tool
extends Node
class_name OpenWorldDatabase

enum Size { SMALL, MEDIUM, LARGE, ALWAYS_LOADED }

@export var size_thresholds: Array[float] = [0.5, 2.0, 8.0]
@export var chunk_sizes: Array[float] = [8.0, 16.0, 64.0]
@export var chunk_load_range: int = 3
@export var debug_enabled: bool = false
@export var camera: Node

@export_tool_button("debug info", "Debug") var debug_action = debug

var chunk_lookup: Dictionary = {} # [Size][Vector2i] -> Array[String] (UIDs)
var database: Database
var chunk_manager: ChunkManager
var node_monitor: NodeMonitor
var node_handler: NodeHandler
var is_loading: bool = false

func _ready() -> void:
	if Engine.is_editor_hint():
		get_tree().auto_accept_quit = false
	
	reset()
	is_loading = true
	database.load_database()
	is_loading = false

func reset():
	is_loading = true
	NodeUtils.remove_children(self)
	chunk_manager = ChunkManager.new(self)
	node_monitor = NodeMonitor.new(self)
	database = Database.new(self)
	node_handler = NodeHandler.new(self)
	setup_listeners(self)
	is_loading = false

func setup_listeners(node: Node):
	if not node.child_entered_tree.is_connected(_on_child_entered_tree):
		node.child_entered_tree.connect(_on_child_entered_tree)
	
	if not node.child_exiting_tree.is_connected(_on_child_exiting_tree):
		node.child_exiting_tree.connect(_on_child_exiting_tree)

func _on_child_entered_tree(node: Node):
	node_handler.handle_child_entered_tree(node)

func _on_child_exiting_tree(node: Node):
	node_handler.handle_child_exiting_tree(node)

func get_all_owd_nodes() -> Array[Node]:
	return get_tree().get_nodes_in_group("owdb")

func get_node_by_uid(uid: String) -> Node:
	for node in get_tree().get_nodes_in_group("owdb"):
		if node.has_meta("_owd_uid") and node.get_meta("_owd_uid") == uid:
			return node
	return null

func add_to_chunk_lookup(uid: String, position: Vector3, size: float):
	var size_cat = get_size_category(size)
	var chunk_pos = get_chunk_position(position, size_cat)
	
	if not chunk_lookup.has(size_cat):
		chunk_lookup[size_cat] = {}
	if not chunk_lookup[size_cat].has(chunk_pos):
		chunk_lookup[size_cat][chunk_pos] = []
	
	if uid not in chunk_lookup[size_cat][chunk_pos]:
		chunk_lookup[size_cat][chunk_pos].append(uid)

func remove_from_chunk_lookup(uid: String, position: Vector3, size: float):
	var size_cat = get_size_category(size)
	var chunk_pos = get_chunk_position(position, size_cat)
	
	if chunk_lookup.has(size_cat) and chunk_lookup[size_cat].has(chunk_pos):
		chunk_lookup[size_cat][chunk_pos].erase(uid)
		if chunk_lookup[size_cat][chunk_pos].is_empty():
			chunk_lookup[size_cat].erase(chunk_pos)

func get_size_category(node_size: float) -> Size:
	if node_size == 0.0 or node_size > size_thresholds[Size.LARGE]:
		return Size.ALWAYS_LOADED
	
	for i in range(size_thresholds.size()):
		if node_size <= size_thresholds[i]:
			return i
	
	return Size.ALWAYS_LOADED

func get_chunk_position(position: Vector3, size_category: Size) -> Vector2i:
	if size_category == Size.ALWAYS_LOADED:
		return Vector2i(0, 0)
	
	var chunk_size = chunk_sizes[size_category]
	return Vector2i(int(position.x / chunk_size), int(position.z / chunk_size))

func is_chunk_loaded(size_cat: Size, chunk_pos: Vector2i) -> bool:
	return chunk_manager.is_chunk_loaded(size_cat, chunk_pos)

func handle_node_rename(node: Node) -> bool:
	return node_handler.handle_node_rename(node)

func get_total_database_nodes() -> int:
	return node_monitor.stored_nodes.size()

func get_currently_loaded_nodes() -> int:
	return get_all_owd_nodes().size()

func _process(_delta: float) -> void:
	if chunk_manager and not is_loading:
		chunk_manager._update_camera_chunks()

func debug():
	print("=== OWDB DEBUG INFO ===")
	print("Nodes currently loaded: ", get_currently_loaded_nodes())
	print("Total nodes in database: ", get_total_database_nodes())
	print("Loaded chunks per size:")
	
	for size in chunk_manager.loaded_chunks:
		print("  ", Size.keys()[size], ": ", chunk_manager.loaded_chunks[size].size(), " chunks")
	
	print("\nCurrently loaded nodes:")
	for node in get_all_owd_nodes():
		print("  - ", node.get_meta("_owd_uid", "NO_UID"), " : ", node.name)
	
	database.debug()
	
func save_database():
	database.save_database()

func _notification(what: int) -> void:
	if Engine.is_editor_hint():
		if what == NOTIFICATION_EDITOR_PRE_SAVE:
			save_database()

func _unload_node_not_in_chunk(node: Node):
	if not is_instance_valid(node):
		return
	
	var was_loading = is_loading
	is_loading = true
	
	if debug_enabled:
		print("NODE REMOVED (unloaded chunk): ", node.name, " - ", get_total_database_nodes(), " total database nodes")
	
	node.free()
	is_loading = was_loading

func _check_node_removal(node):
	if is_instance_valid(node) and node.is_inside_tree() and self.is_ancestor_of(node):
		return
	
	var was_in_database = false
	
	if is_instance_valid(node) and node.has_meta("_owd_uid"):
		var uid = node.get_meta("_owd_uid")
		if node_monitor.stored_nodes.has(uid):
			was_in_database = true
			var node_info = node_monitor.stored_nodes[uid]
			remove_from_chunk_lookup(uid, node_info.position, node_info.size)
			node_monitor.stored_nodes.erase(uid)
			
			if debug_enabled:
				print("NODE REMOVED FROM DATABASE: ", uid, " - ", get_total_database_nodes(), " total database nodes")
	
	if debug_enabled and not was_in_database:
		print("NODE REMOVED (not in database): ", node.name if is_instance_valid(node) else "Unknown")
	
	if is_instance_valid(node) and node.is_in_group("owdb"):
		node.remove_from_group("owdb")
