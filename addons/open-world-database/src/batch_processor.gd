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
		
		if owdb.debug_enabled:
			print("Batch processing completed. All operations processed.")
	
	if owdb.debug_enabled and operations_performed > 0:
		var time_taken = Time.get_ticks_msec() - start_time
		print("Batch processed ", operations_performed, " operations in ", time_taken, "ms. Remaining: ", operation_order.size())
	
	is_processing_batch = false

func _queue_operation(uid: String, action: String):
	# Remove existing operation if different action
	if uid in pending_operations:
		if pending_operations[uid].action != action:
			operation_order.erase(uid)
			operation_order.append(uid)
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
		if not owdb.loaded_nodes_by_uid.has(uid):
			_queue_operation(uid, "load")
	else:
		if not owdb.loaded_nodes_by_uid.has(uid):
			owdb._immediate_load_node(uid)

func unload_node(uid: String):
	if batch_processing_enabled:
		if owdb.loaded_nodes_by_uid.has(uid):
			_queue_operation(uid, "unload")
	else:
		if owdb.loaded_nodes_by_uid.has(uid):
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
	
	if owdb.debug_enabled:
		var time_taken = Time.get_ticks_msec() - start_time
		print("Force processed ", actual_operations, "/", total_operations, " operations in ", time_taken, "ms")

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
