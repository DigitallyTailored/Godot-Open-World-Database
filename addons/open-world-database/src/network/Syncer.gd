# src/network/Syncer.gd
extends Node

var nodes: Nodes
var _sync_nodes: Dictionary = {}  # node_name -> SyncNodeData
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

# Internal class to track sync node data
class SyncNodeData:
	var parent: Node3D
	var parent_scene: String
	var parent_name: String
	var parent_path: String
	var peer_id: int
	var synced_values: Dictionary
	var sync_component: Sync = null  # null if no Sync component
	var is_pre_existing: bool = false
	
	func _init(node: Node3D, scene: String, name: String, path: String, peer: int, values: Dictionary, sync_comp: Sync = null):
		parent = node
		parent_scene = scene
		parent_name = name
		parent_path = path
		peer_id = peer
		synced_values = values
		sync_component = sync_comp

func _ready() -> void:
	nodes = load("res://addons/open-world-database/src/Nodes.gd").new(self)
	print(multiplayer.get_unique_id(), ": SYNCER READY")
	for key in transform_mappings:
		reverse_mappings[transform_mappings[key]] = key

# Called by OWDB when it's ready
func register_owdb(owdb_instance: OpenWorldDatabase):
	if owdb == owdb_instance:
		return
	
	if owdb:
		unregister_owdb()
	
	owdb = owdb_instance
	print(multiplayer.get_unique_id(), ": SYNCER: OWDB registered - integration active")
	
	if owdb.batch_processor and not owdb.batch_processor.batch_complete_callbacks.has(_on_owdb_batch_complete):
		owdb.batch_processor.add_batch_complete_callback(_on_owdb_batch_complete)

func unregister_owdb():
	if not owdb:
		return
	
	print(multiplayer.get_unique_id(), ": SYNCER: OWDB unregistered")
	
	if owdb.batch_processor and owdb.batch_processor.batch_complete_callbacks.has(_on_owdb_batch_complete):
		owdb.batch_processor.remove_batch_complete_callback(_on_owdb_batch_complete)
	
	owdb = null
	_peer_positions.clear()

func _on_owdb_batch_complete():
	_update_entity_visibility_from_owdb()

func _update_new_peer_visibility(peer_id: int):
	if not _peer_positions.has(peer_id):
		call_deferred("_update_new_peer_visibility", peer_id)
		return
	
	var peer_owdb_position = _peer_positions[peer_id]
	if not peer_owdb_position or not is_instance_valid(peer_owdb_position):
		return
	
	# Use the same chunk-based logic instead of making everything visible
	_update_single_peer_visibility(peer_id)

func _update_entity_visibility_from_owdb():
	if not multiplayer.is_server() or not owdb:
		return
	
	print(multiplayer.get_unique_id(), ": Updating entity visibility from OWDB chunks...")
	
	for peer_id in _peer_positions:
		var owdb_position = _peer_positions[peer_id]
		if not owdb_position or not is_instance_valid(owdb_position):
			continue
		
		# Get all entities that should be visible (both sync nodes and OWDB entities)
		# Use a set to avoid duplicates
		var all_entities_to_check = {}
		
		# Add registered sync nodes
		for node_name in _sync_nodes:
			var sync_data = _sync_nodes[node_name]
			if sync_data and is_instance_valid(sync_data.parent):
				all_entities_to_check[node_name] = sync_data.parent
		
		# Add OWDB entities (but avoid duplicates with sync nodes)
		for uid in owdb.loaded_nodes_by_uid:
			var node = owdb.loaded_nodes_by_uid[uid]
			if node and not all_entities_to_check.has(node.name):
				all_entities_to_check[node.name] = node
		
		# Process each entity once
		for entity_name in all_entities_to_check:
			var entity_node = all_entities_to_check[entity_name]
			
			# Skip self
			if _sync_nodes.has(entity_name) and _sync_nodes[entity_name].peer_id == peer_id:
				continue
			
			var should_see = _should_peer_see_entity_via_chunks(peer_id, entity_node)
			var currently_visible = peer_has_node(peer_id, entity_name)
			
			if should_see and not currently_visible:
				entity_peer_visible(peer_id, entity_name, true)
				if _sync_nodes.has(entity_name):
					print(multiplayer.get_unique_id(), ": Making sync entity ", entity_name, " visible to peer ", peer_id)
				else:
					print(multiplayer.get_unique_id(), ": Making OWDB entity ", entity_name, " visible to peer ", peer_id)
			elif not should_see and currently_visible:
				entity_peer_visible(peer_id, entity_name, false)
				if _sync_nodes.has(entity_name):
					print(multiplayer.get_unique_id(), ": Hiding sync entity ", entity_name, " from peer ", peer_id)
				else:
					print(multiplayer.get_unique_id(), ": Hiding OWDB entity ", entity_name, " from peer ", peer_id)

# NEW: Update visibility for a single peer when they move
func _update_single_peer_visibility(peer_id: int):
	if not multiplayer.is_server() or not owdb:
		return
	
	if not _peer_positions.has(peer_id):
		return
	
	print(multiplayer.get_unique_id(), ": Updating visibility for peer ", peer_id, " due to position change...")
	
	# Get all entities that could be visible
	var all_entities_to_check = {}
	
	# Add registered sync nodes
	for node_name in _sync_nodes:
		var sync_data = _sync_nodes[node_name]
		if sync_data and is_instance_valid(sync_data.parent):
			all_entities_to_check[node_name] = sync_data.parent
	
	# Add OWDB entities (but avoid duplicates with sync nodes)
	for uid in owdb.loaded_nodes_by_uid:
		var node = owdb.loaded_nodes_by_uid[uid]
		if node and not all_entities_to_check.has(node.name):
			all_entities_to_check[node.name] = node
	
	# Process each entity for this specific peer
	for entity_name in all_entities_to_check:
		var entity_node = all_entities_to_check[entity_name]
		
		# Skip self
		if _sync_nodes.has(entity_name) and _sync_nodes[entity_name].peer_id == peer_id:
			continue
		
		var should_see = _should_peer_see_entity_via_chunks(peer_id, entity_node)
		var currently_visible = peer_has_node(peer_id, entity_name)
		
		if should_see and not currently_visible:
			entity_peer_visible(peer_id, entity_name, true)
			if _sync_nodes.has(entity_name):
				print(multiplayer.get_unique_id(), ": Making sync entity ", entity_name, " visible to peer ", peer_id)
			else:
				print(multiplayer.get_unique_id(), ": Making OWDB entity ", entity_name, " visible to peer ", peer_id)
		elif not should_see and currently_visible:
			entity_peer_visible(peer_id, entity_name, false)
			if _sync_nodes.has(entity_name):
				print(multiplayer.get_unique_id(), ": Hiding sync entity ", entity_name, " from peer ", peer_id)
			else:
				print(multiplayer.get_unique_id(), ": Hiding OWDB entity ", entity_name, " from peer ", peer_id)

# FIXED: Use OWDB's chunk system with proper edge case handling
func _should_peer_see_entity_via_chunks(peer_id: int, entity_node: Node3D) -> bool:
	if not owdb or not entity_node:
		return true
	
	# Get the peer's position
	var owdb_position = _peer_positions.get(peer_id)
	if not owdb_position or not is_instance_valid(owdb_position):
		return false
	
	var peer_position_id = owdb_position.get_position_id()
	if peer_position_id == "":
		return false
	
	# Get the chunks required by this peer
	var peer_required_chunks = owdb.chunk_manager.position_required_chunks.get(peer_position_id, {})
	if peer_required_chunks.is_empty():
		return false
	
	# Check if the entity is in any of the chunks that this peer should see
	var entity_position = entity_node.global_position if entity_node is Node3D else Vector3.ZERO
	var entity_size = NodeUtils.calculate_node_size(entity_node) if entity_node is Node3D else 0.0
	var entity_size_category = owdb.get_size_category(entity_size)
	
	# ALWAYS_LOADED entities should always be visible
	if entity_size_category == OpenWorldDatabase.Size.ALWAYS_LOADED:
		return peer_required_chunks.has(OpenWorldDatabase.Size.ALWAYS_LOADED)
	
	# FIXED: Proper chunk size calculation with bounds checking
	if entity_size_category >= owdb.chunk_sizes.size():
		# If size category is out of bounds, treat as ALWAYS_LOADED
		return peer_required_chunks.has(OpenWorldDatabase.Size.ALWAYS_LOADED)
	
	var chunk_size = owdb.chunk_sizes[entity_size_category]
	var entity_chunk_pos = NodeUtils.get_chunk_position(entity_position, chunk_size)
	
	# Check if the peer requires the chunk that contains this entity
	var required_chunks_for_size = peer_required_chunks.get(entity_size_category, {})
	return required_chunks_for_size.has(entity_chunk_pos)

func register_peer_position(peer_id: int, owdb_position: OWDBPosition):
	_peer_positions[peer_id] = owdb_position
	print(multiplayer.get_unique_id(), ": Registered OWDBPosition for peer: ", peer_id)

func unregister_peer_position(peer_id: int):
	_peer_positions.erase(peer_id)
	print(multiplayer.get_unique_id(), ": Unregistered OWDBPosition for peer: ", peer_id)

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("ui_accept"):
		print(multiplayer.get_unique_id(), ": sync_nodes: ", _sync_nodes.keys())
		print(multiplayer.get_unique_id(), ": peer_nodes_observing: ", _peer_nodes_observing)
		print(multiplayer.get_unique_id(), ": peer_positions: ", _peer_positions.keys())
		print(multiplayer.get_unique_id(), ": owdb_registered: ", owdb != null)

# NEW: Check if a node is already registered
func is_node_registered(node: Node3D) -> bool:
	return _sync_nodes.has(node.name)

# NEW: Universal node registration (works with or without Sync component)
func register_node(node: Node3D, scene: String = "", peer_id: int = 1, initial_values: Dictionary = {}, sync_component: Sync = null) -> void:
	var node_name = node.name
	var node_scene = scene if scene != "" else (node.scene_file_path if node.scene_file_path != "" else node.get_class())
	var node_path = _get_node_path(node)
	
	var sync_data = SyncNodeData.new(node, node_scene, node_name, node_path, peer_id, initial_values, sync_component)
	sync_data.is_pre_existing = _check_if_pre_existing(node_name)
	
	_sync_nodes[node_name] = sync_data
	
	print(multiplayer.get_unique_id(), ": Registered node: ", node_name, " (has Sync: ", sync_component != null, ")")
	
	# Connect to node signals for automatic cleanup
	if not node.tree_exiting.is_connected(_on_node_tree_exiting):
		node.tree_exiting.connect(_on_node_tree_exiting.bind(node))
	
	if multiplayer.is_server():
		for peer_id_key in _peer_nodes_observing.keys():
			if peer_has_node(peer_id_key, node_name):
				if peer_id_key == 1:
					node.visible = true
				else:
					rpc_id(peer_id_key, "add_node", node_name, node_scene, sync_data.peer_id, 
						node.position, node.rotation, sync_data.synced_values, node_path)

# NEW: Universal node unregistration
func unregister_node(node: Node3D) -> void:
	var node_name = node.name
	
	if not _sync_nodes.has(node_name):
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
	print(multiplayer.get_unique_id(), ": Unregistered node: ", node_name)

# NEW: Handle node cleanup when it exits tree
func _on_node_tree_exiting(node: Node3D):
	unregister_node(node)

func _get_node_path(node: Node3D) -> String:
	var current_parent = node.get_parent()
	if current_parent == get_node("/root"):
		return ""
	return current_parent.get_path()

func _check_if_pre_existing(node_name: String) -> bool:
	if not multiplayer or not multiplayer.has_multiplayer_peer():
		return true
	var loaded_nodes = nodes.get_loaded()
	return not loaded_nodes.has(node_name)

# UPDATED: Sync variables now works with both types of nodes
func sync_variables(node_name: String, variables_in: Dictionary, force_send_to_all: bool = false, sender_peer_id: int = -1) -> void:
	if not _sync_nodes.has(node_name):
		return
	
	var sync_data = _sync_nodes[node_name]
	
	# Update stored values
	for key in variables_in:
		sync_data.synced_values[key] = variables_in[key]
	
	if multiplayer.is_server():
		for peer_id in _peer_nodes_observing.keys():
			if peer_has_node(peer_id, node_name):
				var should_send = force_send_to_all or (sender_peer_id == -1 or peer_id != sender_peer_id)
				if peer_id != 1 and should_send:
					rpc_id(peer_id, "update_node", node_name, variables_in)
		
		# Apply to local node if it's not the sender
		if force_send_to_all or (sync_data.peer_id != 1 and sync_data.peer_id != 0):
			_apply_variables_to_node(sync_data, variables_in)
	else:
		rpc_id(1, "update_node", node_name, variables_in)

# NEW: Apply variables to nodes (handles both with and without Sync component)
func _apply_variables_to_node(sync_data: SyncNodeData, variables: Dictionary):
	if sync_data.sync_component:
		# Let Sync component handle it
		sync_data.sync_component.variables_receive(variables)
	else:
		# Handle it directly for nodes without Sync
		var converted_variables = _convert_short_keys_to_properties(variables)
		for key in converted_variables:
			_set_node_property(sync_data.parent, key, converted_variables[key])

# NEW: Direct property setting for nodes without Sync component
func _set_node_property(node: Node3D, property_name: String, value):
	match property_name:
		"position": node.position = value
		"rotation": node.rotation = value
		"scale": node.scale = value
		"position.x": node.position = Vector3(value, node.position.y, node.position.z)
		"position.y": node.position = Vector3(node.position.x, value, node.position.z)
		"position.z": node.position = Vector3(node.position.x, node.position.y, value)
		"rotation.x": node.rotation = Vector3(value, node.rotation.y, node.rotation.z)
		"rotation.y": node.rotation = Vector3(node.rotation.x, value, node.rotation.z)
		"rotation.z": node.rotation = Vector3(node.rotation.x, node.rotation.y, value)
		"scale.x": node.scale = Vector3(value, node.scale.y, node.scale.z)
		"scale.y": node.scale = Vector3(node.scale.x, value, node.scale.z)
		"scale.z": node.scale = Vector3(node.scale.x, node.scale.y, value)
		_: 
			if node.has_method("set") and property_name in node:
				node.set(property_name, value)

func _convert_short_keys_to_properties(data: Dictionary) -> Dictionary:
	var converted = {}
	for key in data:
		if reverse_mappings.has(key):
			converted[reverse_mappings[key]] = data[key]
		else:
			converted[key] = data[key]
	return converted

# Rest of the existing methods remain unchanged but updated to work with SyncNodeData
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
			var sync_data = _sync_nodes[node_name]
			if peer_id == 1:
				sync_data.parent.visible = true
			else:
				rpc_id(peer_id, "add_node", node_name, sync_data.parent_scene, 
					sync_data.peer_id, sync_data.parent.position, 
					sync_data.parent.rotation, sync_data.synced_values, sync_data.parent_path)
			
	elif not is_visible and _peer_nodes_observing[peer_id].has(node_name):
		_peer_nodes_observing[peer_id].erase(node_name)
		
		if peer_id == 1:
			if _sync_nodes.has(node_name):
				var sync_data = _sync_nodes[node_name]
				sync_data.parent.visible = false
		else:
			rpc_id(peer_id, "remove_node", node_name)

func peer_has_node(peer_id: int, node_name: String) -> bool:
	return _peer_nodes_observing.has(peer_id) and node_name in _peer_nodes_observing[peer_id]

func handle_client_connected_to_server() -> void:
	if multiplayer.is_server():
		return
		
	for node_name in _sync_nodes.keys():
		var sync_data = _sync_nodes[node_name]
		if sync_data.is_pre_existing:
			print(multiplayer.get_unique_id(), ": Transferring control of pre-existing node to server: ", node_name)
			sync_data.peer_id = 1
			sync_data.is_pre_existing = false

@rpc("authority", "reliable")
func add_node(node_name: String, scene: String, peer_id: int, position: Vector3, rotation: Vector3, initial_variables: Dictionary, parent_path: String = "") -> void:
	if _sync_nodes.has(node_name):
		print(multiplayer.get_unique_id(), ": taking control of existing node ", node_name)
		var sync_data = _sync_nodes[node_name]
		sync_data.peer_id = peer_id
		sync_data.parent.position = position
		sync_data.parent.rotation = rotation
		sync_data.synced_values = initial_variables
		sync_data.is_pre_existing = false
		
		# Apply initial values
		_apply_variables_to_node(sync_data, initial_variables)
		return
	
	print(multiplayer.get_unique_id(), ": add_node ", node_name, " at path: ", parent_path)
	nodes.add_id(
		node_name,
		scene,
		parent_path,
		func(entity: Node) -> void:
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
			var sync_data = _sync_nodes[node_name]
			for key in new_variables:
				sync_data.synced_values[key] = new_variables[key]
			var sender_id = multiplayer.get_remote_sender_id()
			sync_variables(node_name, new_variables, false, sender_id)
	else:
		if _sync_nodes.has(node_name):
			var sync_data = _sync_nodes[node_name]
			_apply_variables_to_node(sync_data, new_variables)

func handle_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		if not _peer_nodes_observing.has(peer_id):
			_peer_nodes_observing[peer_id] = []
		
		print(multiplayer.get_unique_id(), ": Peer ", peer_id, " connected. Current nodes: ", _sync_nodes.keys())
		
		if owdb:
			call_deferred("_update_new_peer_visibility", peer_id)

func handle_peer_disconnected(peer_id: int) -> void:
	if multiplayer.is_server():
		unregister_peer_position(peer_id)
		
		var nodes_to_remove = []
		for node_name in _sync_nodes:
			var sync_data = _sync_nodes[node_name]
			if sync_data.peer_id == peer_id:
				nodes_to_remove.append(node_name)
		
		if _peer_nodes_observing.has(peer_id):
			_peer_nodes_observing.erase(peer_id)
		
		for node_name in nodes_to_remove:
			if _sync_nodes.has(node_name):
				var sync_data = _sync_nodes[node_name]
				unregister_node(sync_data.parent)
			nodes.remove(node_name)

# UPDATED: No longer automatically adds Sync component
func entity_sync_setup(node: Node, scene: String, position: Vector3, rotation: Vector3, peer_id: int, initial_variables: Dictionary) -> void:
	node.position = position
	node.rotation = rotation
	
	# Check if node already has a Sync component
	var sync_component = node.find_child("Sync")
	if sync_component:
		sync_component.peer_id = peer_id
		sync_component.synced_values = initial_variables
	
	# Register the node (whether it has Sync or not)
	#register_node(node, scene, peer_id, initial_variables, sync_component)
