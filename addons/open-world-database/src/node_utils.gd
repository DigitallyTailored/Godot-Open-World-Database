@tool
extends RefCounted
class_name NodeUtils

static func remove_children(node: Node):
	var children = node.get_children()
	for child in children:
		child.free()

# Generate sequential node names based on stored nodes array
static func generate_next_available_name(base_name: String, stored_nodes: Dictionary) -> String:
	# Extract the actual base name (remove any trailing numbers)
	var actual_base = _extract_base_name(base_name)
	
	# If the clean base name doesn't exist, use it directly
	if not _name_exists_in_stored_nodes(actual_base, stored_nodes):
		return actual_base
	
	# Find the highest existing number for this base name
	var highest_number = _find_highest_number_for_base(actual_base, stored_nodes)
	
	# Return the next available number
	return actual_base + str(highest_number + 1)

# Extract base name by removing trailing numbers
static func _extract_base_name(name: String) -> String:
	# Work backwards from the end to find where numbers start
	var i = name.length() - 1
	while i >= 0 and name[i].is_valid_int():
		i -= 1
	
	# If the entire string is numbers, return it as-is
	if i < 0:
		return name
	
	# Return everything up to where the numbers start
	return name.substr(0, i + 1)

# Find the highest number suffix for a given base name
static func _find_highest_number_for_base(base_name: String, stored_nodes: Dictionary) -> int:
	var highest = 0
	
	for uid in stored_nodes:
		var node_name = uid.split(OpenWorldDatabase.UID_SEPARATOR)[0] if OpenWorldDatabase.UID_SEPARATOR in uid else uid
		
		# Check if this node name starts with our base name
		if node_name.begins_with(base_name):
			var suffix = node_name.substr(base_name.length())
			
			# If there's no suffix, this is the base name (treat as number 1)
			if suffix == "":
				highest = max(highest, 1)
			# If suffix is all digits, it's a numbered variant
			elif suffix.is_valid_int():
				highest = max(highest, suffix.to_int())
	
	return highest

# Helper function to check if a name exists in stored nodes
static func _name_exists_in_stored_nodes(name: String, stored_nodes: Dictionary) -> bool:
	# Check by UID (which is the node name in your system)
	if stored_nodes.has(name):
		return true
	
	# Also check by extracting base names from UIDs (in case there are separators)
	for uid in stored_nodes:
		var node_name = uid.split(OpenWorldDatabase.UID_SEPARATOR)[0] if OpenWorldDatabase.UID_SEPARATOR in uid else uid
		if node_name == name:
			return true
	
	return false

static func get_valid_node_uid(node: Node) -> String:
	if not is_instance_valid(node) or not node.has_meta("_owd_uid"):
		return ""
	return node.get_meta("_owd_uid", "")

static func get_chunk_key(size: OpenWorldDatabase.Size, chunk_pos: Vector2i) -> Vector3:
	return Vector3(size, chunk_pos.x, chunk_pos.y)

static func get_chunk_position(position: Vector3, chunk_size: float) -> Vector2i:
	return Vector2i(int(position.x / chunk_size), int(position.z / chunk_size))

static func get_node_aabb(node: Node, exclude_top_level_transform: bool = true) -> AABB:
	var bounds: AABB = AABB()

	if node is VisualInstance3D:
		bounds = node.get_aabb()

	for child in node.get_children():
		var child_bounds: AABB = get_node_aabb(child, false)
		if bounds.size == Vector3.ZERO:
			bounds = child_bounds
		else:
			bounds = bounds.merge(child_bounds)

	if not exclude_top_level_transform and node is Node3D:
		bounds = node.transform * bounds

	return bounds

static func calculate_node_size(node: Node, force_recalculate: bool = false) -> float:
	if not node is Node3D:
		return 0.0
	
	var node_3d = node as Node3D
	
	if not force_recalculate and node_3d.has_meta("_owd_last_scale"):
		var meta = node_3d.get_meta("_owd_last_scale")
		if node_3d.scale == meta:
			return node_3d.get_meta("_owd_last_size")
	
	var aabb = get_node_aabb(node_3d, false)
	var size = aabb.size
	var max_size = max(size.x, max(size.y, size.z))
	
	node_3d.set_meta("_owd_last_scale", node_3d.scale)
	node_3d.set_meta("_owd_last_size", max_size)
	
	return max_size

static func get_storable_properties(node: Node) -> Array:
	return node.get_property_list().filter(func(prop): 
		return not prop.name.begins_with("_") and (prop.usage & PROPERTY_USAGE_STORAGE) and not prop.name in OpenWorldDatabase.SKIP_PROPERTIES
	)

static func values_equal(a, b) -> bool:
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

static func convert_property_value(stored_value: Variant, current_value: Variant) -> Variant:
	if typeof(stored_value) != TYPE_STRING:
		return stored_value
	
	var str_val = stored_value as String
	
	if current_value is Color:
		return parse_color(str_val)
	elif current_value is Vector2:
		return parse_vector2(str_val)
	elif current_value is Vector3:
		return parse_vector3(str_val)  
	elif current_value is Vector4:
		return parse_vector4(str_val)
	
	return stored_value

static func parse_vector_components(str_val: String, component_count: int) -> Array:
	var start = 1 if str_val.length() > 0 and str_val[0] == '(' else 0
	var end = str_val.length() - 1 if str_val.length() > 0 and str_val[-1] == ')' else str_val.length()
	var inner = str_val.substr(start, end - start)
	var parts = inner.split(",")
	
	var components = []
	for i in component_count:
		if i < parts.size():
			components.append(parts[i].strip_edges().to_float())
		else:
			components.append(0.0)
	return components

static func parse_vector2(str_val: String) -> Vector2:
	var components = parse_vector_components(str_val, 2)
	return Vector2(components[0], components[1])

static func parse_vector3(str_val: String) -> Vector3:
	var components = parse_vector_components(str_val, 3)
	return Vector3(components[0], components[1], components[2])

static func parse_vector4(str_val: String) -> Vector4:
	var components = parse_vector_components(str_val, 4)
	return Vector4(components[0], components[1], components[2], components[3])

static func parse_color(str_val: String) -> Color:
	var components = parse_vector_components(str_val, 4)
	if components.size() >= 3:
		var a = 1.0 if components.size() < 4 else components[3]
		return Color(components[0], components[1], components[2], a)
	return Color.WHITE

static func update_chunk_lookup_uid(chunk_lookup: Dictionary, old_uid: String, new_uid: String):
	for size in chunk_lookup:
		for chunk_pos in chunk_lookup[size]:
			var uid_list = chunk_lookup[size][chunk_pos]
			var old_index = uid_list.find(old_uid)
			if old_index >= 0:
				uid_list[old_index] = new_uid

static func update_parent_references(stored_nodes: Dictionary, old_uid: String, new_uid: String):
	for child_uid in stored_nodes:
		var child_info = stored_nodes[child_uid]
		if child_info.parent_uid == old_uid:
			child_info.parent_uid = new_uid
