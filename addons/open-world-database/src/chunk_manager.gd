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
	
	# Always ensure ALWAYS_LOADED chunk is loaded
	_ensure_always_loaded_chunk()
	
	if last_camera_position.distance_to(current_pos) < owdb.chunk_sizes[OpenWorldDatabase.Size.SMALL] * 0.1:
		return
	
	last_camera_position = current_pos
	
	# Process chunks from largest to smallest for proper hierarchy loading
	var sizes = OpenWorldDatabase.Size.values()
	sizes.reverse()
	
	for size in sizes:
		# Skip ALWAYS_LOADED as it's handled separately
		if size == OpenWorldDatabase.Size.ALWAYS_LOADED:
			continue
			
		if size >= owdb.chunk_sizes.size():
			continue
		
		var chunk_size = owdb.chunk_sizes[size]
		var center_chunk = Vector2i(
			int(current_pos.x / chunk_size),
			int(current_pos.z / chunk_size)
		)
		
		var new_chunks = {}
		for x in range(-owdb.chunk_load_range, owdb.chunk_load_range + 1):
			for z in range(-owdb.chunk_load_range, owdb.chunk_load_range + 1):
				var chunk_pos = center_chunk + Vector2i(x, z)
				new_chunks[chunk_pos] = true
		
		# Find chunks that are being unloaded
		var chunks_to_unload = []
		var loaded_chunks_size = loaded_chunks[size]
		for chunk_pos in loaded_chunks_size:
			if not new_chunks.has(chunk_pos):
				chunks_to_unload.append(chunk_pos)
		
		# Validate nodes and get additional nodes to unload
		var additional_nodes_to_unload = _validate_nodes_in_chunks(size, chunks_to_unload, new_chunks)
		
		# Unload chunks
		for chunk_pos in chunks_to_unload:
			_unload_chunk(size, chunk_pos)
		
		# Unload additional nodes that moved to non-loaded chunks
		_unload_additional_nodes(additional_nodes_to_unload)
		
		# Load chunks
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
	
	if chunks_to_check.is_empty():
		return additional_nodes_to_unload
		
	for chunk_pos in chunks_to_check:
		if not owdb.chunk_lookup.has(size_cat) or not owdb.chunk_lookup[size_cat].has(chunk_pos):
			continue
			
		var node_uids = owdb.chunk_lookup[size_cat][chunk_pos].duplicate()
		
		for uid in node_uids:
			var node = owdb.get_node_by_uid(uid)
			if not node:
				continue
			
			# Check for rename before updating stored node
			owdb.handle_node_rename(node)
			
			# Update node properties
			owdb.node_monitor.update_stored_node(node)
			
			# Check if node has moved or changed size
			var node_size = NodeUtils.calculate_node_size(node)
			var current_size_cat = owdb.get_size_category(node_size)
			var node_position = node.global_position if node is Node3D else Vector3.ZERO
			var current_chunk = owdb.get_chunk_position(node_position, current_size_cat)
			
			# If node has moved to a different chunk or changed size category
			if current_size_cat != size_cat or current_chunk != chunk_pos:
				# Remove from old location
				owdb.chunk_lookup[size_cat][chunk_pos].erase(uid)
				if owdb.chunk_lookup[size_cat][chunk_pos].is_empty():
					owdb.chunk_lookup[size_cat].erase(chunk_pos)
				
				# Check if new chunk will be loaded
				var new_chunk_will_be_loaded = _is_chunk_loaded_or_loading(current_size_cat, current_chunk, currently_loading_chunks)
				
				if new_chunk_will_be_loaded:
					# Move node and all children to new chunks
					_move_node_hierarchy_to_chunks(node)
				else:
					# New chunk is not loaded, mark node for unloading
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
	# Recursively move node and all children to appropriate chunks
	if node.has_meta("_owd_uid"):
		var uid = node.get_meta("_owd_uid")
		var node_size = NodeUtils.calculate_node_size(node)
		var node_position = node.global_position if node is Node3D else Vector3.ZERO
		
		# Update stored node info and add to new chunk
		owdb.node_monitor.update_stored_node(node)
		owdb.add_to_chunk_lookup(uid, node_position, node_size)
	
	# Process children
	for child in node.get_children():
		if child.has_meta("_owd_uid"):
			_move_node_hierarchy_to_chunks(child)

func _unload_additional_nodes(nodes_to_unload: Array):
	if nodes_to_unload.is_empty():
		return
	
	# Collect all nodes in hierarchies before freeing any
	var all_nodes_to_unload = []
	for node in nodes_to_unload:
		if is_instance_valid(node):
			_collect_node_hierarchy(node, all_nodes_to_unload)
	
	owdb.is_loading = true
	
	# Check for renames and update stored data for all nodes before freeing
	for node in all_nodes_to_unload:
		if is_instance_valid(node):
			owdb.handle_node_rename(node)
			owdb.node_monitor.update_stored_node(node)
	
	# Free the top-level nodes (children will be freed automatically)
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
	
	# Check if scene is a file path or node type
	if node_info.scene.begins_with("res://"):
		# Load from scene file
		#var scene = ResourceLoader.load(node_info.scene, "", ResourceLoader.CACHE_MODE_REUSE)
		var scene = load(node_info.scene)
		instance = scene.instantiate()
	else:
		# Create from node type
		instance = ClassDB.instantiate(node_info.scene)
		if not instance:
			print("Failed to create node of type: ", node_info.scene)
			return
	
	instance.set_meta("_owd_uid", node_info.uid)
	instance.name = node_info.uid
	
	# Find parent
	var parent_node = null
	if node_info.parent_uid != "":
		parent_node = owdb.get_node_by_uid(node_info.parent_uid)
	
	
	# Set properties before we instance so they can be used by the _ready function
	for prop_name in node_info.properties:
		if prop_name not in ["position", "rotation", "scale", "size"]:
			if instance.has_method("set") and prop_name in instance:
				var stored_value = node_info.properties[prop_name]
				var current_value = instance.get(prop_name)
				var converted_value = NodeUtils.convert_property_value(stored_value, current_value)
				instance.set(prop_name, converted_value)
				
	# Add to parent or owdb
	if parent_node:
		parent_node.add_child(instance)
		owdb._on_child_entered_tree(instance)
	else:
		owdb.add_child(instance)
	
	instance.owner = owdb.get_tree().get_edited_scene_root()
	
	# Set properties only if it's a Node3D
	if instance is Node3D:
		instance.global_position = node_info.position
		instance.global_rotation = node_info.rotation
		instance.scale = node_info.scale
	
	
func _unload_chunk(size: OpenWorldDatabase.Size, chunk_pos: Vector2i):
	# Never unload ALWAYS_LOADED chunks
	if size == OpenWorldDatabase.Size.ALWAYS_LOADED:
		return
		
	if not owdb.chunk_lookup.has(size) or not owdb.chunk_lookup[size].has(chunk_pos):
		return
	
	var uids_to_unload = owdb.chunk_lookup[size][chunk_pos].duplicate()
	var nodes_to_unload = []
	
	# Collect all nodes before updating/freeing any
	for uid in uids_to_unload:
		var node = owdb.get_node_by_uid(uid)
		if node:
			nodes_to_unload.append(node)
	
	# Collect all nodes in hierarchies
	var all_nodes_to_unload = []
	for node in nodes_to_unload:
		_collect_node_hierarchy(node, all_nodes_to_unload)
	
	owdb.is_loading = true
	
	# Check for renames and update stored data for all nodes before freeing
	for node in all_nodes_to_unload:
		if is_instance_valid(node):
			owdb.handle_node_rename(node)
			owdb.node_monitor.update_stored_node(node)
	
	# Free the top-level nodes
	for node in nodes_to_unload:
		if is_instance_valid(node):
			node.free()
	
	owdb.is_loading = false
