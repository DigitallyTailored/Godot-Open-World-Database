#chunk_manager.gd
@tool
extends RefCounted
class_name ChunkManager

var owdb: OpenWorldDatabase
var loaded_chunks: Dictionary = {}
var last_camera_position: Vector3

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database
	reset()

func reset():
	for size in OpenWorldDatabase.Size.values():
		loaded_chunks[size] = {}

func is_chunk_loaded(size_cat: OpenWorldDatabase.Size, chunk_pos: Vector2i) -> bool:
	if size_cat == OpenWorldDatabase.Size.ALWAYS_LOADED:
		return true
	return loaded_chunks.has(size_cat) and loaded_chunks[size_cat].has(chunk_pos)

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
	
	if last_camera_position.distance_to(current_pos) < owdb.chunk_sizes[OpenWorldDatabase.Size.SMALL] * 0.1:
		return
	
	last_camera_position = current_pos
	
	var sizes = OpenWorldDatabase.Size.values()
	sizes.reverse()
	
	for size in sizes:
		if size == OpenWorldDatabase.Size.ALWAYS_LOADED:
			continue
			
		if size >= owdb.chunk_sizes.size():
			continue
		
		_update_chunks_for_size(size, current_pos)

func _update_chunks_for_size(size: OpenWorldDatabase.Size, camera_pos: Vector3):
	var chunk_size = owdb.chunk_sizes[size]
	var center_chunk = Vector2i(
		int(camera_pos.x / chunk_size),
		int(camera_pos.z / chunk_size)
	)
	
	var new_chunks = {}
	for x in range(-owdb.chunk_load_range, owdb.chunk_load_range + 1):
		for z in range(-owdb.chunk_load_range, owdb.chunk_load_range + 1):
			var chunk_pos = center_chunk + Vector2i(x, z)
			new_chunks[chunk_pos] = true
	
	var chunks_to_unload = []
	var loaded_chunks_size = loaded_chunks[size]
	for chunk_pos in loaded_chunks_size:
		if not new_chunks.has(chunk_pos):
			chunks_to_unload.append(chunk_pos)
	
	var additional_nodes_to_unload = _validate_nodes_in_chunks(size, chunks_to_unload, new_chunks)
	
	# Unload chunks (prevent chunk replacement by validating before unloading)
	#if !owdb.is_loading and chunks_to_unload.size() < loaded_chunks_size.size() / 2:  # Safety check
	#	print("WARNING: Unloading more than half the loaded chunks quantity - did you just teleport?? ", size)
	for chunk_pos in chunks_to_unload:
		_unload_chunk(size, chunk_pos)
	_unload_additional_nodes(additional_nodes_to_unload)
	
	# Load new chunks
	for chunk_pos in new_chunks:
		if not loaded_chunks_size.has(chunk_pos):
			_load_chunk(size, chunk_pos)
	
	loaded_chunks[size] = new_chunks

func _ensure_always_loaded_chunk():
	var always_loaded_chunk = Vector2i(0, 0)
	if not loaded_chunks[OpenWorldDatabase.Size.ALWAYS_LOADED].has(always_loaded_chunk):
		_load_chunk(OpenWorldDatabase.Size.ALWAYS_LOADED, always_loaded_chunk)
		loaded_chunks[OpenWorldDatabase.Size.ALWAYS_LOADED][always_loaded_chunk] = true

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
	
	for node in all_nodes_to_unload:
		if is_instance_valid(node):
			owdb.handle_node_rename(node)
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
	
	owdb.is_loading = true
	
	var node_infos = owdb.node_monitor.get_nodes_for_chunk(size, chunk_pos)
	
	for info in node_infos:
		_load_node(info)
	
	owdb.is_loading = false

func _load_node(node_info: Dictionary):
	var instance: Node
	
	if node_info.scene.begins_with("res://"):
		var scene = load(node_info.scene)
		instance = scene.instantiate()
	else:
		instance = ClassDB.instantiate(node_info.scene)
		if not instance:
			print("Failed to create node of type: ", node_info.scene)
			return
	
	instance.set_meta("_owd_uid", node_info.uid)
	instance.name = node_info.uid
	
	var parent_node = null
	if node_info.parent_uid != "":
		parent_node = owdb.get_node_by_uid(node_info.parent_uid)
	
	for prop_name in node_info.properties:
		if prop_name not in ["position", "rotation", "scale", "size"]:
			if instance.has_method("set") and prop_name in instance:
				var stored_value = node_info.properties[prop_name]
				var current_value = instance.get(prop_name)
				var converted_value = NodeUtils.convert_property_value(stored_value, current_value)
				instance.set(prop_name, converted_value)
	
	if parent_node:
		parent_node.add_child(instance)
		owdb._on_child_entered_tree(instance)
	else:
		owdb.add_child(instance)
	
	instance.owner = owdb.get_tree().get_edited_scene_root()
	
	if instance is Node3D:
		instance.global_position = node_info.position
		instance.global_rotation = node_info.rotation
		instance.scale = node_info.scale

func _unload_chunk(size: OpenWorldDatabase.Size, chunk_pos: Vector2i):
	if size == OpenWorldDatabase.Size.ALWAYS_LOADED:
		return
		
	if not owdb.chunk_lookup.has(size) or not owdb.chunk_lookup[size].has(chunk_pos):
		return
	
	var uids_to_unload = owdb.chunk_lookup[size][chunk_pos].duplicate()
	var nodes_to_unload = []
	
	for uid in uids_to_unload:
		var node = owdb.get_node_by_uid(uid)
		if node:
			nodes_to_unload.append(node)
	
	var all_nodes_to_unload = []
	for node in nodes_to_unload:
		_collect_node_hierarchy(node, all_nodes_to_unload)
	
	owdb.is_loading = true
	
	for node in all_nodes_to_unload:
		if is_instance_valid(node):
			owdb.handle_node_rename(node)
			owdb.node_monitor.update_stored_node(node)
	
	for node in nodes_to_unload:
		if is_instance_valid(node):
			if owdb.debug_enabled:
				print("NODE REMOVED: ", node.name, " - ", owdb.get_total_database_nodes(), " total nodes")
			node.free()
	
	owdb.is_loading = false
