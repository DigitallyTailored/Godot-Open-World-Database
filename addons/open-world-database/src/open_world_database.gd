#open_world_database.gd
@tool
extends Node
class_name OpenWorldDatabase

enum Size { SMALL, MEDIUM, LARGE, ALWAYS_LOADED }


#@export_tool_button("Save World Database", "save") var save_action = save_database
@export var size_thresholds: Array[float] = [0.5, 2.0, 8.0]
@export var chunk_sizes: Array[float] = [8.0, 16.0, 64.0]
@export var chunk_load_range: int = 3
@export var debug_enabled: bool = false
@export var camera: Node

@export_tool_button("debug info", "Debug") var debug_action = debug

var chunk_lookup: Dictionary = {} # [Size][Vector2i] -> Array[String] (UIDs)
var database: Database
var chunk_manager: ChunkManager
var node_monitor: NodeMonitor
var is_loading: bool = false

func _ready() -> void:
	if Engine.is_editor_hint():
		get_tree().auto_accept_quit = false
	
	reset()
	is_loading = true
	database.load_database()
	chunk_manager._update_camera_chunks()
	is_loading = false
	
	if debug_enabled:
		debug()

func reset():
	is_loading = true
	NodeUtils.remove_children(self)
	chunk_manager = ChunkManager.new(self)
	node_monitor = NodeMonitor.new(self)
	database = Database.new(self)
	setup_listeners(self)
	is_loading = false

func setup_listeners(node: Node):
	if not node.child_entered_tree.is_connected(_on_child_entered_tree):
		node.child_entered_tree.connect(_on_child_entered_tree)
	
	if not node.child_exiting_tree.is_connected(_on_child_exiting_tree):
		node.child_exiting_tree.connect(_on_child_exiting_tree)

func _on_child_entered_tree(node: Node):
	if !self.is_ancestor_of(node): # ignore this node if not a child of owdb
		return
		
	if node.is_in_group("owdb_ignore"): # ignore scene child nodes
		return
	
	var children = node.get_children()
	for child in children:
		if !child.is_in_group("owdb"):
			child.add_to_group("owdb_ignore")
	
	# Setup listeners for this node after its children are added
	call_deferred("setup_listeners", node)
	
	if is_loading:
		node.add_to_group("owdb")
		return
	
	# Check if this is a move operation (node already in owdb group)
	if node.is_in_group("owdb"):
		if debug_enabled:
			print("NODE MOVED: ", node.name)
		# Update node monitor for moved nodes
		node_monitor.update_stored_node(node)
		# Update chunk lookup for moved nodes
		var uid = node.get_meta("_owd_uid", "")
		if uid != "":
			var node_size = NodeUtils.calculate_node_size(node)
			# Remove from old position and add to new position
			if node_monitor.stored_nodes.has(uid):
				var old_info = node_monitor.stored_nodes[uid]
				remove_from_chunk_lookup(uid, old_info.position, old_info.size)
			add_to_chunk_lookup(uid, node.global_position if node is Node3D else Vector3.ZERO, node_size)
		return
	
	# This is a new node being added
	node.add_to_group("owdb")
	if debug_enabled:
			print("NODE ADDED: ", node.name)
	
	# Only set UID if node doesn't have one
	if not node.has_meta("_owd_uid"):
		var uid = node.name + '-' + NodeUtils.generate_uid()
		node.set_meta("_owd_uid", uid)
		node.name = uid
	
	var uid = node.get_meta("_owd_uid")
	
	# Check if another node exists with this UID
	var existing_node = get_node_by_uid(uid)
	if existing_node != null and existing_node != node:
		# Generate a new UID for this node
		var new_uid = node.name.split('-')[0] + '-' + NodeUtils.generate_uid()
		node.set_meta("_owd_uid", new_uid)
		node.name = new_uid
		uid = new_uid
		
	# Update node monitor
	node_monitor.update_stored_node(node)
	
	# Add to chunk lookup
	var node_size = NodeUtils.calculate_node_size(node)
	add_to_chunk_lookup(uid, node.global_position if node is Node3D else Vector3.ZERO, node_size)
	
	if debug_enabled:
		print(get_tree().get_nodes_in_group("owdb"))

func _on_child_exiting_tree(node: Node):
	if is_loading:
		return
	
	if !node.is_in_group("owdb"):
		return
	
	# Use call_deferred to check if this is a move or actual removal
	call_deferred("_check_node_removal", node)

func _check_node_removal(node: Node):
	# If node is still valid and in tree, it was moved within the owdb tree
	if is_instance_valid(node) and node.is_inside_tree() and self.is_ancestor_of(node):
		# This was handled in _on_child_entered_tree as a move
		return
	
	# Node was actually removed from the owdb tree
	if debug_enabled:
		print("NODE REMOVED: ", node.name if is_instance_valid(node) else "Unknown")
	
	# Clean up stored data
	if is_instance_valid(node) and node.has_meta("_owd_uid"):
		var uid = node.get_meta("_owd_uid")
		if node_monitor.stored_nodes.has(uid):
			var node_info = node_monitor.stored_nodes[uid]
			# Remove from chunk lookup
			remove_from_chunk_lookup(uid, node_info.position, node_info.size)
			# Remove from stored nodes
			node_monitor.stored_nodes.erase(uid)
			
			if debug_enabled:
				print("Removed node from storage: ", uid)
	
	# Remove from owdb group so if it's re-added later, it's treated as a new addition
	if is_instance_valid(node) and node.is_in_group("owdb"):
		node.remove_from_group("owdb")

func handle_node_rename(node: Node) -> bool:
	if not node.has_meta("_owd_uid"):
		return false
	
	var old_uid = node.get_meta("_owd_uid")
	var new_name = node.name
	
	# Check if name is different from uid
	if old_uid == new_name:
		return false
	
	# Update node metadata
	node.set_meta("_owd_uid", new_name)
	
	# Update stored nodes dictionary
	if node_monitor.stored_nodes.has(old_uid):
		var node_info = node_monitor.stored_nodes[old_uid]
		node_info.uid = new_name
		node_monitor.stored_nodes[new_name] = node_info
		node_monitor.stored_nodes.erase(old_uid)
	
	# Update chunk lookup
	for size in chunk_lookup:
		for chunk_pos in chunk_lookup[size]:
			var uid_list = chunk_lookup[size][chunk_pos]
			var old_index = uid_list.find(old_uid)
			if old_index >= 0:
				uid_list[old_index] = new_name
	
	# Update parent references in children
	for child_uid in node_monitor.stored_nodes:
		var child_info = node_monitor.stored_nodes[child_uid]
		if child_info.parent_uid == old_uid:
			child_info.parent_uid = new_name
	
	return true

func get_all_owd_nodes() -> Array[Node]:
	return get_tree().get_nodes_in_group("owdb")

func get_node_by_uid(uid: String) -> Node:
	# Search through owdb group nodes for matching UID
	var owdb_nodes = get_tree().get_nodes_in_group("owdb")
	for node in owdb_nodes:
		if node.has_meta("_owd_uid") and node.get_meta("_owd_uid") == uid:
			return node
	return null

func add_to_chunk_lookup(uid: String, position: Vector3, size: float):
	var size_cat = get_size_category(size)
	var chunk_pos = get_chunk_position(position, size_cat)
	
	if not chunk_lookup.has(size_cat):
		chunk_lookup[size_cat] = {}
	if not chunk_lookup[size_cat].has(chunk_pos):
		chunk_lookup[size_cat][chunk_pos] = []
	
	if uid not in chunk_lookup[size_cat][chunk_pos]:
		chunk_lookup[size_cat][chunk_pos].append(uid)

func remove_from_chunk_lookup(uid: String, position: Vector3, size: float):
	var size_cat = get_size_category(size)
	var chunk_pos = get_chunk_position(position, size_cat)
	
	if chunk_lookup.has(size_cat) and chunk_lookup[size_cat].has(chunk_pos):
		chunk_lookup[size_cat][chunk_pos].erase(uid)
		if chunk_lookup[size_cat][chunk_pos].is_empty():
			chunk_lookup[size_cat].erase(chunk_pos)

func get_size_category(node_size: float) -> Size:
	# Always load nodes with size 0.0 or bigger than LARGE threshold
	if node_size == 0.0 or node_size > size_thresholds[Size.LARGE]:
		return Size.ALWAYS_LOADED
	
	for i in range(size_thresholds.size()):
		if node_size <= size_thresholds[i]:
			return i
	
	# Should never reach here, but fallback to ALWAYS_LOADED
	return Size.ALWAYS_LOADED

func get_chunk_position(position: Vector3, size_category: Size) -> Vector2i:
	# Always loaded nodes go to a single chunk
	if size_category == Size.ALWAYS_LOADED:
		return Vector2i(0, 0)
	
	var chunk_size = chunk_sizes[size_category]
	return Vector2i(int(position.x / chunk_size), int(position.z / chunk_size))

func _process(_delta: float) -> void:
	if chunk_manager and not is_loading:
		chunk_manager._update_camera_chunks()

func debug():
	var owdb_nodes = get_all_owd_nodes()
	print("OWDB nodes loaded: ", owdb_nodes.size())
	for node in owdb_nodes:
		print("  - ", node.get_meta("_owd_uid", "NO_UID"), " : ", node.name)
	database.debug()
	
func save_database():
	database.save_database()

func _notification(what: int) -> void:
	if Engine.is_editor_hint():
		if what == NOTIFICATION_EDITOR_PRE_SAVE:
			save_database()
