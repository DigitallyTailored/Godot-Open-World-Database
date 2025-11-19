# src/NodeHandler.gd
# Handles node lifecycle events and coordinates with chunk system for loading decisions
# Manages node entering/exiting tree, moves, renames, type changes, and duplicate UID resolution
# Ensures nodes are loaded/unloaded based on chunk requirements
# Input: Tree change signals, node modifications
# Output: Node database updates, chunk lookup maintenance, deferred unloading
@tool
extends RefCounted
class_name NodeHandler

var owdb: OpenWorldDatabase
var _pending_nodes: Dictionary = {}  # Tracks nodes waiting for owner to be set

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database

func handle_child_entered_tree(node: Node):
	if not is_instance_valid(node) or not owdb.is_ancestor_of(node):
		return

	# In editor, nodes might not have owner set immediately when dropped
	# Store them and retry after a frame
	if Engine.is_editor_hint() and node.owner == null:
		var node_id = node.get_instance_id()
		if not _pending_nodes.has(node_id):
			_pending_nodes[node_id] = 0  # Retry counter
			owdb.get_tree().process_frame.connect(_retry_handle_node.bind(node_id, node), CONNECT_ONE_SHOT)
		return
	
	# Skip nodes that don't belong to our scene (but null owner is OK during loading)
	if node.owner != owdb.owner and node.owner != null:
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

func _retry_handle_node(node_id: int, node: Node):
	if not is_instance_valid(node) or not node.is_inside_tree():
		_pending_nodes.erase(node_id)
		return
	
	var retry_count = _pending_nodes.get(node_id, 0)
	
	# If owner is now set, process the node
	if node.owner != null:
		_pending_nodes.erase(node_id)
		handle_child_entered_tree(node)
		return
	
	# Retry up to 10 times (10 frames)
	if retry_count < 10:
		_pending_nodes[node_id] = retry_count + 1
		owdb.get_tree().process_frame.connect(_retry_handle_node.bind(node_id, node), CONNECT_ONE_SHOT)
	else:
		# Give up after 10 retries
		_pending_nodes.erase(node_id)
		owdb.debug("WARNING: Node failed to get owner after 10 retries: ", node.name)

func handle_child_exiting_tree(node: Node):
	if owdb.is_loading:
		return
	
	var uid = NodeUtils.get_valid_node_uid(node)
	if uid != "" and is_instance_valid(node) and node.is_inside_tree():
		owdb._check_node_removal(node)

func _handle_node_move(node: Node):
	owdb.debug("NODE MOVED: ", node.name)
	
	# Check for type changes when node moves
	handle_node_type_change(node)
	
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

func handle_node_type_change(node: Node) -> bool:
	var uid = NodeUtils.get_valid_node_uid(node)
	if uid == "" or not owdb.node_monitor.stored_nodes.has(uid):
		return false
	
	var stored_info = owdb.node_monitor.stored_nodes[uid]
	var current_source = _get_node_source(node)
	
	# Check if the node type (source) has changed
	if stored_info.scene != current_source:
		owdb.debug("NODE TYPE CHANGED: " + uid + " from " + stored_info.scene + " to " + current_source)
		
		# Store old size and position for chunk lookup cleanup
		var old_position = stored_info.position
		var old_size = stored_info.size
		
		# Force recalculate size since node type changed
		var new_size = NodeUtils.calculate_node_size(node, true)
		var new_position = node.global_position if node is Node3D else Vector3.ZERO
		
		# Update stored info
		stored_info.scene = current_source
		stored_info.size = new_size
		stored_info.position = new_position
		
		# Remove from old chunk lookup
		owdb.remove_from_chunk_lookup(uid, old_position, old_size)
		
		# Add to new chunk lookup
		owdb.add_to_chunk_lookup(uid, new_position, new_size)
		
		# Check if the node should still be loaded in its current chunk
		var new_size_cat = owdb.get_size_category(new_size)
		var new_chunk_pos = Vector2i(int(new_position.x / owdb.chunk_sizes[new_size_cat]), int(new_position.z / owdb.chunk_sizes[new_size_cat])) if new_size_cat != OpenWorldDatabase.Size.ALWAYS_LOADED else OpenWorldDatabase.ALWAYS_LOADED_CHUNK_POS
		
		# If the node should no longer be loaded (e.g., changed to a type that puts it in an unloaded chunk)
		if not owdb.chunk_manager.is_chunk_loaded(new_size_cat, new_chunk_pos):
			owdb.debug("NODE TYPE CHANGE REQUIRES UNLOAD: ", uid)
			owdb.call_deferred("_unload_node_not_in_chunk", node)
		
		owdb.debug("NODE TYPE UPDATE COMPLETE: " + uid + " size: " + str(old_size) + " -> " + str(new_size))
		return true
	
	return false

func _get_node_source(node: Node) -> String:
	if node.scene_file_path != "":
		return node.scene_file_path
	return node.get_class()
