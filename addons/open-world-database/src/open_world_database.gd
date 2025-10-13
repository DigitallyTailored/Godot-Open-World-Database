# open-world-database-gd
@tool
extends Node
class_name OpenWorldDatabase

enum Size { SMALL, MEDIUM, LARGE, ALWAYS_LOADED }

# Constants
const UID_SEPARATOR = "-"
const DATABASE_EXTENSION = ".owdb"
const METADATA_PREFIX = "_owd_"
const ALWAYS_LOADED_CHUNK_POS = Vector2i(0, 0)
const SKIP_PROPERTIES = [
	"metadata/_owd_uid", "metadata/_owd_last_scale", "metadata/_owd_last_size",
	"script", "transform", "global_transform", "global_position", "global_rotation"
]

@export var size_thresholds: Array[float] = [1.0, 4.0, 16.0]
@export var chunk_sizes: Array[float] = [8.0, 16.0, 64.0]
@export var chunk_load_range: int = 3
@export var debug_enabled: bool = false

@export_tool_button("debug info", "Debug") var debug_action = debug

# Batch processing configuration
@export_group("Batch Processing")
@export var batch_time_limit_ms: float = 5.0
@export var batch_interval_ms: float = 100.0
@export var batch_processing_enabled: bool = true

var chunk_lookup: Dictionary = {} # [Size][Vector2i] -> Array[String] (UIDs)
var loaded_nodes_by_uid: Dictionary = {} # uid -> Node (cached for O(1) lookup)
var database: Database
var chunk_manager: ChunkManager
var node_monitor: NodeMonitor
var node_handler: NodeHandler
var batch_processor: BatchProcessor
var is_loading: bool = false
var nodes_being_unloaded: Dictionary = {} # uid -> true

func debug_log(message: String, value = null):
	if debug_enabled:
		if value != null:
			print(message, value)
		else:
			print(message)

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
	loaded_nodes_by_uid.clear()
	NodeUtils.remove_children(self)
	
	chunk_manager = ChunkManager.new(self)
	node_monitor = NodeMonitor.new(self)
	database = Database.new(self)
	node_handler = NodeHandler.new(self)
	batch_processor = BatchProcessor.new(self)
	
	batch_processor.batch_time_limit_ms = batch_time_limit_ms
	batch_processor.batch_interval_ms = batch_interval_ms
	batch_processor.batch_processing_enabled = batch_processing_enabled
	
	_setup_listeners(self)
	batch_processor.setup()
	is_loading = false

func _setup_listeners(node: Node):
	if not node.child_entered_tree.is_connected(_on_child_entered_tree):
		node.child_entered_tree.connect(_on_child_entered_tree)
	
	if not node.child_exiting_tree.is_connected(_on_child_exiting_tree):
		node.child_exiting_tree.connect(_on_child_exiting_tree)

func _on_child_entered_tree(node: Node):
	node_handler.call_deferred("handle_child_entered_tree", node)

func _on_child_exiting_tree(node: Node):
	node_handler.handle_child_exiting_tree(node)

func get_all_owd_nodes() -> Array:
	return loaded_nodes_by_uid.values()

func get_node_by_uid(uid: String) -> Node:
	return loaded_nodes_by_uid.get(uid)

func add_to_chunk_lookup(uid: String, position: Vector3, size: float):
	var size_cat = get_size_category(size)
	var chunk_pos = NodeUtils.get_chunk_position(position, chunk_sizes[size_cat]) if size_cat != Size.ALWAYS_LOADED else ALWAYS_LOADED_CHUNK_POS
	
	if not chunk_lookup.has(size_cat):
		chunk_lookup[size_cat] = {}
	if not chunk_lookup[size_cat].has(chunk_pos):
		chunk_lookup[size_cat][chunk_pos] = []
	
	if uid not in chunk_lookup[size_cat][chunk_pos]:
		chunk_lookup[size_cat][chunk_pos].append(uid)

func remove_from_chunk_lookup(uid: String, position: Vector3, size: float):
	var size_cat = get_size_category(size)
	var chunk_pos = NodeUtils.get_chunk_position(position, chunk_sizes[size_cat]) if size_cat != Size.ALWAYS_LOADED else ALWAYS_LOADED_CHUNK_POS
	
	if chunk_lookup.has(size_cat) and chunk_lookup[size_cat].has(chunk_pos):
		chunk_lookup[size_cat][chunk_pos].erase(uid)
		if chunk_lookup[size_cat][chunk_pos].is_empty():
			chunk_lookup[size_cat].erase(chunk_pos)


func get_size_category(node_size: float) -> Size:
	if node_size == 0.0:
		return Size.ALWAYS_LOADED
	
	for i in size_thresholds.size():
		if node_size <= size_thresholds[i]:
			return i
	
	return Size.ALWAYS_LOADED

func get_total_database_nodes() -> int:
	return node_monitor.stored_nodes.size()

func get_currently_loaded_nodes() -> int:
	return loaded_nodes_by_uid.size()

func get_active_position_count() -> int:
	return chunk_manager.get_active_position_count()

func update_batch_settings():
	batch_processor.batch_time_limit_ms = batch_time_limit_ms
	batch_processor.batch_interval_ms = batch_interval_ms
	batch_processor.batch_processing_enabled = batch_processing_enabled
	batch_processor.update_batch_settings()

func _remove_node_and_children_from_database(uid: String, node = null):
	if not node_monitor.stored_nodes.has(uid):
		return
	
	var node_info = node_monitor.stored_nodes[uid]
	
	remove_from_chunk_lookup(uid, node_info.position, node_info.size)
	node_monitor.stored_nodes.erase(uid)
	loaded_nodes_by_uid.erase(uid)
	batch_processor.remove_from_queues(uid)
	
	debug_log("NODE REMOVED FROM DATABASE: " + uid + " - " + str(get_total_database_nodes()) + " total database nodes")
	
	var child_uids = []
	for child_uid in node_monitor.stored_nodes:
		if node_monitor.stored_nodes[child_uid].parent_uid == uid:
			child_uids.append(child_uid)
	
	for child_uid in child_uids:
		_remove_node_and_children_from_database(child_uid)

func save_database(custom_name: String = ""):
	database.save_database(custom_name)

func load_database(custom_name: String = ""):
	database.load_database(custom_name)

func list_custom_databases() -> Array[String]:
	return database.list_custom_databases()

func delete_custom_database(database_name: String) -> bool:
	return database.delete_custom_database(database_name)

func _immediate_load_node(uid: String):
	if uid not in node_monitor.stored_nodes:
		return
	
	if loaded_nodes_by_uid.has(uid):
		return
		
	var node_info = node_monitor.stored_nodes[uid]
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
		var parent = loaded_nodes_by_uid.get(node_info.parent_uid)
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
	
	loaded_nodes_by_uid[uid] = new_node
	_setup_listeners(new_node)
	
	debug_log("NODE LOADED: " + uid + " at ", node_info.position)

func _immediate_unload_node(uid: String):
	var node = loaded_nodes_by_uid.get(uid)
	if not node:
		return
	
	nodes_being_unloaded[uid] = true
	
	var node_info = node_monitor.stored_nodes.get(uid, {})
	if not node_info.is_empty():
		if node is Node3D:
			node_info.position = node.global_position
			node_info.rotation = node.global_rotation
			node_info.scale = node.scale
	
	loaded_nodes_by_uid.erase(uid)
	node.free()
	
	call_deferred("_cleanup_unload_tracking", uid)
	
	debug_log("NODE UNLOADED: ", uid)

func _cleanup_unload_tracking(uid: String):
	nodes_being_unloaded.erase(uid)

func debug():
	print("=== OWDB DEBUG INFO ===")
	print("Nodes currently loaded: ", get_currently_loaded_nodes())
	print("Total nodes in database: ", get_total_database_nodes())
	print("Active OWDBPosition nodes: ", get_active_position_count())
	var chunk_info = chunk_manager.get_chunk_requirement_info()
	print("Chunks required: ", chunk_info.total_chunks_required)
	print("Chunks loaded: ", chunk_info.chunks_loaded)

func _notification(what: int) -> void:
	if Engine.is_editor_hint():
		if what == NOTIFICATION_EDITOR_PRE_SAVE:
			save_database()

func _unload_node_not_in_chunk(node: Node):
	if not is_instance_valid(node):
		return
	
	var was_loading = is_loading
	is_loading = true
	
	var uid = NodeUtils.get_valid_node_uid(node)
	if uid != "":
		nodes_being_unloaded[uid] = true
		loaded_nodes_by_uid.erase(uid)
	
	debug_log("NODE REMOVED (unloaded chunk): " + node.name + " - " + str(get_total_database_nodes()) + " total database nodes")
	
	node.free()
	is_loading = was_loading

func _check_node_removal(node):
	if not node or is_loading:
		return
	
	var uid = NodeUtils.get_valid_node_uid(node)
	if uid == "":
		return
	
	if nodes_being_unloaded.has(uid):
		debug_log("NODE EXITED (system unload): ", uid)
		return
	
	if node_monitor.stored_nodes.has(uid):
		call_deferred("_deferred_check_node_removal", node, uid)

func _deferred_check_node_removal(node, uid: String):
	if is_loading:
		return
	
	if node and node.is_inside_tree():
		debug_log("NODE MOVED (still in tree): ", uid)
		return
	
	if node_monitor.stored_nodes.has(uid) and not nodes_being_unloaded.has(uid):
		_remove_node_and_children_from_database(uid, node)
		
		debug_log("NODE AUTO-REMOVED (user freed): " + uid + " - " + str(get_total_database_nodes()) + " total database nodes")
