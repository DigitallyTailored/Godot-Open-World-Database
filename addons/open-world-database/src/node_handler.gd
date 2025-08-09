@tool
extends RefCounted
class_name NodeHandler

var owdb: OpenWorldDatabase

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database

func handle_child_entered_tree(node: Node):
	if not is_instance_valid(node) or not owdb.is_ancestor_of(node):
		return

	if node.owner != owdb.owner or node.has_meta("_owd_uid"):
		return

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
	if owdb.debug_enabled:
		print("NODE MOVED: ", node.name)
	
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
		var uid = "%s%s%s" % [node.name, OpenWorldDatabase.UID_SEPARATOR, NodeUtils.generate_uid()]
		node.set_meta("_owd_uid", uid)
		node.name = uid
	
	var uid = node.get_meta("_owd_uid")
	var existing_node = owdb.get_node_by_uid(uid)
	if existing_node != null and existing_node != node:
		var new_uid = "%s%s%s" % [node.name.split(OpenWorldDatabase.UID_SEPARATOR)[0], OpenWorldDatabase.UID_SEPARATOR, NodeUtils.generate_uid()]
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
	
	if owdb.debug_enabled:
		print("NODE ADDED: ", node.name, " at position: ", node_position, " - ", owdb.get_total_database_nodes(), " total nodes")
	
	if not owdb.chunk_manager.is_chunk_loaded(size_cat, chunk_pos):
		if owdb.debug_enabled:
			print("NODE ADDED TO UNLOADED CHUNK - UNLOADING: ", node.name)
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
	
	# Update cache
	if owdb.loaded_nodes_by_uid.has(old_uid):
		owdb.loaded_nodes_by_uid[node.name] = owdb.loaded_nodes_by_uid[old_uid]
		owdb.loaded_nodes_by_uid.erase(old_uid)
	
	# Update chunk lookup
	NodeUtils.update_chunk_lookup_uid(owdb.chunk_lookup, old_uid, node.name)
	
	# Update parent references
	NodeUtils.update_parent_references(owdb.node_monitor.stored_nodes, old_uid, node.name)
	
	# Update queues
	owdb.batch_processor.remove_from_queues(old_uid)
	
	return true
