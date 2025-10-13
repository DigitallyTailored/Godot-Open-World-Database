@tool
extends Node3D
class_name OWDBPosition

@export var update_threshold: float = 1.0  # Minimum distance to move before triggering update
@export var debug_enabled: bool = false

var last_position: Vector3 = Vector3.INF
var owdb: OpenWorldDatabase

func _ready():
	#last_position = global_position
	_find_owdb()

func _find_owdb():
	# Search up the tree for OWDB
	var current = get_parent()
	while current != null:
		if current is OpenWorldDatabase:
			owdb = current
			if debug_enabled:
				print("OWDBPosition: Found OWDB as ancestor")
			return
		current = current.get_parent()
	
	# Search the entire tree as fallback
	var root = get_tree().root
	owdb = _find_owdb_recursive(root)
	
	if owdb and debug_enabled:
		print("OWDBPosition: Found OWDB in tree")

func _find_owdb_recursive(node: Node) -> OpenWorldDatabase:
	if node is OpenWorldDatabase:
		return node
	
	for child in node.get_children():
		var result = _find_owdb_recursive(child)
		if result:
			return result
	
	return null

func _process(_delta):
	if not owdb or owdb.is_loading:
		return
	
	var current_pos = global_position
	if last_position.distance_to(current_pos) >= update_threshold:
		if debug_enabled:
			print("OWDBPosition: Position changed by ", last_position.distance_to(current_pos), " - triggering chunk update")
		
		owdb.chunk_manager._update_chunks_from_position(current_pos)
		last_position = current_pos

func force_update():
	if owdb and not owdb.is_loading:
		owdb.chunk_manager._update_chunks_from_position(global_position)
		last_position = global_position
