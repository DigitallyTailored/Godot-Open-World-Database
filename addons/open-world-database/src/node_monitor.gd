#node_monitor.gd
@tool
extends RefCounted
class_name NodeMonitor

var owdb: OpenWorldDatabase
var stored_nodes: Dictionary = {} # uid -> node info
var baseline_values: Dictionary = {} # class_name -> {property_name -> default_value}

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database
	
	# Get baseline property values for all common node types
	var node_types = [
		Node.new(), Node3D.new(), Sprite3D.new(), MeshInstance3D.new(),
		MultiMeshInstance3D.new(), GPUParticles3D.new(), CPUParticles3D.new(),
		RigidBody3D.new(), StaticBody3D.new(), CharacterBody3D.new(),
		Area3D.new(), CollisionShape3D.new(), Camera3D.new(),
		DirectionalLight3D.new(), SpotLight3D.new(), OmniLight3D.new(),
		AudioStreamPlayer.new(), AudioStreamPlayer3D.new(),
		Path3D.new(), PathFollow3D.new(), NavigationAgent3D.new(),
	]
	
	for node in node_types:
		var class_name_ = node.get_class()
		baseline_values[class_name_] = {}
		
		for prop in node.get_property_list():
			if not prop.name.begins_with("_") and (prop.usage & PROPERTY_USAGE_STORAGE):
				baseline_values[class_name_][prop.name] = node.get(prop.name)
		
		node.free()

func create_node_info(node: Node, force_recalculate_size: bool = false) -> Dictionary:
	var info = {
		"uid": node.get_meta("_owd_uid", ""),
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
	
	var baseline = baseline_values.get(node.get_class(), {})
	
	var skip_properties = [
		"metadata/_owd_uid", "metadata/_owd_last_scale", "metadata/_owd_last_size",
		"script", "transform", "global_transform", "global_position", "global_rotation"
	]
	
	for prop in node.get_property_list():
		if prop.name.begins_with("_") or not (prop.usage & PROPERTY_USAGE_STORAGE):
			continue
			
		if prop.name in skip_properties:
			continue
		
		var current_value = node.get(prop.name)
		if not _values_equal(current_value, baseline.get(prop.name)):
			info.properties[prop.name] = current_value
	
	return info

func _values_equal(a, b) -> bool:
	if a == null and b == null:
		return true
	if a == null or b == null:
		return false
	
	if a == b:
		return true
	
	if a is float and b is float:
		return abs(a - b) < 0.0001
	
	if a is Vector2 and b is Vector2:
		return a.is_equal_approx(b)
	if a is Vector3 and b is Vector3:
		return a.is_equal_approx(b)
	if a is Vector4 and b is Vector4:
		return a.is_equal_approx(b)
	
	return false

func _get_node_source(node: Node) -> String:
	if node.scene_file_path != "":
		return node.scene_file_path
	return node.get_class()

func update_stored_node(node: Node, force_recalculate_size: bool = false):
	var uid = node.get_meta("_owd_uid", "")
	if uid:
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
