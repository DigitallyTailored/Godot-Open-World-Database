@tool
extends Node3D
class_name OWDBPosition

var last_position: Vector3 = Vector3.INF
var owdb: OpenWorldDatabase
var position_id: String = ""

const UPDATE_THRESHOLD_SQUARED: float = 1.0

func _ready():
	_find_owdb()
	if owdb:
		position_id = owdb.chunk_manager.register_position(self)
		call_deferred("force_update")

func _exit_tree():
	if owdb and position_id != "":
		owdb.chunk_manager.unregister_position(position_id)

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

func _process(_delta):
	if not owdb or owdb.is_loading or position_id == "":
		return
	
	var current_pos = global_position
	var distance_squared = last_position.distance_squared_to(current_pos)
	
	if distance_squared >= UPDATE_THRESHOLD_SQUARED:
		owdb.chunk_manager.update_position_chunks(position_id, current_pos)
		last_position = current_pos

func force_update():
	if owdb and not owdb.is_loading and position_id != "":
		var current_pos = global_position
		owdb.chunk_manager.update_position_chunks(position_id, current_pos)
		last_position = current_pos

func get_position_id() -> String:
	return position_id
