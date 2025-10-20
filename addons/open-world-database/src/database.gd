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
		
	return scene_path.get_basename() + OpenWorldDatabase.DATABASE_EXTENSION

func get_user_database_path(database_name: String) -> String:
	if database_name == "":
		return ""
	
	var db_name = database_name
	if not db_name.ends_with(OpenWorldDatabase.DATABASE_EXTENSION):
		db_name += OpenWorldDatabase.DATABASE_EXTENSION
	
	return "user://" + db_name

# Consolidated save function
func save_database(custom_name: String = ""):
	var db_path = _get_database_path(custom_name)
	if db_path == "":
		print(owdb.multiplayer.get_unique_id(), ": Error: Cannot determine database path")
		return
	
	_save_database_to_path(db_path)

# Consolidated load function  
func load_database(custom_name: String = ""):
	var db_path = _get_database_path(custom_name)
	if db_path == "" or not FileAccess.file_exists(db_path):
		if custom_name != "":
			owdb.debug_log("Custom database not found: ", db_path)
		return
	
	_load_database_from_path(db_path)

func _get_database_path(custom_name: String = "") -> String:
	if custom_name != "":
		return get_user_database_path(custom_name)
	return get_database_path()

func list_custom_databases() -> Array[String]:
	var databases = []
	var dir = DirAccess.open("user://")
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(OpenWorldDatabase.DATABASE_EXTENSION):
				databases.append(file_name.get_basename())
			file_name = dir.get_next()
		dir.list_dir_end()
	return databases

func delete_custom_database(database_name: String) -> bool:
	var db_path = get_user_database_path(database_name)
	if FileAccess.file_exists(db_path):
		DirAccess.remove_absolute(db_path)
		return true
	return false

func _save_database_to_path(db_path: String):
	# Update all currently loaded nodes and handle size/position changes
	# BUT only if they still exist in stored_nodes (haven't been deleted)
	for uid in owdb.loaded_nodes_by_uid.keys():  # Use keys() to avoid modification during iteration
		if not owdb.node_monitor.stored_nodes.has(uid):
			continue  # Skip nodes that have been removed from database
			
		var node = owdb.loaded_nodes_by_uid[uid]
		if not is_instance_valid(node):
			# Clean up invalid node references
			owdb.loaded_nodes_by_uid.erase(uid)
			continue
			
		owdb.node_handler.handle_node_rename(node)
		
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
		print(owdb.multiplayer.get_unique_id(), ": Error: Could not create database file at: ", db_path)
		return
	
	var top_level_uids = _get_top_level_uids()
	
	for uid in top_level_uids:
		_write_node_recursive(file, uid, 0)
	
	file.close()
	owdb.debug_log("Database saved successfully to: ", db_path)

func _get_top_level_uids() -> Array:
	var top_level_uids = []
	for uid in owdb.node_monitor.stored_nodes:
		if owdb.node_monitor.stored_nodes[uid].parent_uid == "":
			top_level_uids.append(uid)
	
	#top_level_uids.sort()
	return top_level_uids

func _load_database_from_path(db_path: String):
	var file = FileAccess.open(db_path, FileAccess.READ)
	if not file:
		print(owdb.multiplayer.get_unique_id(), ": Error: Could not open database: ", db_path)
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
	owdb.debug_log("Database loaded successfully from: ", db_path)

func debug():
	print(owdb.multiplayer.get_unique_id(), ": ")
	print(owdb.multiplayer.get_unique_id(), ": All known nodes  ", owdb.node_monitor.stored_nodes)
	print(owdb.multiplayer.get_unique_id(), ": ")
	print(owdb.multiplayer.get_unique_id(), ": Chunked nodes ", owdb.chunk_lookup)
	print(owdb.multiplayer.get_unique_id(), ": ")

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
	
	var child_uids = _get_child_uids(uid)
	for child_uid in child_uids:
		_write_node_recursive(file, child_uid, depth + 1)

func _get_child_uids(parent_uid: String) -> Array:
	var child_uids = []
	for child_uid in owdb.node_monitor.stored_nodes:
		if owdb.node_monitor.stored_nodes[child_uid].parent_uid == parent_uid:
			child_uids.append(child_uid)
	
	#child_uids.sort()
	return child_uids

func _parse_line(line: String) -> Dictionary:
	var parts = line.split("|")
	if parts.size() < 6:
		return {}
	
	return {
		"uid": parts[0],
		"scene": parts[1].strip_edges().trim_prefix("\"").trim_suffix("\""),
		"parent_uid": "",
		"position": NodeUtils.parse_vector3(parts[2]),
		"rotation": NodeUtils.parse_vector3(parts[3]),
		"scale": NodeUtils.parse_vector3(parts[4]),
		"size": parts[5].to_float(),
		"properties": _parse_properties(parts[6] if parts.size() > 6 else "{}")
	}

func _parse_properties(props_str: String) -> Dictionary:
	if props_str == "{}" or props_str == "":
		return {}
	
	var json = JSON.new()
	if json.parse(props_str) == OK:
		return json.data
	
	return {}
