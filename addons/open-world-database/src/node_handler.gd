@tool
extends RefCounted
class_name NodeHandler

var owdb: OpenWorldDatabase

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database

func handle_child_entered_tree(node: Node):
	if not is_instance_valid(node) or not owdb.is_ancestor_of(node):
		return

	# Use owner check instead of groups - only manage nodes with matching owner
	if node.owner != owdb.owner or node.has_meta("_owd_uid"):
		return

	if not (node is Node3D or node.get_class() == "Node"):
		return
	
	owdb.call_deferred("setup_listeners", node)
	
	if owdb.is_loading:
		return
	
	var existing_node = owdb.get_node_by_uid(node.name)
	if existing_node and existing_node != node:
		_handle_node_move(node)
		return
	
	_handle_new_node(node)

func handle_child_exiting_tree(node: Node):
	if owdb.is_loading or not node.has_meta("_owd_uid"):
		return
	
	if is_instance_valid(node) and node.is_inside_tree() and node.has_meta("_owd_uid"):
		#owdb.call_deferred("_check_node_removal", node)
		owdb._check_node_removal(node)

func _handle_node_move(node: Node):
	if owdb.debug_enabled:
		print("NODE MOVED: ", node.name)
	
	owdb.node_monitor.update_stored_node(node)
	
	var uid = node.get_meta("_owd_uid", "")
	if uid != "":
		var node_size = NodeUtils.calculate_node_size(node)
		if owdb.node_monitor.stored_nodes.has(uid):
			var old_info = owdb.node_monitor.stored_nodes[uid]
			owdb.remove_from_chunk_lookup(uid, old_info.position, old_info.size)
		owdb.add_to_chunk_lookup(uid, node.global_position if node is Node3D else Vector3.ZERO, node_size)

func _handle_new_node(node: Node):
	if not node.has_meta("_owd_uid"):
		var uid = node.name + '-' + NodeUtils.generate_uid()
		node.set_meta("_owd_uid", uid)
		node.name = uid
	
	var uid = node.get_meta("_owd_uid")
	var existing_node = owdb.get_node_by_uid(uid)
	if existing_node != null and existing_node != node:
		var new_uid = node.name.split('-')[0] + '-' + NodeUtils.generate_uid()
		node.set_meta("_owd_uid", new_uid)
		node.name = new_uid
		uid = new_uid
	
	call_deferred("_handle_new_node_positioning", node)

func _handle_new_node_positioning(node: Node):
	if not is_instance_valid(node) or not node.is_inside_tree():
		return
	
	var uid = node.get_meta("_owd_uid", "")
	if uid == "":
		return
	
	owdb.node_monitor.update_stored_node(node)
	
	var node_size = NodeUtils.calculate_node_size(node)
	var node_position = node.global_position if node is Node3D else Vector3.ZERO
	var size_cat = owdb.get_size_category(node_size)
	var chunk_pos = owdb.get_chunk_position(node_position, size_cat)
	
	owdb.add_to_chunk_lookup(uid, node_position, node_size)
	
	if owdb.debug_enabled:
		print("NODE ADDED: ", node.name, " at position: ", node_position, " - ", owdb.get_total_database_nodes(), " total nodes")
	
	if not owdb.is_chunk_loaded(size_cat, chunk_pos):
		if owdb.debug_enabled:
			print("NODE ADDED TO UNLOADED CHUNK - UNLOADING: ", node.name)
		owdb.call_deferred("_unload_node_not_in_chunk", node)
		return

func handle_node_rename(node: Node) -> bool:
	if not node.has_meta("_owd_uid"):
		return false
	
	var old_uid = node.get_meta("_owd_uid")
	if old_uid == node.name:
		return false
	
	node.set_meta("_owd_uid", node.name)
	
	if owdb.node_monitor.stored_nodes.has(old_uid):
		var node_info = owdb.node_monitor.stored_nodes[old_uid]
		node_info.uid = node.name
		owdb.node_monitor.stored_nodes[node.name] = node_info
		owdb.node_monitor.stored_nodes.erase(old_uid)
	
	# Update chunk lookup
	for size in owdb.chunk_lookup:
		for chunk_pos in owdb.chunk_lookup[size]:
			var uid_list = owdb.chunk_lookup[size][chunk_pos]
			var old_index = uid_list.find(old_uid)
			if old_index >= 0:
				uid_list[old_index] = node.name
	
	# Update parent references
	for child_uid in owdb.node_monitor.stored_nodes:
		var child_info = owdb.node_monitor.stored_nodes[child_uid]
		if child_info.parent_uid == old_uid:
			child_info.parent_uid = node.name
	
	# Update queues if present in batch processor
	owdb.batch_processor.remove_from_queues(old_uid)
	
	return true
