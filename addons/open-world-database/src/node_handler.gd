# src/NodeHandler.gd
# Handles node lifecycle events and coordinates with chunk system for loading decisions
# Manages node entering/exiting tree, moves, renames, and duplicate UID resolution
# Ensures nodes are loaded/unloaded based on chunk requirements
# Input: Tree change signals, node modifications
# Output: Node database updates, chunk lookup maintenance, deferred unloading
@tool
extends RefCounted
class_name NodeHandler

var owdb: OpenWorldDatabase

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database

func handle_child_entered_tree(node: Node):
	if not is_instance_valid(node) or not owdb.is_ancestor_of(node):
		return

	if node.owner != owdb.owner:
		return
		
	if node.has_meta("_owd_uid"):
		if owdb.is_loading:
			return
		else:
			var uid = node.get_meta("_owd_uid")
			if owdb.loaded_nodes_by_uid.has(uid):
				var existing_node = owdb.loaded_nodes_by_uid[uid]
				if existing_node != node and is_instance_valid(existing_node):
					var base_name = uid.split(OpenWorldDatabase.UID_SEPARATOR)[0] if OpenWorldDatabase.UID_SEPARATOR in uid else uid
					var new_uid = NodeUtils.generate_next_available_name(base_name, owdb.node_monitor.stored_nodes)
					node.set_meta("_owd_uid", new_uid)
					node.name = new_uid
					
					owdb.debug("DUPLICATE UID DETECTED: " + uid + " -> " + new_uid)
			
	if not (node is Node3D or node.get_class() == "Node"):
		return
	
	owdb.call_deferred("_setup_listeners", node)
	
	if owdb.is_loading:
		return
	
	var existing_node = owdb.get_node_by_uid(node.name)
	if existing_node and existing_node != node:
		_handle_node_move(node)
		return
	
	_handle_new_node(node)

func handle_child_exiting_tree(node: Node):
	if owdb.is_loading:
		return
	
	var uid = NodeUtils.get_valid_node_uid(node)
	if uid != "" and is_instance_valid(node) and node.is_inside_tree():
		owdb._check_node_removal(node)

func _handle_node_move(node: Node):
	owdb.debug("NODE MOVED: ", node.name)
	
	owdb.node_monitor.update_stored_node(node)
	
	var uid = NodeUtils.get_valid_node_uid(node)
	if uid != "":
		var node_size = NodeUtils.calculate_node_size(node)
		if owdb.node_monitor.stored_nodes.has(uid):
			var old_info = owdb.node_monitor.stored_nodes[uid]
			owdb.remove_from_chunk_lookup(uid, old_info.position, old_info.size)
		owdb.add_to_chunk_lookup(uid, node.global_position if node is Node3D else Vector3.ZERO, node_size)

func _handle_new_node(node: Node):
	if not node.has_meta("_owd_uid"):
		var base_name = node.name
		var new_name = NodeUtils.generate_next_available_name(base_name, owdb.node_monitor.stored_nodes)
		node.set_meta("_owd_uid", new_name)
		node.name = new_name
	
	var uid = node.get_meta("_owd_uid")
	var existing_node = owdb.get_node_by_uid(uid)
	if existing_node != null and existing_node != node:
		var base_name = node.name.split(OpenWorldDatabase.UID_SEPARATOR)[0] if OpenWorldDatabase.UID_SEPARATOR in node.name else node.name
		var new_uid = NodeUtils.generate_next_available_name(base_name, owdb.node_monitor.stored_nodes)
		node.set_meta("_owd_uid", new_uid)
		node.name = new_uid
		uid = new_uid
	
	call_deferred("_handle_new_node_positioning", node)

func _handle_new_node_positioning(node: Node):
	var uid = NodeUtils.get_valid_node_uid(node)
	if uid == "" or not is_instance_valid(node) or not node.is_inside_tree():
		return
	
	owdb.node_monitor.update_stored_node(node)
	owdb.loaded_nodes_by_uid[uid] = node
	
	var node_size = NodeUtils.calculate_node_size(node)
	var node_position = node.global_position if node is Node3D else Vector3.ZERO
	var size_cat = owdb.get_size_category(node_size)
	var chunk_pos = Vector2i(int(node_position.x / owdb.chunk_sizes[size_cat]), int(node_position.z / owdb.chunk_sizes[size_cat])) if size_cat != OpenWorldDatabase.Size.ALWAYS_LOADED else OpenWorldDatabase.ALWAYS_LOADED_CHUNK_POS
	
	owdb.add_to_chunk_lookup(uid, node_position, node_size)
	
	owdb.debug("NODE ADDED: " + node.name + " at position: " + str(node_position) + " - " + str(owdb.get_total_database_nodes()) + " total nodes")
	
	if not owdb.chunk_manager.is_chunk_loaded(size_cat, chunk_pos):
		owdb.debug("NODE ADDED TO UNLOADED CHUNK - UNLOADING: ", node.name)
		owdb.call_deferred("_unload_node_not_in_chunk", node)
		return

func handle_node_rename(node: Node) -> bool:
	var old_uid = NodeUtils.get_valid_node_uid(node)
	if old_uid == "" or old_uid == node.name:
		return false
	
	node.set_meta("_owd_uid", node.name)
	
	if owdb.node_monitor.stored_nodes.has(old_uid):
		var node_info = owdb.node_monitor.stored_nodes[old_uid]
		node_info.uid = node.name
		owdb.node_monitor.stored_nodes[node.name] = node_info
		owdb.node_monitor.stored_nodes.erase(old_uid)
	
	if owdb.loaded_nodes_by_uid.has(old_uid):
		owdb.loaded_nodes_by_uid[node.name] = owdb.loaded_nodes_by_uid[old_uid]
		owdb.loaded_nodes_by_uid.erase(old_uid)
	
	NodeUtils.update_chunk_lookup_uid(owdb.chunk_lookup, old_uid, node.name)
	
	NodeUtils.update_parent_references(owdb.node_monitor.stored_nodes, old_uid, node.name)
	
	owdb.batch_processor.remove_from_queues(old_uid)
	
	return true
