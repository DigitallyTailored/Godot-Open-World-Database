@tool
extends RefCounted
class_name BatchProcessor

var owdb: OpenWorldDatabase

# Batch processing configuration
var batch_time_limit_ms: float = 5.0
var batch_interval_ms: float = 100.0
var batch_processing_enabled: bool = true

# Optimized queue system using Dictionary for O(1) operations
var pending_operations: Dictionary = {} # uid -> {action: String, timestamp: float}
var operation_order: Array = [] # UIDs in processing order
var batch_timer: Timer
var is_processing_batch: bool = false
var batch_complete_callbacks: Array[Callable] = []

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database

func setup():
	batch_timer = Timer.new()
	owdb.add_child(batch_timer)
	batch_timer.wait_time = batch_interval_ms / 1000.0
	batch_timer.timeout.connect(_process_batch)
	batch_timer.autostart = false
	batch_timer.one_shot = false

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
		var uid = operation_order.pop_front()
		
		if not pending_operations.has(uid):
			continue # Operation was cancelled
		
		var operation = pending_operations[uid]
		
		# CRITICAL FIX: Validate operation is still needed based on current chunk state
		if not _is_operation_still_valid(uid, operation.action):
			pending_operations.erase(uid)
			continue
		
		var is_loaded = owdb.loaded_nodes_by_uid.has(uid)
		
		if operation.action == "load" and not is_loaded:
			owdb._immediate_load_node(uid)
			operations_performed += 1
		elif operation.action == "unload" and is_loaded:
			owdb._immediate_unload_node(uid)
			operations_performed += 1
		
		pending_operations.erase(uid)
		
		if Time.get_ticks_msec() - start_time >= batch_time_limit_ms:
			break
	
	if operation_order.is_empty():
		batch_timer.stop()
		
		for callback in batch_complete_callbacks:
			if callback.is_valid():
				callback.call()
		
		owdb.debug_log("Batch processing completed. All operations processed.")
	
	if operations_performed > 0:
		var time_taken = Time.get_ticks_msec() - start_time
		owdb.debug_log("Batch processed " + str(operations_performed) + " operations in " + str(time_taken) + "ms. Remaining: " + str(operation_order.size()))
	
	is_processing_batch = false

# NEW: Validate if operation is still needed based on current chunk requirements
func _is_operation_still_valid(uid: String, action: String) -> bool:
	if not owdb.node_monitor.stored_nodes.has(uid):
		return false  # Node doesn't exist in database
	
	var node_info = owdb.node_monitor.stored_nodes[uid]
	var size_cat = owdb.get_size_category(node_info.size)
	var chunk_pos = Vector2i(int(node_info.position.x / owdb.chunk_sizes[size_cat]), int(node_info.position.z / owdb.chunk_sizes[size_cat])) if size_cat != OpenWorldDatabase.Size.ALWAYS_LOADED else OpenWorldDatabase.ALWAYS_LOADED_CHUNK_POS
	
	var chunk_should_be_loaded = owdb.chunk_manager.is_chunk_loaded(size_cat, chunk_pos)
	var is_currently_loaded = owdb.loaded_nodes_by_uid.has(uid)
	
	# Validate the operation makes sense given current chunk state
	if action == "load":
		return chunk_should_be_loaded and not is_currently_loaded
	elif action == "unload":
		return not chunk_should_be_loaded and is_currently_loaded
	
	return false

func _queue_operation(uid: String, action: String):
	# First validate the operation is needed
	if not _is_operation_still_valid(uid, action):
		return  # Don't queue operations that aren't needed
	
	# Remove existing operation if different action
	if uid in pending_operations:
		if pending_operations[uid].action != action:
			operation_order.erase(uid)
			operation_order.append(uid)
		else:
			# Same operation already queued, just update timestamp
			pending_operations[uid].timestamp = Time.get_ticks_msec()
			return
	else:
		operation_order.append(uid)
	
	pending_operations[uid] = {
		"action": action,
		"timestamp": Time.get_ticks_msec()
	}
	
	if batch_processing_enabled and not batch_timer.time_left > 0:
		batch_timer.start()

func load_node(uid: String):
	if batch_processing_enabled:
		_queue_operation(uid, "load")
	else:
		if _is_operation_still_valid(uid, "load"):
			owdb._immediate_load_node(uid)

func unload_node(uid: String):
	if batch_processing_enabled:
		_queue_operation(uid, "unload")
	else:
		if _is_operation_still_valid(uid, "unload"):
			owdb._immediate_unload_node(uid)

func clear_queues():
	pending_operations.clear()
	operation_order.clear()
	if batch_timer:
		batch_timer.stop()

func force_process_queues():
	var start_time = Time.get_ticks_msec()
	var total_operations = operation_order.size()
	var actual_operations = 0
	
	while not operation_order.is_empty():
		var uid = operation_order.pop_front()
		
		if not pending_operations.has(uid):
			continue
		
		var operation = pending_operations[uid]
		
		# Validate operation is still needed
		if not _is_operation_still_valid(uid, operation.action):
			pending_operations.erase(uid)
			continue
		
		var is_loaded = owdb.loaded_nodes_by_uid.has(uid)
		
		if operation.action == "load" and not is_loaded:
			owdb._immediate_load_node(uid)
			actual_operations += 1
		elif operation.action == "unload" and is_loaded:
			owdb._immediate_unload_node(uid)
			actual_operations += 1
		
		pending_operations.erase(uid)
	
	if batch_timer:
		batch_timer.stop()
	
	for callback in batch_complete_callbacks:
		if callback.is_valid():
			callback.call()
	
	var time_taken = Time.get_ticks_msec() - start_time
	owdb.debug_log("Force processed " + str(actual_operations) + "/" + str(total_operations) + " operations in " + str(time_taken) + "ms")

# NEW: Clean up invalid operations from queue
func cleanup_invalid_operations():
	var invalid_uids = []
	
	for uid in pending_operations:
		var operation = pending_operations[uid]
		if not _is_operation_still_valid(uid, operation.action):
			invalid_uids.append(uid)
	
	for uid in invalid_uids:
		pending_operations.erase(uid)
		operation_order.erase(uid)
	
	if invalid_uids.size() > 0:
		owdb.debug_log("Cleaned up " + str(invalid_uids.size()) + " invalid operations from queue")

func update_batch_settings():
	if batch_timer:
		batch_timer.wait_time = batch_interval_ms / 1000.0

func remove_from_queues(uid: String):
	if uid in pending_operations:
		pending_operations.erase(uid)
		operation_order.erase(uid)

func add_batch_complete_callback(callback: Callable):
	if not callback in batch_complete_callbacks:
		batch_complete_callbacks.append(callback)

func remove_batch_complete_callback(callback: Callable):
	batch_complete_callbacks.erase(callback)

func get_queue_info() -> Dictionary:
	var load_count = 0
	var unload_count = 0
	
	for uid in pending_operations:
		if pending_operations[uid].action == "load":
			load_count += 1
		elif pending_operations[uid].action == "unload":
			unload_count += 1
	
	return {
		"total_queue_size": operation_order.size(),
		"load_operations_queued": load_count,
		"unload_operations_queued": unload_count,
		"batch_processing_active": batch_timer.time_left > 0,
		"is_processing_batch": is_processing_batch
	}
