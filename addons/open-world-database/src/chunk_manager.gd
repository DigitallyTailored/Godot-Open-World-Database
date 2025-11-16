@tool
extends RefCounted
class_name ChunkManager

var owdb: OpenWorldDatabase
var loaded_chunks: Dictionary = {}
var chunk_requirements: Dictionary = {} # chunk_key -> Set of position_ids that need this chunk
var position_registry: Dictionary = {} # position_id -> OWDBPosition node
var position_required_chunks: Dictionary = {} # position_id -> Dictionary of required chunks
var pending_chunk_operations: Dictionary = {} # chunk_key -> "load"/"unload"
var batch_callback_registered: bool = false

# Network integration
var _syncer_notified_entities: Dictionary = {} # entity_name -> true (track what we've told Syncer about)
var _autonomous_chunk_management: bool = true
var _current_network_mode: OpenWorldDatabase.NetworkMode = OpenWorldDatabase.NetworkMode.HOST

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database
	reset()

func reset():
	for size in OpenWorldDatabase.Size.values():
		loaded_chunks[size] = {}
	chunk_requirements.clear()
	position_registry.clear()
	position_required_chunks.clear()
	pending_chunk_operations.clear()
	_syncer_notified_entities.clear()
	_autonomous_chunk_management = true
	batch_callback_registered = false

func set_network_mode(mode: OpenWorldDatabase.NetworkMode):
	_current_network_mode = mode
	owdb.debug("ChunkManager: Network mode set to ", mode)

func clear_autonomous_chunk_management():
	_autonomous_chunk_management = false
	pending_chunk_operations.clear()
	owdb.debug("ChunkManager: Autonomous chunk management disabled (PEER mode)")

func enable_autonomous_chunk_management():
	_autonomous_chunk_management = true
	owdb.debug("ChunkManager: Autonomous chunk management enabled (HOST mode)")

func force_refresh_all_positions():
	for position_id in position_registry:
		var pos_node = position_registry[position_id]
		if pos_node and is_instance_valid(pos_node):
			update_position_chunks(position_id, pos_node.global_position)

func register_position(position_node: OWDBPosition) -> String:
	var position_id = str(position_node.get_instance_id())
	position_registry[position_id] = position_node
	position_required_chunks[position_id] = {}
	
	owdb.debug("ChunkManager: Registered OWDBPosition with ID: ", position_id)
	
	return position_id

func unregister_position(position_id: String):
	if not position_registry.has(position_id):
		return
	
	var old_required_chunks = position_required_chunks.get(position_id, {})
	for size in old_required_chunks:
		for chunk_pos in old_required_chunks[size]:
			_remove_chunk_requirement(size, chunk_pos, position_id)
	
	position_registry.erase(position_id)
	position_required_chunks.erase(position_id)
	
	owdb.debug("ChunkManager: Unregistered OWDBPosition with ID: ", position_id)

func is_chunk_loaded(size_cat: OpenWorldDatabase.Size, chunk_pos: Vector2i) -> bool:
	if size_cat == OpenWorldDatabase.Size.ALWAYS_LOADED:
		return true
	
	var chunk_key = NodeUtils.get_chunk_key(size_cat, chunk_pos)
	
	if pending_chunk_operations.has(chunk_key):
		return pending_chunk_operations[chunk_key] == "load"
	
	return loaded_chunks.has(size_cat) and loaded_chunks[size_cat].has(chunk_pos)

func update_position_chunks(position_id: String, position: Vector3):
	if not position_registry.has(position_id):
		return
	
	_ensure_always_loaded_chunk()
	
	var sizes = OpenWorldDatabase.Size.values()
	sizes.reverse()
	
	var new_required_chunks = {}
	for size in sizes:
		if size == OpenWorldDatabase.Size.ALWAYS_LOADED or size >= owdb._chunk_sizes.size():
			new_required_chunks[size] = {OpenWorldDatabase.ALWAYS_LOADED_CHUNK_POS: true}
			continue
		new_required_chunks[size] = _calculate_required_chunks_for_size(size, position)
	
	var old_required_chunks = position_required_chunks.get(position_id, {})
	var chunks_changed = false
	
	for size in sizes:
		var old_chunks = old_required_chunks.get(size, {})
		var new_chunks = new_required_chunks.get(size, {})
		
		for chunk_pos in old_chunks:
			if not new_chunks.has(chunk_pos):
				_remove_chunk_requirement(size, chunk_pos, position_id)
				chunks_changed = true
		
		for chunk_pos in new_chunks:
			if not old_chunks.has(chunk_pos):
				_add_chunk_requirement(size, chunk_pos, position_id)
				chunks_changed = true
	
	position_required_chunks[position_id] = new_required_chunks
	
	if _current_network_mode == OpenWorldDatabase.NetworkMode.HOST and chunks_changed:
		var peer_id = _get_peer_id_for_position(position_id)
		if peer_id != -1:
			call_deferred("_trigger_peer_visibility_update", peer_id)
	
	if _autonomous_chunk_management:
		owdb.batch_processor.cleanup_invalid_operations()
		
		if not batch_callback_registered:
			owdb.batch_processor.add_batch_complete_callback(_on_batch_complete)
			batch_callback_registered = true

func _calculate_required_chunks_for_size(size: OpenWorldDatabase.Size, position: Vector3) -> Dictionary:
	var chunk_size = owdb._chunk_sizes[size]
	var center_chunk = NodeUtils.get_chunk_position(position, chunk_size)
	
	var required_chunks = {}
	for x in range(-owdb._chunk_load_range, owdb._chunk_load_range + 1):
		for z in range(-owdb._chunk_load_range, owdb._chunk_load_range + 1):
			var chunk_pos = center_chunk + Vector2i(x, z)
			required_chunks[chunk_pos] = true
	
	return required_chunks

func _add_chunk_requirement(size: OpenWorldDatabase.Size, chunk_pos: Vector2i, position_id: String):
	var chunk_key = NodeUtils.get_chunk_key(size, chunk_pos)
	
	if not chunk_requirements.has(chunk_key):
		chunk_requirements[chunk_key] = {}
		if _autonomous_chunk_management:
			_queue_chunk_operation(size, chunk_pos, "load")
	
	chunk_requirements[chunk_key][position_id] = true

func _remove_chunk_requirement(size: OpenWorldDatabase.Size, chunk_pos: Vector2i, position_id: String):
	var chunk_key = NodeUtils.get_chunk_key(size, chunk_pos)
	
	if not chunk_requirements.has(chunk_key):
		return
	
	chunk_requirements[chunk_key].erase(position_id)
	
	if chunk_requirements[chunk_key].is_empty():
		chunk_requirements.erase(chunk_key)
		if size != OpenWorldDatabase.Size.ALWAYS_LOADED and _autonomous_chunk_management:
			_queue_chunk_operation(size, chunk_pos, "unload")

func _on_batch_complete():
	var newly_loaded_entities = []
	var newly_unloaded_entities = []
	
	for chunk_key in pending_chunk_operations:
		var size = int(chunk_key.x)
		var chunk_pos = Vector2i(chunk_key.y, chunk_key.z)
		var operation = pending_chunk_operations[chunk_key]
		
		if operation == "unload":
			if owdb.chunk_lookup.has(size) and owdb.chunk_lookup[size].has(chunk_pos):
				for uid in owdb.chunk_lookup[size][chunk_pos]:
					if owdb.loaded_nodes_by_uid.has(uid):
						var node = owdb.loaded_nodes_by_uid[uid]
						if node.has_node("Sync"):
							newly_unloaded_entities.append(node.name)
			
			if loaded_chunks.has(size):
				loaded_chunks[size].erase(chunk_pos)
				
		elif operation == "load":
			if owdb.chunk_lookup.has(size) and owdb.chunk_lookup[size].has(chunk_pos):
				for uid in owdb.chunk_lookup[size][chunk_pos]:
					if owdb.node_monitor.stored_nodes.has(uid):
						newly_loaded_entities.append(uid)
			
			if not loaded_chunks.has(size):
				loaded_chunks[size] = {}
			loaded_chunks[size][chunk_pos] = true
	
	pending_chunk_operations.clear()
	
	if _current_network_mode == OpenWorldDatabase.NetworkMode.HOST and _is_syncer_available():
		_notify_syncer_of_changes(newly_loaded_entities, newly_unloaded_entities)
	
	owdb.debug("Chunk states updated after batch completion")

func _is_syncer_available() -> bool:
	if Engine.is_editor_hint():
		return false
	
	return Syncer != null and not (Syncer.has_method("is_placeholder") and Syncer.is_placeholder())

func _notify_syncer_of_changes(loaded_entities: Array, unloaded_entities: Array):
	if not _is_syncer_available():
		owdb.debug("Syncer not available - skipping notification")
		return
	
	owdb.debug(owdb.multiplayer.get_unique_id(), ": Notifying Syncer of chunk changes - loaded: ", loaded_entities.size(), " unloaded: ", unloaded_entities.size())
	
	for uid in loaded_entities:
		if owdb.loaded_nodes_by_uid.has(uid):
			var node = owdb.loaded_nodes_by_uid[uid]
			if node and node is Node3D:
				var entity_name = node.name
				var sync_component = node.find_child("Sync") if node.has_node("Sync") else null
				
				# Get OWDB properties for this entity
				var owdb_properties = {}
				if owdb.node_monitor.stored_nodes.has(uid):
					var node_info = owdb.node_monitor.stored_nodes[uid]
					owdb_properties = node_info.properties.duplicate()
				
				if not Syncer.is_node_registered(node):
					Syncer.register_node(node, node.scene_file_path, 1, owdb_properties, sync_component)
				
				_syncer_notified_entities[entity_name] = true
				owdb.debug(owdb.multiplayer.get_unique_id(), ": Notified Syncer about loaded entity: ", entity_name)
	
	for entity_name in unloaded_entities:
		if _syncer_notified_entities.has(entity_name):
			Syncer.entity_all_visible(entity_name, false)
			_syncer_notified_entities.erase(entity_name)
			owdb.debug(owdb.multiplayer.get_unique_id(), ": Hiding unloaded entity: ", entity_name)
	
	Syncer._update_entity_visibility_from_owdb()

func _get_peer_id_for_position(position_id: String) -> int:
	var owdb_position = position_registry.get(position_id)
	if owdb_position and is_instance_valid(owdb_position):
		return owdb_position.get_peer_id()
	return -1

func _trigger_peer_visibility_update(peer_id: int):
	if not _is_syncer_available():
		return
	
	Syncer._update_single_peer_visibility(peer_id)
	owdb.debug("Triggered visibility update for peer: ", peer_id)

func _queue_chunk_operation(size: OpenWorldDatabase.Size, chunk_pos: Vector2i, operation: String):
	var chunk_key = NodeUtils.get_chunk_key(size, chunk_pos)
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

func get_active_position_count() -> int:
	return position_registry.size()

func get_chunk_requirement_info() -> Dictionary:
	var total_chunks_required = chunk_requirements.size()
	var chunks_loaded = 0
	
	for size in loaded_chunks:
		chunks_loaded += loaded_chunks[size].size()
	
	return {
		"active_positions": position_registry.size(),
		"total_chunks_required": total_chunks_required,
		"chunks_loaded": chunks_loaded,
		"autonomous_management": _autonomous_chunk_management,
		"network_mode": _current_network_mode
	}
