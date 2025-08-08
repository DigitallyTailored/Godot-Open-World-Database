@tool
extends RefCounted
class_name BatchProcessor

var owdb: OpenWorldDatabase

# Batch processing configuration
var batch_time_limit_ms: float = 5.0
var batch_interval_ms: float = 100.0
var batch_processing_enabled: bool = true

# Simple queue system
var operation_queue: Array = []  # Array of {uid: String, action: String}
var batch_timer: Timer
var is_processing_batch: bool = false

# Callbacks for chunk manager
var batch_complete_callbacks: Array[Callable] = []

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database

func setup():
	# Create timer for batch processing
	batch_timer = Timer.new()
	owdb.add_child(batch_timer)
	batch_timer.wait_time = batch_interval_ms / 1000.0
	batch_timer.timeout.connect(_process_batch)
	batch_timer.autostart = false
	batch_timer.one_shot = false

func reset():
	operation_queue.clear()
	batch_complete_callbacks.clear()
	if batch_timer:
		batch_timer.stop()

func _is_node_currently_loaded(uid: String) -> bool:
	for node in owdb.get_all_owd_nodes():
		if node.has_meta("_owd_uid") and node.get_meta("_owd_uid") == uid:
			return true
	return false

func _remove_existing_operations(uid: String):
	for i in range(operation_queue.size() - 1, -1, -1):
		if operation_queue[i].uid == uid:
			operation_queue.remove_at(i)

func _process_batch():
	if is_processing_batch:
		return
	
	is_processing_batch = true
	var start_time = Time.get_ticks_msec()
	var operations_performed = 0
	
	# Process operations in order until time limit or queue is empty
	while not operation_queue.is_empty():
		var operation = operation_queue.pop_front()
		
		# Double-check if the operation is still needed
		var is_loaded = _is_node_currently_loaded(operation.uid)
		
		if operation.action == "load" and not is_loaded:
			owdb._immediate_load_node(operation.uid)
			operations_performed += 1
		elif operation.action == "unload" and is_loaded:
			owdb._immediate_unload_node(operation.uid)
			operations_performed += 1
		# Skip operation if it's no longer needed
		
		# Check time limit
		if Time.get_ticks_msec() - start_time >= batch_time_limit_ms:
			break
	
	# Stop timer if queue is empty
	if operation_queue.is_empty():
		batch_timer.stop()
		
		# Call completion callbacks
		for callback in batch_complete_callbacks:
			if callback.is_valid():
				callback.call()
		
		if owdb.debug_enabled:
			print("Batch processing completed. All operations processed.")
	
	if owdb.debug_enabled and operations_performed > 0:
		var time_taken = Time.get_ticks_msec() - start_time
		print("Batch processed ", operations_performed, " operations in ", time_taken, "ms. Remaining: ", operation_queue.size())
	
	is_processing_batch = false

func _start_batch_processing_if_needed():
	if batch_processing_enabled and not batch_timer.time_left > 0 and not operation_queue.is_empty():
		batch_timer.start()
		if owdb.debug_enabled:
			print("Started batch processing. Operations pending: ", operation_queue.size())

func queue_load_node(uid: String):
	# Remove any existing operations for this node
	_remove_existing_operations(uid)
	
	# Only queue if the node is not already loaded
	if not _is_node_currently_loaded(uid):
		operation_queue.append({"uid": uid, "action": "load"})
		_start_batch_processing_if_needed()

func queue_unload_node(uid: String):
	# Remove any existing operations for this node
	_remove_existing_operations(uid)
	
	# Only queue if the node is currently loaded
	if _is_node_currently_loaded(uid):
		operation_queue.append({"uid": uid, "action": "unload"})
		_start_batch_processing_if_needed()

func load_node(uid: String):
	if batch_processing_enabled:
		queue_load_node(uid)
	else:
		if not _is_node_currently_loaded(uid):
			owdb._immediate_load_node(uid)

func unload_node(uid: String):
	if batch_processing_enabled:
		queue_unload_node(uid)
	else:
		if _is_node_currently_loaded(uid):
			owdb._immediate_unload_node(uid)

func clear_queues():
	operation_queue.clear()
	if batch_timer:
		batch_timer.stop()

func force_process_queues():
	var start_time = Time.get_ticks_msec()
	var total_operations = operation_queue.size()
	var actual_operations = 0
	
	# Process all operations
	while not operation_queue.is_empty():
		var operation = operation_queue.pop_front()
		
		# Double-check if the operation is still needed
		var is_loaded = _is_node_currently_loaded(operation.uid)
		
		if operation.action == "load" and not is_loaded:
			owdb._immediate_load_node(operation.uid)
			actual_operations += 1
		elif operation.action == "unload" and is_loaded:
			owdb._immediate_unload_node(operation.uid)
			actual_operations += 1
	
	if batch_timer:
		batch_timer.stop()
	
	# Call completion callbacks
	for callback in batch_complete_callbacks:
		if callback.is_valid():
			callback.call()
	
	if owdb.debug_enabled:
		var time_taken = Time.get_ticks_msec() - start_time
		print("Force processed ", actual_operations, "/", total_operations, " operations in ", time_taken, "ms")

func update_batch_settings():
	if batch_timer:
		batch_timer.wait_time = batch_interval_ms / 1000.0

func remove_from_queues(uid: String):
	_remove_existing_operations(uid)

func add_batch_complete_callback(callback: Callable):
	if not callback in batch_complete_callbacks:
		batch_complete_callbacks.append(callback)

func remove_batch_complete_callback(callback: Callable):
	batch_complete_callbacks.erase(callback)

func get_queue_info() -> Dictionary:
	var load_count = 0
	var unload_count = 0
	
	for operation in operation_queue:
		if operation.action == "load":
			load_count += 1
		elif operation.action == "unload":
			unload_count += 1
	
	return {
		"total_queue_size": operation_queue.size(),
		"load_operations_queued": load_count,
		"unload_operations_queued": unload_count,
		"batch_processing_active": batch_timer.time_left > 0,
		"is_processing_batch": is_processing_batch
	}
