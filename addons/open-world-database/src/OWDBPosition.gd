# src/OWDBPosition.gd
@tool
extends Node3D
class_name OWDBPosition

var last_position: Vector3 = Vector3.INF
var owdb: OpenWorldDatabase
var position_id: String = ""
var _cached_peer_id: int = -1  # Cache to detect changes
var _sync_node: OWDBSync = null  # Cache the sync node reference

func _ready():
	_find_owdb()
	if owdb:
		position_id = owdb.chunk_manager.register_position(self)
		call_deferred("force_update")
	
	# Initial registration with current peer_id
	_update_peer_registration()

func _exit_tree():
	if owdb and position_id != "":
		owdb.chunk_manager.unregister_position(position_id)
	
	# Unregister from Syncer
	_unregister_from_syncer()

func get_peer_id() -> int:
	if not Engine.is_editor_hint():
		# Look for OWDBSync node (check siblings first, then children as fallback)
		var sync_node = _find_sync_node()
		if sync_node:
			return sync_node.peer_id
		
	# Default to server/host if no OWDBSync node
	return 1

func _find_sync_node():
	# Check if we have a cached reference that's still valid
	if _sync_node and is_instance_valid(_sync_node):
		return _sync_node
	
	# Look for OWDBSync node as sibling first
	var parent = get_parent()
	if parent:
		for sibling in parent.get_children():
			if sibling is OWDBSync:
				_sync_node = sibling
				return _sync_node
	
	# Fallback: look for OWDBSync node as child
	for child in get_children():
		if child is OWDBSync:
			_sync_node = child
			return _sync_node
	
	# Clear cache if no OWDBSync node found
	_sync_node = null
	return null

func _update_peer_registration():
	var current_peer_id = get_peer_id()
	
	# Only update if peer_id has actually changed
	if current_peer_id != _cached_peer_id:
		# Unregister old peer_id if it was registered
		if _cached_peer_id != -1:
			_unregister_from_syncer(_cached_peer_id)
		
		# Register new peer_id
		_register_with_syncer(current_peer_id)
		_cached_peer_id = current_peer_id

func _register_with_syncer(peer_id: int):
	Syncer.register_peer_position(peer_id, self)

func _unregister_from_syncer(peer_id: int = -1):
	var id_to_unregister = peer_id if peer_id != -1 else _cached_peer_id
	Syncer.unregister_peer_position(id_to_unregister)

func _process(_delta):
	if not owdb or owdb.is_loading or position_id == "":
		return
	
	# Check for peer_id changes each frame (lightweight check with caching)
	_update_peer_registration()
	
	var current_pos = global_position
	var distance_squared = last_position.distance_squared_to(current_pos)
	
	if distance_squared >= 1.0:
		owdb.chunk_manager.update_position_chunks(position_id, current_pos)
		last_position = current_pos

func _find_owdb():
	# Search up the tree for OWDB
	var current = get_parent()
	while current != null:
		if current is OpenWorldDatabase:
			owdb = current
			return
		current = current.get_parent()
	
	# Search the entire tree as fallback
	var root = get_tree().root
	owdb = _find_owdb_recursive(root)

func _find_owdb_recursive(node: Node) -> OpenWorldDatabase:
	if node is OpenWorldDatabase:
		return node
	
	for child in node.get_children():
		var result = _find_owdb_recursive(child)
		if result:
			return result
	
	return null

func force_update():
	if owdb and not owdb.is_loading and position_id != "":
		var current_pos = global_position
		owdb.chunk_manager.update_position_chunks(position_id, current_pos)
		last_position = current_pos

func get_position_id() -> String:
	return position_id

# Public method to force a peer registration update (useful when OWDBSync nodes are added dynamically)
func refresh_peer_registration():
	_cached_peer_id = -1  # Force update
	_sync_node = null    # Clear cache
	_update_peer_registration()
