@tool
extends RefCounted
class_name BatchProcessor

var owdb: OpenWorldDatabase
var parent_node: Node

# Batch processing configuration
var batch_time_limit_ms: float = 5.0
var batch_interval_ms: float = 100.0
var batch_processing_enabled: bool = true

# Generic operation system
var pending_operations: Dictionary = {} # operation_id -> {type: String, data: Dictionary, callback: Callable}
var operation_order: Array = [] # operation_ids in processing order
var batch_timer: Timer
var is_processing_batch: bool = false
var batch_complete_callbacks: Array[Callable] = []

# Operation types
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
		
		# Process based on operation type
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
		_debug_log("Batch processed " + str(operations_performed) + " operations in " + str(time_taken) + "ms. Remaining: " + str(operation_order.size()))
	
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

# Consolidated node instantiation (handles both scenes and node types)
func _instantiate_node(node_source: String, node_name: String, parent_path: String = "", callback: Callable = Callable()) -> bool:
	var parent_node_target = _get_parent_node_for_instantiation(parent_path)
	if not parent_node_target:
		return false
	
	var new_node: Node
	
	# Use the same logic as _immediate_load_node for consistency
	if node_source.begins_with("res://"):
		var scene = load(node_source)
		if not scene:
			_debug_log("Failed to load scene: " + node_source)
			return false
		new_node = scene.instantiate()
	else:
		new_node = ClassDB.instantiate(node_source)
		if not new_node:
			_debug_log("Failed to create node of type: " + node_source)
			return false
	
	new_node.name = node_name
	
	if callback.is_valid():
		callback.call(new_node)
	
	parent_node_target.add_child(new_node)
	
	# Register with Syncer if available and not in editor
	if not Engine.is_editor_hint() and Syncer and (Syncer.has_method("is_placeholder") and not Syncer.is_placeholder()):
		if not Syncer.is_node_registered(new_node):
			Syncer.register_node(new_node, node_source, 1, {}, null)
	
	return true

func _immediate_load_node(uid: String):
	if not owdb or uid not in owdb.node_monitor.stored_nodes:
		return
	
	if owdb.loaded_nodes_by_uid.has(uid):
		return
		
	var node_info = owdb.node_monitor.stored_nodes[uid]
	var new_node = _create_node_from_source(node_info.scene)
	
	if not new_node:
		_debug_log("Failed to create node for UID: " + uid)
		return
	
	new_node.set_meta("_owd_uid", uid)
	new_node.name = uid
	
	var parent_node_target = owdb
	if node_info.parent_uid != "":
		var parent = owdb.loaded_nodes_by_uid.get(node_info.parent_uid)
		if parent:
			parent_node_target = parent
	
	# Apply properties using resource manager
	owdb.node_monitor.apply_stored_properties(new_node, node_info.properties)
	
	parent_node_target.add_child(new_node)
	new_node.owner = owdb.owner
	
	if new_node is Node3D:
		new_node.global_position = node_info.position
		new_node.global_rotation = node_info.rotation
		new_node.scale = node_info.scale
	
	owdb.loaded_nodes_by_uid[uid] = new_node
	owdb._setup_listeners(new_node)
	
	_debug_log("NODE LOADED: " + uid + " at " + str(node_info.position))

# Consolidated node creation logic
func _create_node_from_source(node_source: String) -> Node:
	if node_source.begins_with("res://"):
		var scene = load(node_source)
		if not scene:
			return null
		return scene.instantiate()
	else:
		return ClassDB.instantiate(node_source)

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
	_debug_log("NODE UNLOADED: " + uid)

func _remove_scene_node(node_name: String) -> bool:
	var tree = _get_scene_tree()
	if not tree or not tree.current_scene:
		return false
		
	var node = tree.current_scene.find_child(node_name, true, false)
	if node and is_instance_valid(node):
		node.queue_free()
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

# Validation methods
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

# Public interface methods
func queue_operation(type: OperationType, data: Dictionary, callback: Callable = Callable()) -> String:
	var operation_id = _generate_operation_id()
	
	pending_operations[operation_id] = {
		"type": type,
		"data": data,
		"callback": callback,
		"timestamp": Time.get_ticks_msec()
	}
	operation_order.append(operation_id)
	
	if batch_processing_enabled and not batch_timer.time_left > 0:
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
	if batch_processing_enabled:
		return queue_operation(OperationType.INSTANTIATE_SCENE, {
			"scene_path": scene_path,
			"node_name": node_name,
			"parent_path": parent_path
		}, callback)
	else:
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

func _debug_log(message: String):
	if owdb:
		owdb.debug_log(message)
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
	_debug_log("Force processed " + str(actual_operations) + "/" + str(total_operations) + " operations in " + str(time_taken) + "ms")

func cleanup_invalid_operations():
	if not owdb:
		return  # Skip cleanup if no OWDB (scene operations don't need validation)
		
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
				is_valid = true # These are always valid when queued
		
		if not is_valid:
			invalid_ids.append(operation_id)
	
	for operation_id in invalid_ids:
		pending_operations.erase(operation_id)
		operation_order.erase(operation_id)
	
	if invalid_ids.size() > 0:
		_debug_log("Cleaned up " + str(invalid_ids.size()) + " invalid operations from queue")

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
		"is_processing_batch": is_processing_batch
	}
