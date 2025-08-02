#database.gd
@tool
extends RefCounted
class_name Database

var owdb: OpenWorldDatabase

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database

func get_database_path() -> String:
	var scene_path: String = ""
	
	if Engine.is_editor_hint():
		var edited_scene = EditorInterface.get_edited_scene_root()
		if edited_scene:
			scene_path = edited_scene.scene_file_path
	else:
		var current_scene = owdb.get_tree().current_scene
		if current_scene:
			scene_path = current_scene.scene_file_path
	
	if scene_path == "":
		return ""
		
	return scene_path.get_basename() + ".owdb"

func save_database():
	var db_path = get_database_path()
	if db_path == "":
		print("Error: Scene must be saved before saving database")
		return
	
	# First, update all currently loaded nodes and handle size/position changes
	for node in owdb.get_all_owd_nodes():
		var uid = node.get_meta("_owd_uid", "")
		if uid == "":
			continue
		
		owdb.handle_node_rename(node)
		
		var old_info = owdb.node_monitor.stored_nodes.get(uid, {})
		owdb.node_monitor.update_stored_node(node, true)
		
		# Check if node needs to be moved to different chunk
		if old_info.has("position") and old_info.has("size"):
			var new_info = owdb.node_monitor.stored_nodes[uid]
			
			if old_info.position.distance_to(new_info.position) > 0.01 or abs(old_info.size - new_info.size) > 0.01:
				owdb.remove_from_chunk_lookup(uid, old_info.position, old_info.size)
				owdb.add_to_chunk_lookup(uid, new_info.position, new_info.size)
	
	var file = FileAccess.open(db_path, FileAccess.WRITE)
	if not file:
		print("Error: Could not create database file")
		return
	
	var top_level_uids = []
	for uid in owdb.node_monitor.stored_nodes:
		if owdb.node_monitor.stored_nodes[uid].parent_uid == "":
			top_level_uids.append(uid)
	
	top_level_uids.sort()
	
	for uid in top_level_uids:
		_write_node_recursive(file, uid, 0)
	
	file.close()
	if owdb.debug_enabled:
		print("Database saved successfully!")

func _write_node_recursive(file: FileAccess, uid: String, depth: int):
	var info = owdb.node_monitor.stored_nodes.get(uid, {})
	if info.is_empty():
		return
	
	var props_str = "{}" if info.properties.size() == 0 else JSON.stringify(info.properties)
	
	var line = "%s%s|\"%s\"|%s,%s,%s|%s,%s,%s|%s,%s,%s|%s|%s" % [
		"\t".repeat(depth), uid, info.scene,
		info.position.x, info.position.y, info.position.z,
		info.rotation.x, info.rotation.y, info.rotation.z,
		info.scale.x, info.scale.y, info.scale.z,
		info.size, props_str
	]
	
	file.store_line(line)
	
	var child_uids = []
	for child_uid in owdb.node_monitor.stored_nodes:
		if owdb.node_monitor.stored_nodes[child_uid].parent_uid == uid:
			child_uids.append(child_uid)
	
	child_uids.sort()
	for child_uid in child_uids:
		_write_node_recursive(file, child_uid, depth + 1)

func load_database():
	var db_path = get_database_path()
	if db_path == "" or not FileAccess.file_exists(db_path):
		return
	
	var file = FileAccess.open(db_path, FileAccess.READ)
	if not file:
		return
	
	owdb.node_monitor.stored_nodes.clear()
	owdb.chunk_lookup.clear()
	
	var node_stack = []
	var depth_stack = []
	
	while not file.eof_reached():
		var line = file.get_line()
		if line == "":
			continue
		
		var depth = 0
		while depth < line.length() and line[depth] == "\t":
			depth += 1
		
		var info = _parse_line(line.strip_edges())
		if not info:
			continue
		
		while depth_stack.size() > 0 and depth <= depth_stack[-1]:
			node_stack.pop_back()
			depth_stack.pop_back()
		
		if node_stack.size() > 0:
			info.parent_uid = node_stack[-1]
		
		node_stack.append(info.uid)
		depth_stack.append(depth)
		
		owdb.node_monitor.stored_nodes[info.uid] = info
		owdb.add_to_chunk_lookup(info.uid, info.position, info.size)
	
	file.close()
	if owdb.debug_enabled:
		print("Database loaded successfully!")

func debug():
	print("")
	print("All known nodes  ", owdb.node_monitor.stored_nodes)
	print("")
	print("Chunked nodes ", owdb.chunk_lookup)
	print("")

func _parse_line(line: String) -> Dictionary:
	var parts = line.split("|")
	if parts.size() < 6:
		return {}
	
	return {
		"uid": parts[0],
		"scene": parts[1].strip_edges().trim_prefix("\"").trim_suffix("\""),
		"parent_uid": "",
		"position": _parse_vector3(parts[2]),
		"rotation": _parse_vector3(parts[3]),
		"scale": _parse_vector3(parts[4]),
		"size": parts[5].to_float(),
		"properties": _parse_properties(parts[6] if parts.size() > 6 else "{}")
	}

func _parse_vector3(vector_str: String) -> Vector3:
	var components = vector_str.split(",")
	if components.size() != 3:
		return Vector3.ZERO
	
	return Vector3(
		components[0].to_float(),
		components[1].to_float(),
		components[2].to_float()
	)

func _parse_properties(props_str: String) -> Dictionary:
	if props_str == "{}" or props_str == "":
		return {}
	
	var json = JSON.new()
	if json.parse(props_str) == OK:
		return json.data
	
	return {}
