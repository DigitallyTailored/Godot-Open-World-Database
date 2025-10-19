# src/network/Syncer.gd
extends Node

var nodes: Nodes
var _sync_nodes: Dictionary = {}
var _peer_nodes_observing: Dictionary = {}

# OWDB Integration - now managed by OWDB itself
var owdb: OpenWorldDatabase = null
var _peer_positions: Dictionary = {} # peer_id -> OWDBPosition

var transform_mappings := {
	"position": "P", "position.x": "PX", "position.y": "PY", "position.z": "PZ",
	"rotation": "R", "rotation.x": "RX", "rotation.y": "RY", "rotation.z": "RZ",
	"scale": "S", "scale.x": "SX", "scale.y": "SY", "scale.z": "SZ"
}

var reverse_mappings := {}

func _ready() -> void:
	nodes = load("res://addons/open-world-database/src/Nodes.gd").new(self)
	print("SYNCER READY")
	for key in transform_mappings:
		reverse_mappings[transform_mappings[key]] = key

# Called by OWDB when it's ready
func register_owdb(owdb_instance: OpenWorldDatabase):
	if owdb == owdb_instance:
		return # Already registered
	
	# Unregister previous OWDB if any
	if owdb:
		unregister_owdb()
	
	owdb = owdb_instance
	print("SYNCER: OWDB registered - integration active")
	
	# Connect to OWDB's batch completion
	if owdb.batch_processor and not owdb.batch_processor.batch_complete_callbacks.has(_on_owdb_batch_complete):
		owdb.batch_processor.add_batch_complete_callback(_on_owdb_batch_complete)

# Called by OWDB when it's being destroyed or scene changes
func unregister_owdb():
	if not owdb:
		return
	
	print("SYNCER: OWDB unregistered")
	
	# Disconnect from OWDB
	if owdb.batch_processor and owdb.batch_processor.batch_complete_callbacks.has(_on_owdb_batch_complete):
		owdb.batch_processor.remove_batch_complete_callback(_on_owdb_batch_complete)
	
	owdb = null
	_peer_positions.clear()

func _on_owdb_batch_complete():
	# When OWDB finishes loading/unloading chunks, update entity visibility
	_update_entity_visibility_from_owdb()

func _update_new_peer_visibility(peer_id: int):
	# Wait a frame for the peer's OWDBPosition to be registered
	if not _peer_positions.has(peer_id):
		# Try again next frame
		call_deferred("_update_new_peer_visibility", peer_id)
		return
	
	var peer_owdb_position = _peer_positions[peer_id]
	if not peer_owdb_position or not is_instance_valid(peer_owdb_position):
		return
	
	var peer_position = peer_owdb_position.global_position
	
	# Check all registered sync nodes to see if this peer should see them
	for node_name in _sync_nodes:
		var sync_node = _sync_nodes[node_name]
		if not sync_node or not is_instance_valid(sync_node.parent):
			continue
		
		# Skip the peer's own player node - that's handled separately
		if sync_node.peer_id == peer_id:
			continue
		
		var entity_position = sync_node.parent.global_position if sync_node.parent is Node3D else Vector3.ZERO
		var should_see = _should_peer_see_entity(peer_id, entity_position, peer_position)
		
		if should_see:
			entity_peer_visible(peer_id, node_name, true)
			print("Making entity ", node_name, " visible to peer ", peer_id)

# Also update the batch complete handler to be more thorough
func _update_entity_visibility_from_owdb():
	if not multiplayer.is_server() or not owdb:
		return
	
	print("Updating entity visibility from OWDB...")
	
	# For each peer position, determine what entities they should see
	for peer_id in _peer_positions:
		var owdb_position = _peer_positions[peer_id]
		if not owdb_position or not is_instance_valid(owdb_position):
			continue
		
		var peer_position = owdb_position.global_position
		
		# Check all loaded OWDB entities
		for uid in owdb.loaded_nodes_by_uid:
			var node = owdb.loaded_nodes_by_uid[uid]
			if not node or not node.has_node("Sync"):
				continue
			
			var entity_name = node.name
			var node_position = node.global_position if node is Node3D else Vector3.ZERO
			
			var should_see = _should_peer_see_entity(peer_id, node_position, peer_position)
			var currently_visible = peer_has_node(peer_id, entity_name)
			
			if should_see and not currently_visible:
				entity_peer_visible(peer_id, entity_name, true)
				print("Making OWDB entity ", entity_name, " visible to peer ", peer_id)
			elif not should_see and currently_visible:
				entity_peer_visible(peer_id, entity_name, false)
				print("Hiding OWDB entity ", entity_name, " from peer ", peer_id)

func _should_peer_see_entity(peer_id: int, entity_pos: Vector3, peer_pos: Vector3) -> bool:
	# Use OWDB's chunk logic to determine visibility
	if not owdb:
		return true
	
	var distance = entity_pos.distance_to(peer_pos)
	var max_chunk_size = owdb.chunk_sizes[owdb.chunk_sizes.size() - 1]
	var max_distance = max_chunk_size * owdb.chunk_load_range * 1.5 # Add some buffer
	
	return distance <= max_distance

func register_peer_position(peer_id: int, owdb_position: OWDBPosition):
	_peer_positions[peer_id] = owdb_position
	print("Registered OWDBPosition for peer: ", peer_id)

func unregister_peer_position(peer_id: int):
	_peer_positions.erase(peer_id)
	print("Unregistered OWDBPosition for peer: ", peer_id)

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("ui_accept"):
		print("sync_nodes: ", _sync_nodes.keys())
		print("peer_nodes_observing: ", _peer_nodes_observing)
		print("peer_positions: ", _peer_positions.keys())
		print("owdb_registered: ", owdb != null)

# ... rest of the existing Syncer methods remain unchanged
func get_peer_nodes_observing() -> Dictionary:
	return _peer_nodes_observing

func entity_all_visible(node_name: String, is_visible: bool) -> void:
	entity_peer_visible(1, node_name, is_visible)
	for peer_id in multiplayer.get_peers():
		if peer_id != 1:
			entity_peer_visible(peer_id, node_name, is_visible)

func entity_peer_visible(peer_id: int, node_name: String, is_visible: bool) -> void:
	if not multiplayer.is_server():
		return
		
	if not _peer_nodes_observing.has(peer_id):
		_peer_nodes_observing[peer_id] = []
	
	if is_visible and not _peer_nodes_observing[peer_id].has(node_name):
		_peer_nodes_observing[peer_id].append(node_name)
		
		if _sync_nodes.has(node_name):
			var sync_node = _sync_nodes[node_name]
			if peer_id == 1:
				sync_node.parent.visible = true
			else:
				rpc_id(peer_id, "add_node", node_name, sync_node.parent_scene, 
					sync_node.peer_id, sync_node.parent.position, 
					sync_node.parent.rotation, sync_node.synced_values, sync_node.parent_path)
			
	elif not is_visible and _peer_nodes_observing[peer_id].has(node_name):
		_peer_nodes_observing[peer_id].erase(node_name)
		
		if peer_id == 1:
			if _sync_nodes.has(node_name):
				var sync_node = _sync_nodes[node_name]
				sync_node.parent.visible = false
		else:
			rpc_id(peer_id, "remove_node", node_name)

func register_sync_node(sync_node: Sync) -> void:
	var node_name = sync_node.parent_name
	var scene = sync_node.parent_scene
	_sync_nodes[node_name] = sync_node
	
	print("Registered sync node: ", node_name, " at path: ", sync_node.parent_path)
	
	if multiplayer.is_server():
		for peer_id in _peer_nodes_observing.keys():
			if peer_has_node(peer_id, node_name):
				if peer_id == 1:
					sync_node.parent.visible = true
				else:
					rpc_id(peer_id, "add_node", node_name, scene, sync_node.peer_id, 
						sync_node.parent.position, sync_node.parent.rotation, 
						sync_node.synced_values, sync_node.parent_path)

func unregister_sync_node(sync_node: Sync) -> void:
	var node_name = sync_node.parent_name
	
	if not _sync_nodes.has(node_name) or not multiplayer:
		return
		
	if multiplayer.is_server():
		for peer_id in _peer_nodes_observing.keys():
			if peer_has_node(peer_id, node_name):
				if peer_id == 1:
					remove_node(node_name)
				else:
					rpc_id(peer_id, "remove_node", node_name)
				_peer_nodes_observing[peer_id].erase(node_name)
	
	_sync_nodes.erase(node_name)

func sync_variables(sync_node: Sync, variables_in: Dictionary, force_send_to_all: bool = false) -> void:
	var node_name = sync_node.parent_name
	if multiplayer.is_server():
		for peer_id in _peer_nodes_observing.keys():
			if peer_has_node(peer_id, node_name):
				if peer_id != 1 and (force_send_to_all or peer_id != multiplayer.get_remote_sender_id()):
					rpc_id(peer_id, "update_node", node_name, variables_in)
		
		if force_send_to_all or (sync_node.peer_id != 1 and sync_node.peer_id != 0):
			sync_node.variables_receive(variables_in)
	else:
		rpc_id(1, "update_node", node_name, variables_in)

func peer_has_node(peer_id: int, node_name: String) -> bool:
	return _peer_nodes_observing.has(peer_id) and node_name in _peer_nodes_observing[peer_id]

func handle_client_connected_to_server() -> void:
	if multiplayer.is_server():
		return
		
	for node_name in _sync_nodes.keys():
		var sync_node = _sync_nodes[node_name]
		if sync_node.is_pre_existing:
			print("Transferring control of pre-existing node to server: ", node_name)
			sync_node.peer_id = 1
			sync_node.is_pre_existing = false

@rpc("authority", "reliable")
func add_node(node_name: String, scene: String, peer_id: int, position: Vector3, rotation: Vector3, initial_variables: Dictionary, parent_path: String = "") -> void:
	if _sync_nodes.has(node_name):
		print(multiplayer.get_unique_id(), ": taking control of existing node ", node_name)
		var sync_node = _sync_nodes[node_name]
		sync_node.peer_id = peer_id
		sync_node.parent.position = position
		sync_node.parent.rotation = rotation
		sync_node.synced_values = initial_variables
		sync_node.is_pre_existing = false
		
		if not sync_node.watched_variables.is_empty():
			sync_node.apply_initial_values(initial_variables)
		
		return
	
	print(multiplayer.get_unique_id(), ": add_node ", node_name, " at path: ", parent_path)
	nodes.add_id(
		node_name,
		scene,
		parent_path,
		func(entity: Node) -> void:
			entity.name = node_name
			entity_sync_setup(entity, scene, position, rotation, peer_id, initial_variables)
	)

@rpc("authority", "reliable")
func remove_node(node_name: String) -> void:
	print(multiplayer.get_unique_id(), ": remove_node ", node_name)
	nodes.remove(node_name)

@rpc("any_peer", "reliable")
func update_node(node_name: String, new_variables: Dictionary) -> void:
	if multiplayer.is_server():
		if _sync_nodes.has(node_name):
			var sync_node = _sync_nodes[node_name]
			for key in new_variables:
				sync_node.synced_values[key] = new_variables[key]
			sync_variables(sync_node, new_variables, false)
	else:
		if _sync_nodes.has(node_name):
			_sync_nodes[node_name].variables_receive(new_variables)

func handle_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		if not _peer_nodes_observing.has(peer_id):
			_peer_nodes_observing[peer_id] = []
		
		print("Peer ", peer_id, " connected. Current nodes: ", _sync_nodes.keys())
		
		# If we have OWDB, update entity visibility based on peer position
		if owdb:
			call_deferred("_update_new_peer_visibility", peer_id)

func handle_peer_disconnected(peer_id: int) -> void:
	if multiplayer.is_server():
		# Clean up peer's position tracking
		unregister_peer_position(peer_id)
		
		var nodes_to_remove = []
		for node_name in _sync_nodes:
			var sync_node = _sync_nodes[node_name]
			if sync_node.peer_id == peer_id:
				nodes_to_remove.append(node_name)
		
		if _peer_nodes_observing.has(peer_id):
			_peer_nodes_observing.erase(peer_id)
		
		for node_name in nodes_to_remove:
			var sync_node = _sync_nodes[node_name]
			unregister_sync_node(sync_node)
			nodes.remove(node_name)

func entity_sync_setup(node: Node, scene: String, position: Vector3, rotation: Vector3, peer_id: int, initial_variables: Dictionary) -> void:
	node.position = position
	node.rotation = rotation
	
	var sync_node = node.find_child("Sync")
	if not sync_node:
		sync_node = preload("res://addons/open-world-database/src/network/sync/Sync.tscn").instantiate()
		node.add_child(sync_node)
	
	sync_node.peer_id = peer_id
	sync_node.synced_values = initial_variables
