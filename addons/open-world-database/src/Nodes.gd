# global/Nodes.gd
extends Node
class_name Nodes

signal batch_completed(count)
signal all_entities_loaded
signal batch_removed(count)
signal all_entities_removed

# Configuration
var batch_time_limit_ms := 10.0
var interval_between_batches_ms := 50.0

# Internal state
var _entity_queue := {}  # Dictionary: id -> [path, callback, parent_path]
var _removal_queue := []  # Array of node_names to remove
var _is_processing := false
var _interval_timer := Timer.new()
var _loaded := {}  # Dictionary: id -> instance
var _scene_cache := {}  # Dictionary: path -> loaded_scene

var _free_node_name = 1
var tree : SceneTree
var parent : Node

# Static-like accessor for loaded entities
func get_loaded() -> Dictionary:
	return _loaded

func _init(parent_in) -> void:
	parent = parent_in
	tree = parent.get_tree()
	_interval_timer.one_shot = true
	_interval_timer.wait_time = interval_between_batches_ms / 1000.0
	_interval_timer.timeout.connect(_on_interval_timeout)
	parent.add_child(_interval_timer)
	
# Queue an entity with callback
func add(entity_path: String, parent_path: String = "", callback: Callable = Callable()) -> String:
	var node_name = entity_path.get_basename().get_file() + str(_free_node_name)
	_free_node_name += 1
	
	return add_id(node_name, entity_path, parent_path, callback)

# Queue an entity with custom ID and callback
func add_id(node_name: String, entity_path: String, parent_path = "", callback: Callable = Callable()) -> String:
	# Add to queue or update if already queued
	_entity_queue[node_name] = [entity_path, callback, parent_path]
	
	if not _is_processing:
		_is_processing = true
		call_deferred("_process_next_batch")
	
	return node_name

# Queue entity for removal - only adds to queue
func remove(node_name: String) -> void:
	_removal_queue.append(node_name)
	
	if not _is_processing:
		_is_processing = true
		call_deferred("_process_next_batch")

func random_string(length: int = 3) -> String:
	var characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	var result = ""
	
	for i in range(length):
		var random_index = randi() % characters.length()
		result += characters[random_index]
	
	return result

# Get node by name
func get_node_by_name(node_name: String) -> Node:
	# Try to find in loaded entities first
	if _loaded.has(node_name):
		return _loaded[node_name]
	
	# Fallback to searching in default parent
	if tree.current_scene.has_node(node_name):
		return tree.current_scene.get_node(node_name)
	
	# Search globally as last resort
	return get_node("/root").find_child(node_name, true, false)

# Get parent node from path
func _get_parent_node(parent_path: String) -> Node:
	if parent_path.is_empty():
		return tree.current_scene
	
	var parent_node = tree.current_scene.get_node(parent_path)
	if not parent_node:
		push_error("Parent path not found: " + parent_path)
		return tree.current_scene
	
	return parent_node

# Process next batch of Nodes (both adding and removing)
func _process_next_batch() -> void:
	var start_time := Time.get_ticks_msec()
	var total_time_available := batch_time_limit_ms
	
	var has_entities_to_add := not _entity_queue.is_empty()
	var has_entities_to_remove := not _removal_queue.is_empty()
	
	# Calculate time allocation
	var add_time_limit := total_time_available
	var remove_time_limit := total_time_available
	
	if has_entities_to_add and has_entities_to_remove:
		# Split time between adding and removing
		add_time_limit = total_time_available / 2.0
		remove_time_limit = total_time_available / 2.0
	
	# Process removal queue first
	var removed_count := 0
	if has_entities_to_remove:
		var removal_start_time := Time.get_ticks_msec()
		while not _removal_queue.is_empty() and (Time.get_ticks_msec() - removal_start_time) < remove_time_limit:
			var node_name = _removal_queue.pop_front()
			
			# Handle removing from add queue if not yet loaded
			if _entity_queue.has(node_name):
				_entity_queue.erase(node_name)
				continue
			
			# Handle removing loaded entity
			if _loaded.has(node_name):
				var instance = _loaded[node_name]
				if is_instance_valid(instance):
					instance.queue_free()
				
				_loaded.erase(node_name)
				removed_count += 1
		
		if removed_count > 0:
			batch_removed.emit(removed_count)
		
		if _removal_queue.is_empty():
			all_entities_removed.emit()
	
	# Process add queue
	var loaded_count := 0
	if has_entities_to_add:
		var sorted_ids = _entity_queue.keys()
		var add_start_time := Time.get_ticks_msec()
		
		while not sorted_ids.is_empty() and (Time.get_ticks_msec() - add_start_time) < add_time_limit:
			var node_name = sorted_ids.pop_front()
			
			# Skip if no longer needed
			if not _entity_queue.has(node_name):
				continue
			
			var entity_data = _entity_queue[node_name]
			var entity_path = entity_data[0]
			var callback = entity_data[1]
			var parent_path = entity_data[2] if entity_data.size() > 2 else ""
			
			# Remove from queue
			_entity_queue.erase(node_name)
			
			# Get the parent node
			var parent_node = _get_parent_node(parent_path)
			if not parent_node:
				continue
			
			# Load and instance the entity (with caching)
			var entity_scene
			if _scene_cache.has(entity_path):
				entity_scene = _scene_cache[entity_path]
			else:
				entity_scene = load(entity_path)
				_scene_cache[entity_path] = entity_scene
				
			var entity_instance = entity_scene.instantiate()
			entity_instance.name = node_name
			
			# Execute the callback if provided
			if callback.is_valid():
				callback.call(entity_instance)
				
			parent_node.add_child(entity_instance)
			loaded_count += 1
			
			# Store reference to loaded entity
			_loaded[node_name] = entity_instance
		
		if loaded_count > 0:
			batch_completed.emit(loaded_count)
		
		if _entity_queue.is_empty():
			all_entities_loaded.emit()
	
	# Check if we need to continue processing
	if _entity_queue.is_empty() and _removal_queue.is_empty():
		_is_processing = false
	else:
		# Wait before processing the next batch
		_interval_timer.start()

func _on_interval_timeout() -> void:
	_process_next_batch()
