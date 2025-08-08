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

# Batch processing configuration
@export_group("Batch Processing")
@export var batch_time_limit_ms: float = 5.0  # Maximum time per batch in milliseconds
@export var batch_interval_ms: float = 100.0   # Interval between batches in milliseconds
@export var batch_processing_enabled: bool = true

var chunk_lookup: Dictionary = {} # [Size][Vector2i] -> Array[String] (UIDs)
var database: Database
var chunk_manager: ChunkManager
var node_monitor: NodeMonitor
var node_handler: NodeHandler
var batch_processor: BatchProcessor
var is_loading: bool = false

# Track nodes being legitimately unloaded by the system
var nodes_being_unloaded: Dictionary = {} # uid -> true

func _ready() -> void:
	if Engine.is_editor_hint():
		get_tree().auto_accept_quit = false
	
	reset()
	is_loading = true
	database.load_database()
	is_loading = false

func reset():
	is_loading = true
	nodes_being_unloaded.clear()
	NodeUtils.remove_children(self)
	chunk_manager = ChunkManager.new(self)
	node_monitor = NodeMonitor.new(self)
	database = Database.new(self)
	node_handler = NodeHandler.new(self)
	batch_processor = BatchProcessor.new(self)
	
	# Sync batch processor settings with exported properties
	batch_processor.batch_time_limit_ms = batch_time_limit_ms
	batch_processor.batch_interval_ms = batch_interval_ms
	batch_processor.batch_processing_enabled = batch_processing_enabled
	
	setup_listeners(self)
	batch_processor.setup()
	is_loading = false

func setup_listeners(node: Node):
	if not node.child_entered_tree.is_connected(_on_child_entered_tree):
		node.child_entered_tree.connect(_on_child_entered_tree)
	
	if not node.child_exiting_tree.is_connected(_on_child_exiting_tree):
		node.child_exiting_tree.connect(_on_child_exiting_tree)

func _on_child_entered_tree(node: Node):
	node_handler.call_deferred("handle_child_entered_tree", node)

func _on_child_exiting_tree(node: Node):
	node_handler.handle_child_exiting_tree(node)

func get_all_owd_nodes() -> Array:
	var nodes = []
	_collect_owd_nodes(self, nodes)
	return nodes

func _collect_owd_nodes(node: Node, collection: Array):
	if node.has_meta("_owd_uid"):
		collection.append(node)
	
	for child in node.get_children():
		_collect_owd_nodes(child, collection)

func get_node_by_uid(uid: String) -> Node:
	return _find_node_by_uid(self, uid)

func _find_node_by_uid(node: Node, uid: String) -> Node:
	if node.has_meta("_owd_uid") and node.get_meta("_owd_uid") == uid:
		return node
	
	for child in node.get_children():
		var result = _find_node_by_uid(child, uid)
		if result:
			return result
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

# Public batch processing interface
func load_node(uid: String):
	batch_processor.load_node(uid)

func unload_node(uid: String):
	batch_processor.unload_node(uid)

func clear_queues():
	batch_processor.clear_queues()

func force_process_queues():
	batch_processor.force_process_queues()

func update_batch_settings():
	# Sync settings from exported properties to batch processor
	batch_processor.batch_time_limit_ms = batch_time_limit_ms
	batch_processor.batch_interval_ms = batch_interval_ms
	batch_processor.batch_processing_enabled = batch_processing_enabled
	batch_processor.update_batch_settings()

func _remove_node_and_children_from_database(uid: String, node: Node = null):
	if not node_monitor.stored_nodes.has(uid):
		return
	
	var node_info = node_monitor.stored_nodes[uid]
	
	# Remove from chunk lookup
	remove_from_chunk_lookup(uid, node_info.position, node_info.size)
	
	# Remove from database
	node_monitor.stored_nodes.erase(uid)
	
	# Remove from batch processor queues
	batch_processor.remove_from_queues(uid)
	
	if debug_enabled:
		print("NODE REMOVED FROM DATABASE: ", uid, " - ", get_total_database_nodes(), " total database nodes")
	
	# Remove all child nodes from database as well
	var child_uids = []
	for child_uid in node_monitor.stored_nodes:
		if node_monitor.stored_nodes[child_uid].parent_uid == uid:
			child_uids.append(child_uid)
	
	for child_uid in child_uids:
		_remove_node_and_children_from_database(child_uid)

# Public save/load interface
func load_database(database_name: String = ""):
	if database_name == "":
		# Use default behavior
		database.load_database()
	else:
		# Load custom database from user directory
		database.load_custom_database(database_name)

func save_database(database_name: String = ""):
	if database_name == "":
		# Use default behavior
		database.save_database()
	else:
		# Save custom database to user directory
		database.save_custom_database(database_name)

func list_custom_databases() -> Array[String]:
	var databases = []
	var dir = DirAccess.open("user://")
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".owdb"):
				databases.append(file_name.get_basename())
			file_name = dir.get_next()
		dir.list_dir_end()
	return databases

func delete_custom_database(database_name: String) -> bool:
	var db_path = database.get_user_database_path(database_name)
	if FileAccess.file_exists(db_path):
		DirAccess.remove_absolute(db_path)
		return true
	return false

# Internal loading functions (called by batch processor)
func _immediate_load_node(uid: String):
	if uid not in node_monitor.stored_nodes:
		return
		
	var node_info = node_monitor.stored_nodes[uid]
	var existing_node = get_node_by_uid(uid)
	if existing_node:
		return  # Already loaded
	
	var new_node: Node
	
	if node_info.scene.begins_with("res://"):
		var scene = load(node_info.scene)
		new_node = scene.instantiate()
	else:
		new_node = ClassDB.instantiate(node_info.scene)
		if not new_node:
			print("Failed to create node of type: ", node_info.scene)
			return
	
	new_node.set_meta("_owd_uid", uid)
	new_node.name = uid
	
	var parent_node = self
	if node_info.parent_uid != "":
		var parent = get_node_by_uid(node_info.parent_uid)
		if parent:
			parent_node = parent
	
	for prop_name in node_info.properties:
		if prop_name not in ["position", "rotation", "scale", "size"]:
			if new_node.has_method("set") and prop_name in new_node:
				var stored_value = node_info.properties[prop_name]
				var current_value = new_node.get(prop_name)
				var converted_value = NodeUtils.convert_property_value(stored_value, current_value)
				new_node.set(prop_name, converted_value)
	
	parent_node.add_child(new_node)
	new_node.owner = owner
	
	if new_node is Node3D:
		new_node.global_position = node_info.position
		new_node.global_rotation = node_info.rotation
		new_node.scale = node_info.scale
	
	if debug_enabled:
		print("NODE LOADED: ", uid, " at ", node_info.position)
	
	setup_listeners(new_node)

func _immediate_unload_node(uid: String):
	var node = get_node_by_uid(uid)
	if not node:
		return
	
	# Mark this node as being legitimately unloaded by the system
	nodes_being_unloaded[uid] = true
	
	var node_info = node_monitor.stored_nodes.get(uid, {})
	if not node_info.is_empty():
		if node is Node3D:
			node_info.position = node.global_position
			node_info.rotation = node.global_rotation
			node_info.scale = node.scale
	
	node.free()
	
	# Clean up the tracking after a short delay
	call_deferred("_cleanup_unload_tracking", uid)
	
	if debug_enabled:
		print("NODE UNLOADED: ", uid)

func _cleanup_unload_tracking(uid: String):
	nodes_being_unloaded.erase(uid)

func _process(_delta: float) -> void:
	if chunk_manager and not is_loading:
		chunk_manager._update_camera_chunks()

func debug():
	print("=== OWDB DEBUG INFO ===")
	print("Nodes currently loaded: ", get_currently_loaded_nodes())
	print("Total nodes in database: ", get_total_database_nodes())
	
	var queue_info = batch_processor.get_queue_info()
	print("Operations queued: ", queue_info.total_queue_size)
	print("Load operations: ", queue_info.load_operations_queued)
	print("Unload operations: ", queue_info.unload_operations_queued)
	print("Batch processing active: ", queue_info.batch_processing_active)
	print("Loaded chunks per size:")
	
	for size in chunk_manager.loaded_chunks:
		print("  ", Size.keys()[size], ": ", chunk_manager.loaded_chunks[size].size(), " chunks")
	
	print("Pending chunk operations: ", chunk_manager.pending_chunk_operations.size())
	
	print("\nCurrently loaded nodes:")
	for node in get_all_owd_nodes():
		print("  - ", node.get_meta("_owd_uid", "NO_UID"), " : ", node.name)
	
	database.debug()

func _notification(what: int) -> void:
	if Engine.is_editor_hint():
		if what == NOTIFICATION_EDITOR_PRE_SAVE:
			save_database()

func _unload_node_not_in_chunk(node: Node):
	if not is_instance_valid(node):
		return
	
	var was_loading = is_loading
	is_loading = true
	
	# Mark as being legitimately unloaded
	if node.has_meta("_owd_uid"):
		var uid = node.get_meta("_owd_uid")
		nodes_being_unloaded[uid] = true
	
	if debug_enabled:
		print("NODE REMOVED (unloaded chunk): ", node.name, " - ", get_total_database_nodes(), " total database nodes")
	
	node.free()
	is_loading = was_loading

func _check_node_removal(node):
	if not node:
		return
	
	# If we're in a loading state, don't process removals
	if is_loading:
		return
	
	# Check if node is still valid and in tree
	#if is_instance_valid(node) and self.is_ancestor_of(node):
	#	return
	
	# Get the UID before we lose access to the node
	var uid = ""
	if is_instance_valid(node) and node.has_meta("_owd_uid"):
		uid = node.get_meta("_owd_uid")
	
	if uid == "":
		return
	
	# Check if this node is being legitimately unloaded by the system
	if nodes_being_unloaded.has(uid):
		if debug_enabled:
			print("NODE EXITED (system unload): ", uid)
		return  # This is a legitimate system unload, don't remove from database
	
	# If we get here, the node was freed by user code, so remove from database
	if node_monitor.stored_nodes.has(uid):
		_remove_node_and_children_from_database(uid, node)
		
		if debug_enabled:
			print("NODE AUTO-REMOVED (user freed): ", uid, " - ", get_total_database_nodes(), " total database nodes")
