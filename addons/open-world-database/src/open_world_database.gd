# src/OpenWorldDatabase.gd
@tool
extends Node
class_name OpenWorldDatabase

enum Size { SMALL, MEDIUM, LARGE, ALWAYS_LOADED }
enum NetworkMode { HOST, PEER, STANDALONE }

const UID_SEPARATOR = "-"
const DATABASE_EXTENSION = ".owdb"
const METADATA_PREFIX = "_owd_"
const ALWAYS_LOADED_CHUNK_POS = Vector2i(0, 0)
const SKIP_PROPERTIES = [
	"metadata/_owd_uid", "metadata/_owd_last_scale", "metadata/_owd_last_size",
	"script", "transform", "global_transform", "global_position", "global_rotation"
]

var _chunk_sizes: Array[float] = [8.0, 16.0, 64.0]
var _threshold_ratio: float = 0.25
var _chunk_load_range: int = 3
var _load_all_chunks: bool = false

@export var chunk_sizes: Array[float] = [8.0, 16.0, 64.0]:
	set(value):
		if not _arrays_equal(_chunk_sizes, value) and Engine.is_editor_hint() and is_inside_tree():
			_chunk_sizes = value
			_handle_editor_property_change("chunk_sizes")
		else:
			_chunk_sizes = value
	get:
		return _chunk_sizes

@export var threshold_ratio: float = 0.25:
	set(value):
		if _threshold_ratio != value and Engine.is_editor_hint() and is_inside_tree():
			_threshold_ratio = value
			_handle_editor_property_change("threshold_ratio")
		else:
			_threshold_ratio = value
	get:
		return _threshold_ratio

@export var chunk_load_range: int = 3:
	set(value):
		if _chunk_load_range != value and Engine.is_editor_hint() and is_inside_tree():
			_chunk_load_range = value
			_handle_editor_property_change("chunk_load_range")
		else:
			_chunk_load_range = value
	get:
		return _chunk_load_range

@export_group("Network Settings")
@export var auto_network_enabled: bool = true
@export var force_network_mode: NetworkMode = NetworkMode.STANDALONE

@export_group("Batch Processing")
@export var batch_processing_enabled: bool = true
@export var batch_time_limit_ms: float = 10.0
@export var batch_interval_ms: float = 50.0

@export_group("Editor")
@export var follow_editor_camera: bool = true
@export var load_all_chunks: bool = false:
	set(value):
		if _load_all_chunks != value and Engine.is_editor_hint() and is_inside_tree():
			_load_all_chunks = value
			_handle_load_all_chunks_change(value)
		else:
			_load_all_chunks = value
	get:
		return _load_all_chunks

@export_group("Debug")
@export var debug_enabled: bool = false
@export_tool_button("debug info", "Debug") var debug_action = debugAll

var chunk_lookup: Dictionary = {}
var loaded_nodes_by_uid: Dictionary = {}
var database: Database
var chunk_manager: ChunkManager
var node_monitor: NodeMonitor
var node_handler: NodeHandler
var batch_processor: BatchProcessor
var syncer: Node = null
var is_loading: bool = false
var nodes_being_unloaded: Dictionary = {}

var current_network_mode: NetworkMode = NetworkMode.STANDALONE
var _multiplayer_connected: bool = false

var _editor_camera_position: OWDBPosition = null
var _last_follow_state: bool = false

func _arrays_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true

func _handle_load_all_chunks_change(enabled: bool):
	debug("Editor 'load_all_chunks' changed to: ", enabled)
	
	if not chunk_manager:
		return
	
	if enabled:
		chunk_manager.enable_load_all_chunks_mode()
	else:
		chunk_manager.disable_load_all_chunks_mode()

func _handle_editor_property_change(property_name: String):
	debug("Editor property '" + property_name + "' changed - performing complete reset with batch processing FORCED OFF")
	
	var original_batch_enabled = batch_processing_enabled
	
	call_deferred("_complete_reset_with_batch_disabled", original_batch_enabled)

func _complete_reset_with_batch_disabled(original_batch_enabled: bool):
	_remove_editor_camera_position()
	
	batch_processing_enabled = false
	
	_reset_with_batch_disabled()
	
	is_loading = true
	database.load_database()
	is_loading = false
	
	if batch_processor:
		batch_processor.force_process_queues()
	
	debug("Reset complete with batch processing FORCED OFF - restoring original setting: " + str(original_batch_enabled))
	
	batch_processing_enabled = original_batch_enabled
	update_batch_settings()
	
	if Engine.is_editor_hint():
		_last_follow_state = follow_editor_camera
		_update_editor_camera_following()
		
		if _load_all_chunks:
			call_deferred("_restore_load_all_chunks_state")
	
	debug("Complete reset finished - batch processing restored to: " + str(batch_processing_enabled))

func _restore_load_all_chunks_state():
	if chunk_manager and _load_all_chunks:
		chunk_manager.enable_load_all_chunks_mode()

func _reset_with_batch_disabled():
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
	batch_processor.batch_processing_enabled = false
	
	_setup_syncer()
	_setup_listeners(self)
	batch_processor.setup()
	
	debug("Reset complete - batch processing FORCED OFF for property change")
	is_loading = false

func get_size_thresholds() -> Array[float]:
	var thresholds: Array[float] = []
	for chunk_size in _chunk_sizes:
		thresholds.append(chunk_size * _threshold_ratio)
	return thresholds

func debug(v1 = "", v2 = "", v3 = "", v4 = "", v5 = "", v6 = "", v7 = ""):
	if debug_enabled:
		if multiplayer:
			print(multiplayer.get_unique_id(),": ", str(v1), str(v2), str(v3), str(v4), str(v5), str(v6), str(v7))
		else:
			print("0: ", str(v1), str(v2), str(v3), str(v4), str(v5), str(v6), str(v7))

func _setup_syncer():
	if Engine.is_editor_hint():
		return
		
	if syncer and is_instance_valid(syncer):
		syncer.unregister_owdb()
		syncer.queue_free()
	
	var syncer_script = load("res://addons/open-world-database/src/network/Syncer.gd")
	if not syncer_script:
		push_error("OWDB: Could not load Syncer script")
		return
	
	syncer = Node.new()
	syncer.set_script(syncer_script)
	syncer.name = "Syncer"
	add_child(syncer)
	
	syncer.register_owdb(self)
	debug("Created local Syncer instance")

func _ready() -> void:
	if Engine.is_editor_hint():
		get_tree().auto_accept_quit = false
	
	_setup_multiplayer_signals()
	
	reset()
	is_loading = true
	database.load_database()
	is_loading = false
	
	_update_network_mode()
	
	if Engine.is_editor_hint():
		_last_follow_state = follow_editor_camera
		call_deferred("_update_editor_camera_following")
		
		if _load_all_chunks:
			call_deferred("_restore_load_all_chunks_state")

func _process(_delta):
	if Engine.is_editor_hint():
		if follow_editor_camera != _last_follow_state:
			_last_follow_state = follow_editor_camera
			_update_editor_camera_following()
		
		if follow_editor_camera and _is_current_edited_scene():
			if not _editor_camera_position or not is_instance_valid(_editor_camera_position):
				_create_editor_camera_position()
				if _editor_camera_position:
					_editor_camera_position.force_update()
			
			if _editor_camera_position:
				_update_editor_camera_position()

func _is_current_edited_scene() -> bool:
	var edited_scene = EditorInterface.get_edited_scene_root()
	if not edited_scene:
		return false
	
	var current_scene = self
	while current_scene.get_parent():
		current_scene = current_scene.get_parent()
		if current_scene == edited_scene:
			return true
		
	return false

func _update_editor_camera_following():
	if follow_editor_camera and not _editor_camera_position:
		_create_editor_camera_position()
	elif not follow_editor_camera and _editor_camera_position:
		_remove_editor_camera_position()

func _get_editor_camera() -> Camera3D:
	if not Engine.is_editor_hint():
		return null
	
	var editor_viewport = EditorInterface.get_editor_viewport_3d(0)
	if editor_viewport:
		return editor_viewport.get_camera_3d()
	
	return null

func _create_editor_camera_position():
	if _editor_camera_position and is_instance_valid(_editor_camera_position):
		return
	
	_editor_camera_position = OWDBPosition.new()
	_editor_camera_position.name = "EditorCameraPosition"
	
	add_child(_editor_camera_position)
	
	debug("Created editor camera OWDBPosition node in scene")

func _remove_editor_camera_position():
	if _editor_camera_position and is_instance_valid(_editor_camera_position):
		_editor_camera_position.queue_free()
		_editor_camera_position = null
		debug("Removed editor camera OWDBPosition node")

func _update_editor_camera_position():
	var editor_camera = _get_editor_camera()
	if not editor_camera:
		return
	
	if _editor_camera_position and is_instance_valid(_editor_camera_position):
		_editor_camera_position.global_position = editor_camera.global_position

func _exit_tree():
	_remove_editor_camera_position()
	
	if syncer and is_instance_valid(syncer):
		syncer.unregister_owdb()
		syncer.queue_free()
		syncer = null
		debug("OWDB unregistered and freed Syncer")

func _setup_multiplayer_signals():
	if not multiplayer:
		return
	
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_connected_to_server():
	debug("OWDB: Connected to server, switching to PEER mode")
	_multiplayer_connected = true
	_update_network_mode()
	_handle_mode_transition_to_peer()

func _on_connection_failed():
	debug("OWDB: Connection failed, staying in current mode")

func _on_server_disconnected():
	debug("OWDB: Disconnected from server, switching to HOST mode")
	_multiplayer_connected = false
	_update_network_mode()
	_handle_mode_transition_to_host()

func _update_network_mode():
	var new_mode = _determine_network_mode()
	
	if new_mode != current_network_mode:
		debug("OWDB: Network mode changing from ", str(current_network_mode) + " to " + str(new_mode))
		current_network_mode = new_mode
		
		if chunk_manager:
			chunk_manager.set_network_mode(current_network_mode)

func _determine_network_mode() -> NetworkMode:
	if force_network_mode != NetworkMode.STANDALONE:
		return force_network_mode
	
	if auto_network_enabled and multiplayer and multiplayer.has_multiplayer_peer():
		if multiplayer.is_server():
			return NetworkMode.HOST
		else:
			return NetworkMode.PEER
	
	return NetworkMode.HOST

func _handle_mode_transition_to_peer():
	is_loading = true
	
	chunk_manager.clear_autonomous_chunk_management()
	
	debug("OWDB: Transitioned to PEER mode - chunk loading now controlled by host")
	is_loading = false

func _handle_mode_transition_to_host():
	is_loading = true
	
	chunk_manager.enable_autonomous_chunk_management()
	
	chunk_manager.force_refresh_all_positions()
	
	debug("OWDB: Transitioned to HOST mode - resuming autonomous chunk management")
	is_loading = false

func get_network_mode() -> NetworkMode:
	return current_network_mode

func is_network_host() -> bool:
	return current_network_mode == NetworkMode.HOST

func is_network_peer() -> bool:
	return current_network_mode == NetworkMode.PEER

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
	
	_setup_syncer()
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
	var chunk_pos = NodeUtils.get_chunk_position(position, _chunk_sizes[size_cat]) if size_cat != Size.ALWAYS_LOADED else ALWAYS_LOADED_CHUNK_POS
	
	if not chunk_lookup.has(size_cat):
		chunk_lookup[size_cat] = {}
	if not chunk_lookup[size_cat].has(chunk_pos):
		chunk_lookup[size_cat][chunk_pos] = []
	
	if uid not in chunk_lookup[size_cat][chunk_pos]:
		chunk_lookup[size_cat][chunk_pos].append(uid)

func remove_from_chunk_lookup(uid: String, position: Vector3, size: float):
	var size_cat = get_size_category(size)
	var chunk_pos = NodeUtils.get_chunk_position(position, _chunk_sizes[size_cat]) if size_cat != Size.ALWAYS_LOADED else ALWAYS_LOADED_CHUNK_POS
	
	if chunk_lookup.has(size_cat) and chunk_lookup[size_cat].has(chunk_pos):
		chunk_lookup[size_cat][chunk_pos].erase(uid)
		if chunk_lookup[size_cat][chunk_pos].is_empty():
			chunk_lookup[size_cat].erase(chunk_pos)

func get_size_category(node_size: float) -> Size:
	if node_size == 0.0:
		return Size.ALWAYS_LOADED
	
	var thresholds = get_size_thresholds()
	for i in thresholds.size():
		if node_size <= thresholds[i]:
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
	
	var child_uids = []
	for child_uid in node_monitor.stored_nodes:
		if node_monitor.stored_nodes[child_uid].parent_uid == uid:
			child_uids.append(child_uid)
	
	# Only remove children that are currently loaded and still parented to THIS node instance
	# Preserve unloaded children and reparented children in database
	for child_uid in child_uids:
		var child_node = loaded_nodes_by_uid.get(child_uid)
		
		if child_node and is_instance_valid(child_node) and child_node.is_inside_tree():
			# If we have the node instance, compare actual parent to THIS node instance
			if node and is_instance_valid(node):
				var actual_parent = child_node.get_parent()
				
				if actual_parent == node:
					# Child is still parented to THIS specific node instance - remove it
					_remove_node_and_children_from_database(child_uid, child_node)
				else:
					# Child has been reparented to a different node instance
					# (could be new node with same UID after type change)
					debug("PRESERVING REPARENTED CHILD: ", child_uid, " (different parent instance)")
					
					# Update parent_uid if the new parent has a different UID
					var new_parent_uid = NodeUtils.get_valid_node_uid(actual_parent) if actual_parent else ""
					if new_parent_uid != "" and new_parent_uid != uid:
						var child_info = node_monitor.stored_nodes[child_uid]
						child_info.parent_uid = new_parent_uid
						debug("  Updated parent_uid: ", uid, " -> ", new_parent_uid)
			else:
				# No node instance provided - can't verify parent relationship, preserve child
				debug("PRESERVING CHILD (no node instance to verify): ", child_uid)
		else:
			# Child is unloaded - preserve in database
			debug("PRESERVING UNLOADED CHILD: ", child_uid)
	
	node_monitor.remove_node_resources(uid)
	remove_from_chunk_lookup(uid, node_info.position, node_info.size)
	node_monitor.stored_nodes.erase(uid)
	loaded_nodes_by_uid.erase(uid)
	batch_processor.remove_from_queues(uid)
	
	debug("NODE REMOVED FROM DATABASE: " + uid + " - " + str(get_total_database_nodes()) + " total database nodes")


func save_database(custom_name: String = ""):
	database.save_database(custom_name)

func load_database(custom_name: String = ""):
	database.load_database(custom_name)

func list_custom_databases() -> Array[String]:
	return database.list_custom_databases()

func delete_custom_database(database_name: String) -> bool:
	return database.delete_custom_database(database_name)

func _cleanup_unload_tracking(uid: String):
	nodes_being_unloaded.erase(uid)

func debugAll():
	print(multiplayer.get_unique_id(), ": === OWDB DEBUG INFO ===")
	print(multiplayer.get_unique_id(), ": Network Mode: ", current_network_mode)
	print(multiplayer.get_unique_id(), ": Nodes currently loaded: ", get_currently_loaded_nodes())
	print(multiplayer.get_unique_id(), ": Total nodes in database: ", get_total_database_nodes())
	print(multiplayer.get_unique_id(), ": Active OWDBPosition nodes: ", get_active_position_count())
	print(multiplayer.get_unique_id(), ": Follow Editor Camera: ", follow_editor_camera)
	print(multiplayer.get_unique_id(), ": Load All Chunks: ", _load_all_chunks)
	print(multiplayer.get_unique_id(), ": Editor Camera Position Node: ", _editor_camera_position != null)
	print(multiplayer.get_unique_id(), ": Is Current Edited Scene: ", _is_current_edited_scene())
	if _editor_camera_position:
		print(multiplayer.get_unique_id(), ": Editor Position Node Position: ", _editor_camera_position.global_position)
	var editor_camera = _get_editor_camera()
	if editor_camera:
		print(multiplayer.get_unique_id(), ": Editor Camera Position: ", editor_camera.global_position)
	var chunk_info = chunk_manager.get_chunk_requirement_info()
	print(multiplayer.get_unique_id(), ": Chunks required: ", chunk_info.total_chunks_required)
	print(multiplayer.get_unique_id(), ": Chunks loaded: ", chunk_info.chunks_loaded)
	print(multiplayer.get_unique_id(), ": Current chunk_sizes: ", _chunk_sizes)
	print(multiplayer.get_unique_id(), ": Current threshold_ratio: ", _threshold_ratio)
	print(multiplayer.get_unique_id(), ": Current chunk_load_range: ", _chunk_load_range)
	print(multiplayer.get_unique_id(), ": Batch processing enabled: ", batch_processing_enabled)
	print(multiplayer.get_unique_id(), ": Syncer instance: ", syncer != null)

func _notification(what: int) -> void:
	if Engine.is_editor_hint():
		if what == NOTIFICATION_EDITOR_PRE_SAVE:
			save_database()

func _unload_node_not_in_chunk(node_instance_id: int):
	var node = instance_from_id(node_instance_id)
	if not is_instance_valid(node) or not node is Node:
		return
	
	var was_loading = is_loading
	is_loading = true
	
	var uid = NodeUtils.get_valid_node_uid(node)
	if uid != "":
		nodes_being_unloaded[uid] = true
		loaded_nodes_by_uid.erase(uid)
		
		# FIXED: Mark all children as being unloaded
		_mark_children_as_unloading(node)
		
		if syncer and is_instance_valid(syncer) and node.has_meta("_network_spawned"):
			syncer.notify_node_unloaded(node.name)
	
	debug("NODE UNLOADED: " + node.name + " - " + str(get_currently_loaded_nodes()) + " total loaded nodes")
	
	node.free()
	is_loading = was_loading

func _mark_children_as_unloading(node: Node):
	"""Recursively mark all children as being unloaded to prevent database removal"""
	for child in node.get_children():
		var child_uid = NodeUtils.get_valid_node_uid(child)
		if child_uid != "":
			nodes_being_unloaded[child_uid] = true
			loaded_nodes_by_uid.erase(child_uid)
			debug("MARKING CHILD FOR UNLOAD: ", child_uid)
		_mark_children_as_unloading(child)

func _check_node_removal(node):
	if not node or is_loading:
		return
	
	var uid = NodeUtils.get_valid_node_uid(node)
	if uid == "":
		return
	
	if nodes_being_unloaded.has(uid):
		debug("NODE EXITED (system unload): ", uid)
		return
	
	if node_monitor.stored_nodes.has(uid):
		call_deferred("_deferred_check_node_removal", node, uid)

func _deferred_check_node_removal(node, uid: String):
	if is_loading:
		return
	
	if node and node.is_inside_tree():
		debug("NODE MOVED (still in tree): ", uid)
		return
	
	if node_monitor.stored_nodes.has(uid) and not nodes_being_unloaded.has(uid):
		_remove_node_and_children_from_database(uid, node)
		
		debug("NODE AUTO-REMOVED (user freed): " + uid + " - " + str(get_total_database_nodes()) + " total database nodes")
