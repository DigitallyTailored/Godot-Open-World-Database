@tool
extends RefCounted
class_name ChunkManager

var owdb: OpenWorldDatabase
var loaded_chunks: Dictionary = {}
var previous_required_chunks: Dictionary = {} # Track what chunks should have been loaded in previous frame
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
	
	var chunk_key = _get_chunk_key(size_cat, chunk_pos)
	
	# Check if there's a pending operation that would affect this
	if pending_chunk_operations.has(chunk_key):
		var pending_op = pending_chunk_operations[chunk_key]
		return pending_op == "load"
	
	return loaded_chunks.has(size_cat) and loaded_chunks[size_cat].has(chunk_pos)

func _get_chunk_key(size_cat: OpenWorldDatabase.Size, chunk_pos: Vector2i) -> Vector3:
	return Vector3(size_cat, chunk_pos.x, chunk_pos.y)

func _get_camera() -> Node3D:
	if Engine.is_editor_hint():
		var viewport = EditorInterface.get_editor_viewport_3d(0)
		if viewport:
			return viewport.get_camera_3d()
			
	if owdb.camera and owdb.camera is Node3D:
		return owdb.camera
	
	owdb.camera = _find_visible_camera3d(owdb.get_tree().root)
	return owdb.camera
	
func _find_visible_camera3d(node: Node) -> Camera3D:
	if node is Camera3D and node.visible:
		return node
	
	for child in node.get_children():
		var found = _find_visible_camera3d(child)
		if found:
			return found
	return null

func _update_camera_chunks():
	var camera = _get_camera()
	if not camera:
		return
	
	var current_pos = camera.global_position
	
	_ensure_always_loaded_chunk()
	
	# Remove the early return - we want to process chunks even for small movements
	# to ensure proper tracking of required chunks
	last_camera_position = current_pos
	
	var sizes = OpenWorldDatabase.Size.values()
	sizes.reverse()
	
	for size in sizes:
		if size == OpenWorldDatabase.Size.ALWAYS_LOADED:
			continue
			
		if size >= owdb.chunk_sizes.size():
			continue
		
		_update_chunks_for_size(size, current_pos)
	
	# Register callback to update chunk states when batch processing completes
	if not batch_callback_registered:
		owdb.batch_processor.add_batch_complete_callback(_on_batch_complete)
		batch_callback_registered = true

func _on_batch_complete():
	# Update actual chunk states after operations complete
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
	
	# Calculate what chunks should be loaded now
	var new_required_chunks = {}
	for x in range(-owdb.chunk_load_range, owdb.chunk_load_range + 1):
		for z in range(-owdb.chunk_load_range, owdb.chunk_load_range + 1):
			var chunk_pos = center_chunk + Vector2i(x, z)
			new_required_chunks[chunk_pos] = true
	
	# Get the previous set of required chunks (what should have been loaded before)
	var prev_required_chunks = previous_required_chunks[size]
	
	# Determine chunks to unload: were required before but not required now
	var chunks_to_unload = []
	for chunk_pos in prev_required_chunks:
		if not new_required_chunks.has(chunk_pos):
			chunks_to_unload.append(chunk_pos)
	
	# Determine chunks to load: required now but weren't required before
	var chunks_to_load = []
	for chunk_pos in new_required_chunks:
		if not prev_required_chunks.has(chunk_pos):
			chunks_to_load.append(chunk_pos)
	
	# Validate nodes in chunks that are being unloaded
	var additional_nodes_to_unload = _validate_nodes_in_chunks(size, chunks_to_unload, new_required_chunks)
	
	# Queue chunk operations (don't update loaded_chunks immediately)
	for chunk_pos in chunks_to_unload:
		_queue_unload_chunk(size, chunk_pos)
	_unload_additional_nodes(additional_nodes_to_unload)
	
	# Load new chunks that are now needed
	for chunk_pos in chunks_to_load:
		_queue_load_chunk(size, chunk_pos)
	
	# Update the previous required chunks for next frame
	previous_required_chunks[size] = new_required_chunks

func _queue_load_chunk(size: OpenWorldDatabase.Size, chunk_pos: Vector2i):
	var chunk_key = _get_chunk_key(size, chunk_pos)
	pending_chunk_operations[chunk_key] = "load"
	_load_chunk(size, chunk_pos)

func _queue_unload_chunk(size: OpenWorldDatabase.Size, chunk_pos: Vector2i):
	var chunk_key = _get_chunk_key(size, chunk_pos)
	pending_chunk_operations[chunk_key] = "unload"
	_unload_chunk(size, chunk_pos)

func _ensure_always_loaded_chunk():
	var always_loaded_chunk = Vector2i(0, 0)
	if not loaded_chunks[OpenWorldDatabase.Size.ALWAYS_LOADED].has(always_loaded_chunk):
		_load_chunk(OpenWorldDatabase.Size.ALWAYS_LOADED, always_loaded_chunk)
		loaded_chunks[OpenWorldDatabase.Size.ALWAYS_LOADED][always_loaded_chunk] = true
	
	# Also ensure it's in the previous required chunks
	previous_required_chunks[OpenWorldDatabase.Size.ALWAYS_LOADED][always_loaded_chunk] = true

func _validate_nodes_in_chunks(size_cat: OpenWorldDatabase.Size, chunks_to_check: Array, currently_loading_chunks: Dictionary) -> Array:
	var additional_nodes_to_unload = []
	
	for chunk_pos in chunks_to_check:
		if not owdb.chunk_lookup.has(size_cat) or not owdb.chunk_lookup[size_cat].has(chunk_pos):
			continue
			
		var node_uids = owdb.chunk_lookup[size_cat][chunk_pos].duplicate()
		
		for uid in node_uids:
			var node = owdb.get_node_by_uid(uid)
			if not node:
				continue
			
			owdb.handle_node_rename(node)
			owdb.node_monitor.update_stored_node(node)
			
			var node_size = NodeUtils.calculate_node_size(node)
			var current_size_cat = owdb.get_size_category(node_size)
			var node_position = node.global_position if node is Node3D else Vector3.ZERO
			var current_chunk = owdb.get_chunk_position(node_position, current_size_cat)
			
			if current_size_cat != size_cat or current_chunk != chunk_pos:
				owdb.chunk_lookup[size_cat][chunk_pos].erase(uid)
				if owdb.chunk_lookup[size_cat][chunk_pos].is_empty():
					owdb.chunk_lookup[size_cat].erase(chunk_pos)
				
				var new_chunk_will_be_loaded = _is_chunk_loaded_or_loading(current_size_cat, current_chunk, currently_loading_chunks)
				
				if new_chunk_will_be_loaded:
					_move_node_hierarchy_to_chunks(node)
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
	# Also check if it will be required in the new frame
	if previous_required_chunks.has(size_cat) and previous_required_chunks[size_cat].has(chunk_pos):
		return true
	
	# Check pending operations
	var chunk_key = _get_chunk_key(size_cat, chunk_pos)
	if pending_chunk_operations.has(chunk_key):
		return pending_chunk_operations[chunk_key] == "load"
	
	return false

func _move_node_hierarchy_to_chunks(node: Node):
	if node.has_meta("_owd_uid"):
		var uid = node.get_meta("_owd_uid")
		var node_size = NodeUtils.calculate_node_size(node)
		var node_position = node.global_position if node is Node3D else Vector3.ZERO
		
		owdb.node_monitor.update_stored_node(node)
		owdb.add_to_chunk_lookup(uid, node_position, node_size)
	
	for child in node.get_children():
		if child.has_meta("_owd_uid"):
			_move_node_hierarchy_to_chunks(child)

func _unload_additional_nodes(nodes_to_unload: Array):
	if nodes_to_unload.is_empty():
		return
	
	var all_nodes_to_unload = []
	for node in nodes_to_unload:
		if is_instance_valid(node):
			_collect_node_hierarchy(node, all_nodes_to_unload)
	
	owdb.is_loading = true
	
	# Mark all nodes as being legitimately unloaded
	for node in all_nodes_to_unload:
		if is_instance_valid(node) and node.has_meta("_owd_uid"):
			var uid = node.get_meta("_owd_uid")
			owdb.nodes_being_unloaded[uid] = true
			owdb.node_monitor.update_stored_node(node)
	
	for node in nodes_to_unload:
		if is_instance_valid(node):
			node.free()
	
	owdb.is_loading = false

func _collect_node_hierarchy(node: Node, collection: Array):
	if node.has_meta("_owd_uid"):
		collection.append(node)
	
	for child in node.get_children():
		if child.has_meta("_owd_uid"):
			_collect_node_hierarchy(child, collection)

func _load_chunk(size: OpenWorldDatabase.Size, chunk_pos: Vector2i):
	if not owdb.chunk_lookup.has(size) or not owdb.chunk_lookup[size].has(chunk_pos):
		return
	
	var node_uids = owdb.chunk_lookup[size][chunk_pos].duplicate()
	
	for uid in node_uids:
		owdb.load_node(uid)  # Use batched loading

func _unload_chunk(size: OpenWorldDatabase.Size, chunk_pos: Vector2i):
	if size == OpenWorldDatabase.Size.ALWAYS_LOADED:
		return
		
	if not owdb.chunk_lookup.has(size) or not owdb.chunk_lookup[size].has(chunk_pos):
		return
	
	var uids_to_unload = owdb.chunk_lookup[size][chunk_pos].duplicate()
	
	for uid in uids_to_unload:
		owdb.unload_node(uid)  # Use batched unloading
