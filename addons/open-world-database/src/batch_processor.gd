# src/BatchProcessor.gd
# Processes world operations in time-limited batches to maintain frame rate stability
# Handles node loading/unloading/instantiation with configurable timing and callbacks
# Provides both immediate and batched operation modes with queue management
# Input: Operation requests (load/unload/instantiate), timing configurations
# Output: Processed world changes, batch completion callbacks, operation validation
@tool
extends RefCounted
class_name BatchProcessor

var owdb: OpenWorldDatabase
var parent_node: Node

var batch_time_limit_ms: float = 5.0
var batch_interval_ms: float = 100.0
var batch_processing_enabled: bool = true

var pending_operations: Dictionary = {}
var operation_order: Array = []
var batch_timer: Timer
var is_processing_batch: bool = false
var batch_complete_callbacks: Array[Callable] = []

# Scene cache to avoid reloading the same scenes
var scene_cache: Dictionary = {}  # scene_path -> PackedScene

enum OperationType {
	LOAD_NODE,
	UNLOAD_NODE,
	INSTANTIATE_SCENE,
	REMOVE_NODE
}

func _init(open_world_database: OpenWorldDatabase, parent: Node = null):
	owdb = open_world_database
	parent_node = parent if parent else open_world_database

func setup():
	batch_timer = Timer.new()
	_get_parent_node().add_child(batch_timer)
	batch_timer.wait_time = batch_interval_ms / 1000.0
	batch_timer.timeout.connect(_process_batch)
	batch_timer.autostart = false
	batch_timer.one_shot = false

func _get_parent_node() -> Node:
	return owdb if owdb else parent_node

func _get_scene_tree() -> SceneTree:
	var parent = _get_parent_node()
	return parent.get_tree() if parent else null

func reset():
	pending_operations.clear()
	operation_order.clear()
	batch_complete_callbacks.clear()
	if batch_timer:
		batch_timer.stop()

func clear_scene_cache():
	scene_cache.clear()
	_debug("Scene cache cleared (" + str(scene_cache.size()) + " entries)")

func _process_batch():
	if is_processing_batch:
		return
	
	is_processing_batch = true
	var start_time = Time.get_ticks_msec()
	var operations_performed = 0
	
	while not operation_order.is_empty():
		var operation_id = operation_order.pop_front()
		
		if not pending_operations.has(operation_id):
			continue
		
		var operation = pending_operations[operation_id]
		
		match operation.type:
			OperationType.LOAD_NODE:
				if _process_load_node_operation(operation):
					operations_performed += 1
			OperationType.UNLOAD_NODE:
				if _process_unload_node_operation(operation):
					operations_performed += 1
			OperationType.INSTANTIATE_SCENE:
				if _process_instantiate_scene_operation(operation):
					operations_performed += 1
			OperationType.REMOVE_NODE:
				if _process_remove_node_operation(operation):
					operations_performed += 1
		
		pending_operations.erase(operation_id)
		
		if Time.get_ticks_msec() - start_time >= batch_time_limit_ms:
			break
	
	if operation_order.is_empty():
		batch_timer.stop()
		_notify_batch_complete()
	
	if operations_performed > 0:
		var time_taken = Time.get_ticks_msec() - start_time
		_debug("Batch processed " + str(operations_performed) + " operations in " + str(time_taken) + "ms. Remaining: " + str(operation_order.size()))
	
	is_processing_batch = false

func _process_load_node_operation(operation: Dictionary) -> bool:
	var uid = operation.data.get("uid", "")
	if not _is_load_operation_valid(uid):
		return false
	
	_immediate_load_node(uid)
	return true

func _process_unload_node_operation(operation: Dictionary) -> bool:
	var uid = operation.data.get("uid", "")
	if not _is_unload_operation_valid(uid):
		return false
	
	_immediate_unload_node(uid)
	return true

func _process_instantiate_scene_operation(operation: Dictionary) -> bool:
	var scene_path = operation.data.get("scene_path", "")
	var node_name = operation.data.get("node_name", "")
	var parent_path = operation.data.get("parent_path", "")
	var callback = operation.callback
	
	return _instantiate_node(scene_path, node_name, parent_path, callback)

func _process_remove_node_operation(operation: Dictionary) -> bool:
	var node_name = operation.data.get("node_name", "")
	return _remove_scene_node(node_name)

func _create_node(node_source: String) -> Node:
	if node_source == "":
		_debug("Cannot create node: empty source")
		return null
	
	var new_node: Node
	
	if node_source.begins_with("res://"):
		# Check cache first
		var scene: PackedScene = scene_cache.get(node_source)
		if not scene:
			scene = load(node_source)
			if not scene:
				_debug("Failed to load scene: " + node_source)
				return null
			scene_cache[node_source] = scene
			_debug("Cached scene: " + node_source + " (cache size: " + str(scene_cache.size()) + ")")
		new_node = scene.instantiate()
	else:
		new_node = ClassDB.instantiate(node_source)
		if not new_node:
			_debug("Failed to create node of type: " + node_source)
			return null
	
	return new_node

func _instantiate_node(node_source: String, node_name: String, parent_path: String = "", callback: Callable = Callable()) -> bool:
	_debug("=== _instantiate_node START ===")
	_debug("  Source: " + node_source)
	_debug("  Name: " + node_name)
	_debug("  Parent path: " + parent_path)
	
	var parent_node_target = _get_parent_node_for_instantiation(parent_path)
	if not parent_node_target:
		_debug("ERROR: Parent node not found!")
		return false
	
	_debug("  Parent found: " + parent_node_target.name)
	
	var new_node = _create_node(node_source)
	if not new_node:
		_debug("ERROR: Failed to create node!")
		return false
	
	_debug("  Node created: " + str(new_node))
	
	new_node.name = node_name
	
	# Mark as network-spawned if we're a client
	if owdb and owdb.is_network_peer():
		new_node.set_meta("_network_spawned", true)
		_debug("  Marked as network-spawned (PEER mode)")
	
	if callback.is_valid():
		_debug("  Calling callback")
		callback.call(new_node)
	
	_debug("  Adding child to parent")
	parent_node_target.add_child(new_node)
	
	if not Engine.is_editor_hint() and owdb and owdb.syncer and is_instance_valid(owdb.syncer):
		if not owdb.syncer.is_node_registered(new_node):
			_debug("  Registering with syncer")
			owdb.syncer.register_node(new_node, node_source, 1, {}, null)
	
	_debug("=== _instantiate_node COMPLETE ===")
	return true

func _immediate_load_node(uid: String):
	if not owdb or uid not in owdb.node_monitor.stored_nodes:
		return

	if owdb.loaded_nodes_by_uid.has(uid):
		return
		
	var node_info = owdb.node_monitor.stored_nodes[uid]
	
	# Handle parent loading logic
	var parent_node_target = owdb
	if node_info.parent_uid != "":
		var parent = owdb.loaded_nodes_by_uid.get(node_info.parent_uid)
		if parent:
			parent_node_target = parent
		else:
			parent_node_target = _ensure_parent_loaded(node_info.parent_uid)
	
	var new_node = _create_node(node_info.scene)
	
	if not new_node:
		_debug("Failed to create node for UID: " + uid)
		return

	new_node.set_meta("_owd_uid", uid)
	new_node.name = uid
	
	owdb.node_monitor.apply_stored_properties(new_node, node_info.properties)
	
	parent_node_target.add_child(new_node)
	new_node.owner = owdb.owner
	
	if new_node is Node3D:
		new_node.global_position = node_info.position
		new_node.global_rotation = node_info.rotation
		new_node.scale = node_info.scale
	
	owdb.loaded_nodes_by_uid[uid] = new_node
	owdb._setup_listeners(new_node)
	
	_debug("NODE LOADED: " + uid + " at " + str(node_info.position))

func _ensure_parent_loaded(parent_uid: String) -> Node:
	# Check if parent is already loaded
	var existing_parent = owdb.loaded_nodes_by_uid.get(parent_uid)
	if existing_parent:
		return existing_parent
	
	# Check if parent exists in database
	if not owdb.node_monitor.stored_nodes.has(parent_uid):
		return owdb
	
	var parent_info = owdb.node_monitor.stored_nodes[parent_uid]
	var parent_size_cat = owdb.get_size_category(parent_info.size)
	var parent_chunk_pos = NodeUtils.get_chunk_position(parent_info.position, owdb.chunk_sizes[parent_size_cat]) if parent_size_cat != OpenWorldDatabase.Size.ALWAYS_LOADED else OpenWorldDatabase.ALWAYS_LOADED_CHUNK_POS
	
	# Check if parent's chunk should be loaded
	if owdb.chunk_manager.is_chunk_loaded(parent_size_cat, parent_chunk_pos):
		# Recursively load the parent
		_immediate_load_node(parent_uid)
		return owdb.loaded_nodes_by_uid.get(parent_uid, owdb)
	else:
		return owdb

func _immediate_unload_node(uid: String):
	if not owdb:
		return
		
	var node = owdb.loaded_nodes_by_uid.get(uid)
	if not node:
		return
	
	owdb.nodes_being_unloaded[uid] = true
	
	var node_info = owdb.node_monitor.stored_nodes.get(uid, {})
	if not node_info.is_empty():
		if node is Node3D:
			node_info.position = node.global_position
			node_info.rotation = node.global_rotation
			node_info.scale = node.scale
	
	owdb.loaded_nodes_by_uid.erase(uid)
	node.free()
	
	owdb.call_deferred("_cleanup_unload_tracking", uid)
	_debug("NODE UNLOADED: " + uid)

func _remove_scene_node(node_name: String) -> bool:
	if not owdb or not owdb.loaded_nodes_by_uid.has(node_name):
		return false
		
	var node = owdb.loaded_nodes_by_uid.get(node_name)
	if node and is_instance_valid(node):
		node.queue_free()
		owdb.loaded_nodes_by_uid.erase(node_name)
		return true
	return false

func _get_parent_node_for_instantiation(parent_path: String) -> Node:
	var tree = _get_scene_tree()
	if not tree or not tree.current_scene:
		return null
	
	if parent_path.is_empty():
		return tree.current_scene
	
	var parent_node_result = tree.current_scene.get_node(parent_path)
	if not parent_node_result:
		push_error("Parent path not found: " + parent_path)
		return tree.current_scene
	
	return parent_node_result

func _is_load_operation_valid(uid: String) -> bool:
	if not owdb or not owdb.node_monitor.stored_nodes.has(uid):
		return false
	
	var node_info = owdb.node_monitor.stored_nodes[uid]
	var size_cat = owdb.get_size_category(node_info.size)
	var chunk_pos = Vector2i(int(node_info.position.x / owdb.chunk_sizes[size_cat]), int(node_info.position.z / owdb.chunk_sizes[size_cat])) if size_cat != OpenWorldDatabase.Size.ALWAYS_LOADED else OpenWorldDatabase.ALWAYS_LOADED_CHUNK_POS
	
	var chunk_should_be_loaded = owdb.chunk_manager.is_chunk_loaded(size_cat, chunk_pos)
	var is_currently_loaded = owdb.loaded_nodes_by_uid.has(uid)
	
	return chunk_should_be_loaded and not is_currently_loaded

func _is_unload_operation_valid(uid: String) -> bool:
	if not owdb or not owdb.node_monitor.stored_nodes.has(uid):
		return false
	
	var node_info = owdb.node_monitor.stored_nodes[uid]
	var size_cat = owdb.get_size_category(node_info.size)
	var chunk_pos = Vector2i(int(node_info.position.x / owdb.chunk_sizes[size_cat]), int(node_info.position.z / owdb.chunk_sizes[size_cat])) if size_cat != OpenWorldDatabase.Size.ALWAYS_LOADED else OpenWorldDatabase.ALWAYS_LOADED_CHUNK_POS
	
	var chunk_should_be_loaded = owdb.chunk_manager.is_chunk_loaded(size_cat, chunk_pos)
	var is_currently_loaded = owdb.loaded_nodes_by_uid.has(uid)
	
	return not chunk_should_be_loaded and is_currently_loaded

func queue_operation(type: OperationType, data: Dictionary, callback: Callable = Callable()) -> String:
	var operation_id = _generate_operation_id()
	
	pending_operations[operation_id] = {
		"type": type,
		"data": data,
		"callback": callback,
		"timestamp": Time.get_ticks_msec()
	}
	operation_order.append(operation_id)
	
	_debug("Operation queued: " + str(type) + " ID: " + operation_id)
	_debug("  Batch timer running: " + str(batch_timer.time_left > 0))
	_debug("  Batch processing enabled: " + str(batch_processing_enabled))
	
	if batch_processing_enabled and not batch_timer.time_left > 0:
		_debug("Starting batch timer")
		batch_timer.start()
	
	return operation_id

func load_node(uid: String):
	if batch_processing_enabled:
		queue_operation(OperationType.LOAD_NODE, {"uid": uid})
	else:
		if _is_load_operation_valid(uid):
			_immediate_load_node(uid)

func unload_node(uid: String):
	if batch_processing_enabled:
		queue_operation(OperationType.UNLOAD_NODE, {"uid": uid})
	else:
		if _is_unload_operation_valid(uid):
			_immediate_unload_node(uid)

func instantiate_scene(scene_path: String, node_name: String, parent_path: String = "", callback: Callable = Callable()) -> String:
	_debug("=== instantiate_scene called ===")
	_debug("  Scene path: " + scene_path)
	_debug("  Node name: " + node_name)
	_debug("  Parent path: " + parent_path)
	_debug("  Batch processing enabled: " + str(batch_processing_enabled))
	
	if batch_processing_enabled:
		_debug("Queueing instantiate operation")
		return queue_operation(OperationType.INSTANTIATE_SCENE, {
			"scene_path": scene_path,
			"node_name": node_name,
			"parent_path": parent_path
		}, callback)
	else:
		_debug("Processing instantiate immediately")
		_instantiate_node(scene_path, node_name, parent_path, callback)
		return node_name

func remove_scene_node(node_name: String):
	if batch_processing_enabled:
		queue_operation(OperationType.REMOVE_NODE, {"node_name": node_name})
	else:
		_remove_scene_node(node_name)

func _generate_operation_id() -> String:
	return str(Time.get_ticks_msec()) + "_" + str(randi() % 10000)

func _notify_batch_complete():
	for callback in batch_complete_callbacks:
		if callback.is_valid():
			callback.call()

func _debug(message: String):
	if owdb:
		owdb.debug(message)
	else:
		print(message)

func force_process_queues():
	var start_time = Time.get_ticks_msec()
	var total_operations = operation_order.size()
	var actual_operations = 0
	
	while not operation_order.is_empty():
		var operation_id = operation_order.pop_front()
		
		if not pending_operations.has(operation_id):
			continue
		
		var operation = pending_operations[operation_id]
		
		match operation.type:
			OperationType.LOAD_NODE:
				if _process_load_node_operation(operation):
					actual_operations += 1
			OperationType.UNLOAD_NODE:
				if _process_unload_node_operation(operation):
					actual_operations += 1
			OperationType.INSTANTIATE_SCENE:
				if _process_instantiate_scene_operation(operation):
					actual_operations += 1
			OperationType.REMOVE_NODE:
				if _process_remove_node_operation(operation):
					actual_operations += 1
		
		pending_operations.erase(operation_id)
	
	if batch_timer:
		batch_timer.stop()
	
	_notify_batch_complete()
	
	var time_taken = Time.get_ticks_msec() - start_time
	_debug("Force processed " + str(actual_operations) + "/" + str(total_operations) + " operations in " + str(time_taken) + "ms")

func cleanup_invalid_operations():
	if not owdb:
		return
		
	var invalid_ids = []
	
	for operation_id in pending_operations:
		var operation = pending_operations[operation_id]
		var is_valid = false
		
		match operation.type:
			OperationType.LOAD_NODE:
				is_valid = _is_load_operation_valid(operation.data.get("uid", ""))
			OperationType.UNLOAD_NODE:
				is_valid = _is_unload_operation_valid(operation.data.get("uid", ""))
			OperationType.INSTANTIATE_SCENE, OperationType.REMOVE_NODE:
				is_valid = true
		
		if not is_valid:
			invalid_ids.append(operation_id)
	
	for operation_id in invalid_ids:
		pending_operations.erase(operation_id)
		operation_order.erase(operation_id)
	
	if invalid_ids.size() > 0:
		_debug("Cleaned up " + str(invalid_ids.size()) + " invalid operations from queue")

func update_batch_settings():
	if batch_timer:
		batch_timer.wait_time = batch_interval_ms / 1000.0

func remove_from_queues(uid: String):
	var ids_to_remove = []
	for operation_id in pending_operations:
		var operation = pending_operations[operation_id]
		if operation.data.has("uid") and operation.data.uid == uid:
			ids_to_remove.append(operation_id)
	
	for operation_id in ids_to_remove:
		pending_operations.erase(operation_id)
		operation_order.erase(operation_id)

func add_batch_complete_callback(callback: Callable):
	if not callback in batch_complete_callbacks:
		batch_complete_callbacks.append(callback)

func remove_batch_complete_callback(callback: Callable):
	batch_complete_callbacks.erase(callback)

func get_queue_info() -> Dictionary:
	var load_count = 0
	var unload_count = 0
	var instantiate_count = 0
	var remove_count = 0
	
	for operation_id in pending_operations:
		var operation = pending_operations[operation_id]
		match operation.type:
			OperationType.LOAD_NODE:
				load_count += 1
			OperationType.UNLOAD_NODE:
				unload_count += 1
			OperationType.INSTANTIATE_SCENE:
				instantiate_count += 1
			OperationType.REMOVE_NODE:
				remove_count += 1
	
	return {
		"total_queue_size": operation_order.size(),
		"load_operations_queued": load_count,
		"unload_operations_queued": unload_count,
		"instantiate_operations_queued": instantiate_count,
		"remove_operations_queued": remove_count,
		"batch_processing_active": batch_timer.time_left > 0,
		"is_processing_batch": is_processing_batch,
		"scene_cache_size": scene_cache.size()
	}
