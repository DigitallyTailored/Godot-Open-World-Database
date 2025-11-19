# src/OWDBPosition.gd
@tool
extends Node3D
class_name OWDBPosition

var last_position: Vector3 = Vector3.INF
var owdb: OpenWorldDatabase
var position_id: String = ""
var _cached_peer_id: int = -1
var sync_node: OWDBSync = null

func _ready():
	owdb = _find_owdb()
	if owdb:
		position_id = owdb.chunk_manager.register_position(self)
		call_deferred("force_update")
	
	_update_peer_registration()

func _exit_tree():
	if owdb and position_id != "":
		owdb.chunk_manager.unregister_position(position_id)
	
	_unregister_from_syncer()

func get_peer_id() -> int:
	if not Engine.is_editor_hint():
		var sync_node = _find_sync_node()
		if sync_node:
			return sync_node.peer_id
		
	return 1

func _find_sync_node():
	if sync_node and is_instance_valid(sync_node):
		return sync_node
	
	var parent = get_parent()
	if parent:
		for sibling in parent.get_children():
			if sibling is OWDBSync:
				sync_node = sibling
				return sync_node
	
	for child in get_children():
		if child is OWDBSync:
			sync_node = child
			return sync_node
	
	sync_node = null
	return null

func _update_peer_registration():
	var current_peer_id = get_peer_id()
	
	if current_peer_id != _cached_peer_id:
		if _cached_peer_id != -1:
			_unregister_from_syncer(_cached_peer_id)
		
		_register_with_syncer(current_peer_id)
		_cached_peer_id = current_peer_id

func _register_with_syncer(peer_id: int):
	if owdb and owdb.syncer:
		owdb.syncer.register_peer_position(peer_id, self)

func _unregister_from_syncer(peer_id: int = -1):
	if owdb and owdb.syncer:
		var id_to_unregister = peer_id if peer_id != -1 else _cached_peer_id
		owdb.syncer.unregister_peer_position(id_to_unregister)

func _process(_delta):
	if not owdb or owdb.is_loading or position_id == "":
		return
	
	_update_peer_registration()
	
	var current_pos = global_position
	var distance_squared = last_position.distance_squared_to(current_pos)
	
	if distance_squared >= 1.0:
		owdb.chunk_manager.update_position_chunks(position_id, current_pos)
		last_position = current_pos

func _find_owdb() -> OpenWorldDatabase:
	var root = get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
	return root.find_children("*", "OpenWorldDatabase", true, false)[0]

func force_update():
	if owdb and not owdb.is_loading and position_id != "":
		var current_pos = global_position
		owdb.chunk_manager.update_position_chunks(position_id, current_pos)
		last_position = current_pos

func get_position_id() -> String:
	return position_id

func refresh_peer_registration():
	_cached_peer_id = -1
	sync_node = null
	_update_peer_registration()
