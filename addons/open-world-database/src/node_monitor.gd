@tool
extends RefCounted
class_name NodeMonitor

var owdb: OpenWorldDatabase
var stored_nodes: Dictionary = {} # uid -> node info
var baseline_values: Dictionary = {} # class_name -> {property_name -> default_value}
var resource_manager: ResourceManager

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database
	resource_manager = ResourceManager.new(owdb)
	_initialize_baseline_values()

# UPDATED: Don't reset resource manager here - only reset when specifically needed
func reset():
	# Don't reset resource_manager here - it should persist during normal operation
	pass

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
			# Use resource manager for resource properties
			var serialized_value = _serialize_property_value(current_value)
			modified_properties[prop_name] = serialized_value
			owdb.debug("Serialized property '" + prop_name + "' as: ", serialized_value)
	
	return modified_properties

func _serialize_property_value(value) -> Variant:
	if value is Resource:
		var resource_id = resource_manager.register_resource(value)
		owdb.debug("Registered resource with ID: ", resource_id)
		return resource_id
	elif value is Array:
		var serialized_array = []
		for item in value:
			serialized_array.append(_serialize_property_value(item))
		return serialized_array
	elif value is Dictionary:
		var serialized_dict = {}
		for key in value:
			serialized_dict[key] = _serialize_property_value(value[key])
		return serialized_dict
	else:
		return value

# Apply properties during node restoration
func apply_stored_properties(node: Node, properties: Dictionary):
	owdb.debug("=== APPLYING PROPERTIES ===")
	owdb.debug("Target node: ", node.name, " (", node.get_class(), ")")
	owdb.debug("Properties to apply: ", properties)
	owdb.debug("===============================")
	
	for prop_name in properties:
		if prop_name not in ["position", "rotation", "scale", "size"]:
			if node.has_method("set") and prop_name in node:
				var stored_value = properties[prop_name]
				var current_value = node.get(prop_name)
				
				owdb.debug("Processing property '", prop_name, "' with stored value: ", stored_value, " (type: ", typeof(stored_value), ")")
				
				var converted_value = _deserialize_property_value(stored_value, current_value)
				
				owdb.debug("Converted value: ", converted_value, " (type: ", typeof(converted_value), ")")
				
				node.set(prop_name, converted_value)
				owdb.debug("Applied property '", prop_name, "' to node: ", node.name)


func _deserialize_property_value(stored_value, current_value) -> Variant:
	# Handle resource references
	if stored_value is String and resource_manager.resource_registry.has(stored_value):
		var restored_resource = resource_manager.restore_resource(stored_value)
		owdb.debug("Restored resource: ", stored_value)
		return restored_resource
	elif stored_value is Array:
		var deserialized_array = []
		var current_array = current_value if current_value is Array else []
		for i in range(stored_value.size()):
			var current_item = current_array[i] if i < current_array.size() else null
			deserialized_array.append(_deserialize_property_value(stored_value[i], current_item))
		return deserialized_array
	elif stored_value is Dictionary:
		var deserialized_dict = {}
		var current_dict = current_value if current_value is Dictionary else {}
		for key in stored_value:
			var current_item = current_dict.get(key)
			deserialized_dict[key] = _deserialize_property_value(stored_value[key], current_item)
		return deserialized_dict
	else:
		# Use existing conversion for non-resource properties
		return NodeUtils.convert_property_value(stored_value, current_value)

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

# Clean up resource references when nodes are removed
func remove_node_resources(uid: String):
	if not stored_nodes.has(uid):
		return
	
	var node_info = stored_nodes[uid]
	_cleanup_property_resources(node_info.properties)

func _cleanup_property_resources(properties: Dictionary):
	for prop_name in properties:
		var value = properties[prop_name]
		_decrement_resource_references(value)

func _decrement_resource_references(value):
	if value is String and resource_manager.resource_registry.has(value):
		resource_manager.decrement_reference(value)
	elif value is Array:
		for item in value:
			_decrement_resource_references(item)
	elif value is Dictionary:
		for key in value:
			_decrement_resource_references(value[key])
