@tool
extends RefCounted
class_name ChunkManager

var owdb: OpenWorldDatabase
var loaded_chunks: Dictionary = {}
var previous_required_chunks: Dictionary = {}
var pending_chunk_operations: Dictionary = {} # chunk_key -> "load"/"unload"
var last_camera_position: Vector3
var batch_callback_registered: bool = false

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database
	reset()

func reset():
	for size in OpenWorldDatabase.Size.values():
		loaded_chunks[size] = {}
		previous_required_chunks[size] = {}
	pending_chunk_operations.clear()
	batch_callback_registered = false

func is_chunk_loaded(size_cat: OpenWorldDatabase.Size, chunk_pos: Vector2i) -> bool:
	if size_cat == OpenWorldDatabase.Size.ALWAYS_LOADED:
		return true
	
	var chunk_key = Vector3(size_cat, chunk_pos.x, chunk_pos.y)
	
	if pending_chunk_operations.has(chunk_key):
		return pending_chunk_operations[chunk_key] == "load"
	
	return loaded_chunks.has(size_cat) and loaded_chunks[size_cat].has(chunk_pos)

func _find_position_node() -> OWDBPosition:
	# Search for OWDBPosition node in the tree
	var root = owdb.get_tree().root
	return _find_position_node_recursive(root)

func _find_position_node_recursive(node: Node) -> OWDBPosition:
	if node is OWDBPosition:
		return node
	
	for child in node.get_children():
		var result = _find_position_node_recursive(child)
		if result:
			return result
	
	return null

func _get_camera() -> Node3D:
	if Engine.is_editor_hint():
		var viewport = EditorInterface.get_editor_viewport_3d(0)
		if viewport:
			return viewport.get_camera_3d()
			
	if owdb.camera and owdb.camera is Node3D:
		return owdb.camera
	
	owdb.camera = NodeUtils.find_visible_camera(owdb.get_tree().root)
	return owdb.camera

func _update_chunks_from_position(position: Vector3):
	_ensure_always_loaded_chunk()
	last_camera_position = position
	
	var sizes = OpenWorldDatabase.Size.values()
	sizes.reverse()
	
	for size in sizes:
		if size == OpenWorldDatabase.Size.ALWAYS_LOADED or size >= owdb.chunk_sizes.size():
			continue
		_update_chunks_for_size(size, position)
	
	# Clean up any invalid operations after chunk updates
	owdb.batch_processor.cleanup_invalid_operations()
	
	if not batch_callback_registered:
		owdb.batch_processor.add_batch_complete_callback(_on_batch_complete)
		batch_callback_registered = true

func _update_camera_chunks():
	# First try to find OWDBPosition node - if it exists, don't do camera updates
	var position_node = _find_position_node()
	if position_node:
		return  # OWDBPosition node will handle updates
	
	# Fallback to camera-based tracking
	var camera = _get_camera()
	if not camera:
		return
	
	var current_pos = camera.global_position
	_update_chunks_from_position(current_pos)

func _on_batch_complete():
	for chunk_key in pending_chunk_operations:
		var size = int(chunk_key.x)
		var chunk_pos = Vector2i(chunk_key.y, chunk_key.z)
		var operation = pending_chunk_operations[chunk_key]
		
		if operation == "unload":
			if loaded_chunks.has(size):
				loaded_chunks[size].erase(chunk_pos)
		elif operation == "load":
			if not loaded_chunks.has(size):
				loaded_chunks[size] = {}
			loaded_chunks[size][chunk_pos] = true
	
	pending_chunk_operations.clear()
	
	if owdb.debug_enabled:
		print("Chunk states updated after batch completion")

func _update_chunks_for_size(size: OpenWorldDatabase.Size, camera_pos: Vector3):
	var chunk_size = owdb.chunk_sizes[size]
	var center_chunk = Vector2i(
		int(camera_pos.x / chunk_size),
		int(camera_pos.z / chunk_size)
	)
	
	var new_required_chunks = _calculate_required_chunks(center_chunk)
	var prev_required_chunks = previous_required_chunks[size]
	
	var chunks_to_unload = _get_chunks_to_unload(prev_required_chunks, new_required_chunks)
	var chunks_to_load = _get_chunks_to_load(prev_required_chunks, new_required_chunks)
	
	var additional_nodes_to_unload = _validate_nodes_in_chunks(size, chunks_to_unload, new_required_chunks)
	
	for chunk_pos in chunks_to_unload:
		_queue_chunk_operation(size, chunk_pos, "unload")
	
	_unload_additional_nodes(additional_nodes_to_unload)
	
	for chunk_pos in chunks_to_load:
		_queue_chunk_operation(size, chunk_pos, "load")
	
	previous_required_chunks[size] = new_required_chunks

func _calculate_required_chunks(center_chunk: Vector2i) -> Dictionary:
	var required_chunks = {}
	for x in range(-owdb.chunk_load_range, owdb.chunk_load_range + 1):
		for z in range(-owdb.chunk_load_range, owdb.chunk_load_range + 1):
			var chunk_pos = center_chunk + Vector2i(x, z)
			required_chunks[chunk_pos] = true
	return required_chunks

func _get_chunks_to_unload(prev_chunks: Dictionary, new_chunks: Dictionary) -> Array:
	var chunks_to_unload = []
	for chunk_pos in prev_chunks:
		if not new_chunks.has(chunk_pos):
			chunks_to_unload.append(chunk_pos)
	return chunks_to_unload

func _get_chunks_to_load(prev_chunks: Dictionary, new_chunks: Dictionary) -> Array:
	var chunks_to_load = []
	for chunk_pos in new_chunks:
		if not prev_chunks.has(chunk_pos):
			chunks_to_load.append(chunk_pos)
	return chunks_to_load

func _queue_chunk_operation(size: OpenWorldDatabase.Size, chunk_pos: Vector2i, operation: String):
	var chunk_key = Vector3(size, chunk_pos.x, chunk_pos.y)
	pending_chunk_operations[chunk_key] = operation
	
	if operation == "load":
		_load_chunk(size, chunk_pos)
	else:
		_unload_chunk(size, chunk_pos)

func _ensure_always_loaded_chunk():
	var always_loaded_chunk = OpenWorldDatabase.ALWAYS_LOADED_CHUNK_POS
	if not loaded_chunks[OpenWorldDatabase.Size.ALWAYS_LOADED].has(always_loaded_chunk):
		_load_chunk(OpenWorldDatabase.Size.ALWAYS_LOADED, always_loaded_chunk)
		loaded_chunks[OpenWorldDatabase.Size.ALWAYS_LOADED][always_loaded_chunk] = true
	
	previous_required_chunks[OpenWorldDatabase.Size.ALWAYS_LOADED][always_loaded_chunk] = true

func _validate_nodes_in_chunks(size_cat: OpenWorldDatabase.Size, chunks_to_check: Array, currently_loading_chunks: Dictionary) -> Array:
	var additional_nodes_to_unload = []
	
	for chunk_pos in chunks_to_check:
		if not owdb.chunk_lookup.has(size_cat) or not owdb.chunk_lookup[size_cat].has(chunk_pos):
			continue
			
		var node_uids = owdb.chunk_lookup[size_cat][chunk_pos].duplicate()
		
		for uid in node_uids:
			var node = owdb.loaded_nodes_by_uid.get(uid)
			if not node:
				continue
			
			owdb.node_handler.handle_node_rename(node)
			owdb.node_monitor.update_stored_node(node)
			
			var node_size = NodeUtils.calculate_node_size(node)
			var current_size_cat = owdb.get_size_category(node_size)
			var node_position = node.global_position if node is Node3D else Vector3.ZERO
			var current_chunk = Vector2i(int(node_position.x / owdb.chunk_sizes[current_size_cat]), int(node_position.z / owdb.chunk_sizes[current_size_cat])) if current_size_cat != OpenWorldDatabase.Size.ALWAYS_LOADED else OpenWorldDatabase.ALWAYS_LOADED_CHUNK_POS
			
			if current_size_cat != size_cat or current_chunk != chunk_pos:
				owdb.chunk_lookup[size_cat][chunk_pos].erase(uid)
				if owdb.chunk_lookup[size_cat][chunk_pos].is_empty():
					owdb.chunk_lookup[size_cat].erase(chunk_pos)
				
				var new_chunk_will_be_loaded = _is_chunk_loaded_or_loading(current_size_cat, current_chunk, currently_loading_chunks)
				
				if new_chunk_will_be_loaded:
					NodeUtils.move_node_hierarchy_to_chunks(node, owdb)
				else:
					additional_nodes_to_unload.append(node)
	
	return additional_nodes_to_unload

func _is_chunk_loaded_or_loading(size_cat: OpenWorldDatabase.Size, chunk_pos: Vector2i, currently_loading_chunks: Dictionary) -> bool:
	if size_cat == OpenWorldDatabase.Size.ALWAYS_LOADED:
		return true
	if currently_loading_chunks.has(chunk_pos):
		return true
	if loaded_chunks.has(size_cat) and loaded_chunks[size_cat].has(chunk_pos):
		return true
	if previous_required_chunks.has(size_cat) and previous_required_chunks[size_cat].has(chunk_pos):
		return true
	
	var chunk_key = Vector3(size_cat, chunk_pos.x, chunk_pos.y)
	if pending_chunk_operations.has(chunk_key):
		return pending_chunk_operations[chunk_key] == "load"
	
	return false

func _unload_additional_nodes(nodes_to_unload: Array):
	if nodes_to_unload.is_empty():
		return
	
	var all_nodes_to_unload = []
	for node in nodes_to_unload:
		if is_instance_valid(node):
			NodeUtils.collect_node_hierarchy(node, all_nodes_to_unload)
	
	owdb.is_loading = true
	
	for node in all_nodes_to_unload:
		if is_instance_valid(node):
			var uid = NodeUtils.get_valid_node_uid(node)
			if uid != "":
				owdb.nodes_being_unloaded[uid] = true
				owdb.loaded_nodes_by_uid.erase(uid)
				owdb.node_monitor.update_stored_node(node)
	
	for node in nodes_to_unload:
		if is_instance_valid(node):
			node.free()
	
	owdb.is_loading = false

func _load_chunk(size: OpenWorldDatabase.Size, chunk_pos: Vector2i):
	if not owdb.chunk_lookup.has(size) or not owdb.chunk_lookup[size].has(chunk_pos):
		return
	
	var node_uids = owdb.chunk_lookup[size][chunk_pos].duplicate()
	for uid in node_uids:
		owdb.batch_processor.load_node(uid)

func _unload_chunk(size: OpenWorldDatabase.Size, chunk_pos: Vector2i):
	if size == OpenWorldDatabase.Size.ALWAYS_LOADED:
		return
		
	if not owdb.chunk_lookup.has(size) or not owdb.chunk_lookup[size].has(chunk_pos):
		return
	
	var uids_to_unload = owdb.chunk_lookup[size][chunk_pos].duplicate()
	for uid in uids_to_unload:
		owdb.batch_processor.unload_node(uid)
