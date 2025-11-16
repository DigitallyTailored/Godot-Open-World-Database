# src/ResourceManager.gd
# Manages resource serialization, registration, and restoration for the open world database
# Handles both file-based (.tres/.res) and built-in resources with content hashing
# Tracks resource references and handles cleanup of unused resources
# Input: Resource instances from node properties
# Output: Resource IDs for serialization, restored Resource objects
@tool
extends RefCounted
class_name ResourceManager

var owdb: OpenWorldDatabase
var resource_registry: Dictionary = {}
var content_hash_to_id: Dictionary = {}
var id_counter: int = 1

class ResourceInfo:
	var id: String
	var original_id: String
	var resource_type: String
	var content_hash: String
	var file_path: String
	var properties: Dictionary
	var reference_count: int = 0
	
	func _init(resource_id: String, type: String, hash: String):
		id = resource_id
		resource_type = type
		content_hash = hash

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database

func reset():
	resource_registry.clear()
	content_hash_to_id.clear()
	id_counter = 1

func register_resource(resource: Resource) -> String:
	if not resource:
		return ""
	
	if _is_standalone_file_resource(resource):
		return _register_file_resource(resource)
	
	return _register_builtin_resource(resource)

func _is_standalone_file_resource(resource: Resource) -> bool:
	var resource_path = resource.resource_path
	
	if resource_path == "":
		return false
	
	if "::" in resource_path:
		return false
	
	return resource_path.ends_with(".tres") or resource_path.ends_with(".res")

func _register_file_resource(resource: Resource) -> String:
	var file_path = resource.resource_path
	var resource_type = resource.get_class()
	
	var resource_id = "file:" + file_path
	
	if not resource_registry.has(resource_id):
		var info = ResourceInfo.new(resource_id, resource_type, "")
		info.original_id = _extract_original_id(resource)
		info.file_path = file_path
		resource_registry[resource_id] = info
		owdb.debug("Registered file resource: ", resource_id)
	
	resource_registry[resource_id].reference_count += 1
	return resource_id

func _register_builtin_resource(resource: Resource) -> String:
	var content_hash = _calculate_content_hash(resource)
	
	if content_hash_to_id.has(content_hash):
		var existing_id = content_hash_to_id[content_hash]
		resource_registry[existing_id].reference_count += 1
		owdb.debug("Reusing existing builtin resource: ", existing_id)
		return existing_id
	
	var original_id = _extract_original_id(resource)
	var resource_type = resource.get_class()
	var resource_id = original_id if original_id != "" else _generate_resource_id(resource_type)
	
	if original_id != "":
		resource_id = "<%s#%s>" % [resource_type, original_id]
	
	var info = ResourceInfo.new(resource_id, resource_type, content_hash)
	info.original_id = original_id
	info.properties = _extract_modified_properties(resource)
	info.reference_count = 1
	
	resource_registry[resource_id] = info
	content_hash_to_id[content_hash] = resource_id
	
	owdb.debug("Registered new builtin resource: ", resource_id + " (" + resource_type + ")")
	return resource_id

func _extract_original_id(resource: Resource) -> String:
	var resource_string = str(resource)
	var regex = RegEx.new()
	regex.compile(r"<.*#(-?\d+)>")
	var result = regex.search(resource_string)
	
	if result:
		return result.get_string(1)
	return ""

func _generate_resource_id(resource_type: String) -> String:
	var new_id = "<%s#%d>" % [resource_type, id_counter]
	id_counter += 1
	return new_id

func _calculate_content_hash(resource: Resource) -> String:
	var properties = _extract_modified_properties(resource)
	var content_string = resource.get_class() + JSON.stringify(properties)
	return content_string.sha256_text()

func _extract_modified_properties(resource: Resource) -> Dictionary:
	var properties = {}
	var baseline = _get_baseline_resource(resource.get_class())
	
	if not baseline:
		owdb.debug("Warning: No baseline available for resource type: ", resource.get_class())
		return properties
	
	for prop in resource.get_property_list():
		if prop.usage & PROPERTY_USAGE_STORAGE and not prop.name.begins_with("_"):
			var current_value = resource.get(prop.name)
			var baseline_value = baseline.get(prop.name)
			
			if not _values_equal(current_value, baseline_value):
				properties[prop.name] = _serialize_property_value(current_value)
	
	return properties

func _get_baseline_resource(resource_type: String) -> Resource:
	match resource_type:
		"SphereMesh": return SphereMesh.new()
		"BoxMesh": return BoxMesh.new()
		"CylinderMesh": return CylinderMesh.new()
		"PlaneMesh": return PlaneMesh.new()
		"QuadMesh": return QuadMesh.new()
		"CapsuleMesh": return CapsuleMesh.new()
		"PrismMesh": return PrismMesh.new()
		"TextMesh": return TextMesh.new()
		"TubeTrailMesh": return TubeTrailMesh.new()
		"RibbonTrailMesh": return RibbonTrailMesh.new()
		"StandardMaterial3D": return StandardMaterial3D.new()
		"ShaderMaterial": return ShaderMaterial.new()
		"Environment": return Environment.new()
		"World3D": return World3D.new()
		"PhysicsMaterial": return PhysicsMaterial.new()
		"ConvexPolygonShape3D": return ConvexPolygonShape3D.new()
		"ConcavePolygonShape3D": return ConcavePolygonShape3D.new()
		"BoxShape3D": return BoxShape3D.new()
		"SphereShape3D": return SphereShape3D.new()
		"CylinderShape3D": return CylinderShape3D.new()
		"CapsuleShape3D": return CapsuleShape3D.new()
		_:
			var instance = ClassDB.instantiate(resource_type) as Resource
			if not instance:
				owdb.debug("Failed to create baseline for resource type: ", resource_type)
			return instance

func _serialize_property_value(value) -> Variant:
	if value is Resource:
		return register_resource(value)
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

func restore_resource(resource_id: String) -> Resource:
	if not resource_registry.has(resource_id):
		owdb.debug("Resource not found in registry: ", resource_id)
		return null
	
	var info = resource_registry[resource_id]
	
	if info.file_path != "":
		return load(info.file_path)
	
	var resource = _get_baseline_resource(info.resource_type)
	if not resource:
		owdb.debug("Failed to create baseline resource: ", info.resource_type)
		return null
	
	for prop_name in info.properties:
		var value = _deserialize_property_value(info.properties[prop_name])
		if resource.has_method("set") and prop_name in resource:
			resource.set(prop_name, value)
	
	owdb.debug("Restored builtin resource: ", resource_id)
	return resource

func _deserialize_property_value(value) -> Variant:
	if value is String and value.begins_with("file:"):
		return load(value.substr(5))
	elif value is String and resource_registry.has(value):
		return restore_resource(value)
	elif value is Array:
		var deserialized_array = []
		for item in value:
			deserialized_array.append(_deserialize_property_value(item))
		return deserialized_array
	elif value is Dictionary:
		var deserialized_dict = {}
		for key in value:
			deserialized_dict[key] = _deserialize_property_value(value[key])
		return deserialized_dict
	else:
		return value

func cleanup_unused_resources():
	if not Engine.is_editor_hint():
		owdb.debug("Skipping resource cleanup - preserving database state in runtime")
		return
		
	var unused_ids = []
	
	for resource_id in resource_registry:
		var info = resource_registry[resource_id]
		if info.reference_count <= 0:
			unused_ids.append(resource_id)
	
	for resource_id in unused_ids:
		var info = resource_registry[resource_id]
		content_hash_to_id.erase(info.content_hash)
		resource_registry.erase(resource_id)
	
	if unused_ids.size() > 0:
		owdb.debug("Cleaned up unused resources: ", unused_ids.size())

func decrement_reference(resource_id: String):
	if resource_registry.has(resource_id):
		resource_registry[resource_id].reference_count -= 1

func serialize_resources() -> Dictionary:
	var serialized = {}
	for resource_id in resource_registry:
		var info = resource_registry[resource_id]
		serialized[resource_id] = {
			"type": info.resource_type,
			"original_id": info.original_id,
			"file_path": info.file_path,
			"properties": info.properties,
			"content_hash": info.content_hash
		}
	return serialized

func deserialize_resources(data: Dictionary):
	reset()
	
	for resource_id in data:
		var resource_data = data[resource_id]
		var info = ResourceInfo.new(resource_id, resource_data.type, resource_data.get("content_hash", ""))
		info.original_id = resource_data.get("original_id", "")
		info.file_path = resource_data.get("file_path", "")
		info.properties = resource_data.get("properties", {})
		
		resource_registry[resource_id] = info
		
		if info.content_hash != "":
			content_hash_to_id[info.content_hash] = resource_id
	
	var max_id = 0
	for resource_id in resource_registry:
		if resource_id.contains("#"):
			var parts = resource_id.split("#")
			if parts.size() == 2:
				var id_part = parts[1].trim_suffix(">")
				if id_part.is_valid_int():
					max_id = max(max_id, id_part.to_int())
	id_counter = max_id + 1

func get_registry_info() -> Dictionary:
	return {
		"total_resources": resource_registry.size(),
		"file_resources": resource_registry.values().filter(func(info): return info.file_path != "").size(),
		"builtin_resources": resource_registry.values().filter(func(info): return info.file_path == "").size(),
		"next_id": id_counter
	}
