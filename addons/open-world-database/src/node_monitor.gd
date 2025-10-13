@tool
extends RefCounted
class_name NodeMonitor

var owdb: OpenWorldDatabase
var stored_nodes: Dictionary = {} # uid -> node info
var baseline_values: Dictionary = {} # class_name -> {property_name -> default_value}

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database
	_initialize_baseline_values()

func _initialize_baseline_values():
	var node_types = [
		Node.new(), Node3D.new(), Sprite3D.new(), MeshInstance3D.new(),
		MultiMeshInstance3D.new(), GPUParticles3D.new(), CPUParticles3D.new(),
		RigidBody3D.new(), StaticBody3D.new(), CharacterBody3D.new(),
		Area3D.new(), CollisionShape3D.new(), Camera3D.new(),
		DirectionalLight3D.new(), SpotLight3D.new(), OmniLight3D.new(),
		AudioStreamPlayer.new(), AudioStreamPlayer3D.new(),
		Path3D.new(), PathFollow3D.new(), NavigationAgent3D.new(),
		CSGBox3D.new(), CSGCombiner3D.new(), CSGCylinder3D.new(), CSGMesh3D.new(),CSGPolygon3D.new()
	]
	
	for node in node_types:
		var class_name_ = node.get_class()
		baseline_values[class_name_] = {}
		
		for prop in NodeUtils.get_storable_properties(node):
			baseline_values[class_name_][prop.name] = node.get(prop.name)
		
		node.free()

func create_node_info(node: Node, force_recalculate_size: bool = false) -> Dictionary:
	var uid = NodeUtils.get_valid_node_uid(node)
	var info = {
		"uid": uid,
		"scene": _get_node_source(node),
		"position": Vector3.ZERO,
		"rotation": Vector3.ZERO,
		"scale": Vector3.ONE,
		"size": NodeUtils.calculate_node_size(node, force_recalculate_size),
		"parent_uid": "",
		"properties": {}
	}
	
	if node is Node3D:
		info.position = node.global_position
		info.rotation = node.global_rotation
		info.scale = node.scale
	
	var parent = node.get_parent()
	if parent and parent.has_meta("_owd_uid"):
		info.parent_uid = parent.get_meta("_owd_uid")
	
	info.properties = _get_modified_properties(node)
	
	return info

func _get_modified_properties(node: Node) -> Dictionary:
	var baseline = baseline_values.get(node.get_class(), {})
	var modified_properties = {}
	
	for prop in NodeUtils.get_storable_properties(node):
		var prop_name = prop.name
		var current_value = node.get(prop_name)
		
		if not NodeUtils.values_equal(current_value, baseline.get(prop_name)):
			modified_properties[prop_name] = current_value
	
	return modified_properties

func _get_node_source(node: Node) -> String:
	if node.scene_file_path != "":
		return node.scene_file_path
	return node.get_class()

func update_stored_node(node: Node, force_recalculate_size: bool = false):
	var uid = NodeUtils.get_valid_node_uid(node)
	if uid != "":
		stored_nodes[uid] = create_node_info(node, force_recalculate_size)

func store_node_hierarchy(node: Node):
	update_stored_node(node)
	for child in node.get_children():
		if child.has_meta("_owd_uid"):
			store_node_hierarchy(child)

func get_nodes_for_chunk(size: OpenWorldDatabase.Size, chunk_pos: Vector2i) -> Array:
	var nodes = []
	if owdb.chunk_lookup.has(size) and owdb.chunk_lookup[size].has(chunk_pos):
		for uid in owdb.chunk_lookup[size][chunk_pos]:
			if stored_nodes.has(uid):
				nodes.append(stored_nodes[uid])
	return nodes
