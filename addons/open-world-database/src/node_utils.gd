#utils/node_utils.gd
@tool
extends RefCounted
class_name NodeUtils

static func remove_children(node:Node):
	var children = node.get_children()
	for child in children:
		child.free()

static func generate_uid() -> String:
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	return str(Time.get_unix_time_from_system()).replace(".", "")+ "_" + str(rng.randi_range(1000,9999))

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
	# Non-3D nodes have no size
	if not node is Node3D:
		return 0.0
	
	var node_3d = node as Node3D
	
	# Check if we have cached values (unless forcing recalculation)
	if not force_recalculate and node_3d.has_meta("_owd_last_scale"):
		# If scale hasn't changed, return cached size
		var meta = node_3d.get_meta("_owd_last_scale")
		if node_3d.scale == meta:
			return node_3d.get_meta("_owd_last_size")
	
	# Calculate new size
	var aabb = get_node_aabb(node_3d, false)
	var size = aabb.size
	var max_size = max(size.x, max(size.y, size.z))
	
	# Cache the scale and size
	node_3d.set_meta("_owd_last_scale", node_3d.scale)
	node_3d.set_meta("_owd_last_size", max_size)
	
	return max_size

static func is_top_level_node(node: Node) -> bool:
	var parent_node = node.get_parent()
	return not (parent_node and parent_node.has_meta("_owd_uid"))

static func convert_property_value(stored_value: Variant, current_value: Variant) -> Variant:
	# If it's not a string, return as-is (already correct type)
	if typeof(stored_value) != TYPE_STRING:
		return stored_value
	
	var str_val = stored_value as String
	
	# Handle Color - most common case
	if current_value is Color:
		return _parse_color_fast(str_val)
	
	# Handle Vectors
	if current_value is Vector2:
		return _parse_vector2_fast(str_val)
	elif current_value is Vector3:
		return _parse_vector3_fast(str_val)
	elif current_value is Vector4:
		return _parse_vector4_fast(str_val)
	
	# For everything else, return the stored value as-is
	return stored_value

static func _parse_color_fast(str_val: String) -> Color:
	# Fast parsing for "(r, g, b, a)" format
	if str_val.length() < 7:  # Minimum: "(0,0,0)"
		return Color.WHITE
	
	var start = 1 if str_val[0] == '(' else 0
	var end = str_val.length() - 1 if str_val[-1] == ')' else str_val.length()
	var inner = str_val.substr(start, end - start)
	var parts = inner.split(",")
	
	if parts.size() >= 3:
		var r = parts[0].strip_edges().to_float()
		var g = parts[1].strip_edges().to_float()
		var b = parts[2].strip_edges().to_float()
		var a = 1.0 if parts.size() < 4 else parts[3].strip_edges().to_float()
		return Color(r, g, b, a)
	
	return Color.WHITE

static func _parse_vector2_fast(str_val: String) -> Vector2:
	var start = 1 if str_val[0] == '(' else 0
	var end = str_val.length() - 1 if str_val[-1] == ')' else str_val.length()
	var inner = str_val.substr(start, end - start)
	var parts = inner.split(",")
	
	if parts.size() >= 2:
		return Vector2(parts[0].strip_edges().to_float(), parts[1].strip_edges().to_float())
	return Vector2.ZERO

static func _parse_vector3_fast(str_val: String) -> Vector3:
	var start = 1 if str_val[0] == '(' else 0
	var end = str_val.length() - 1 if str_val[-1] == ')' else str_val.length()
	var inner = str_val.substr(start, end - start)
	var parts = inner.split(",")
	
	if parts.size() >= 3:
		return Vector3(
			parts[0].strip_edges().to_float(),
			parts[1].strip_edges().to_float(),
			parts[2].strip_edges().to_float()
		)
	return Vector3.ZERO

static func _parse_vector4_fast(str_val: String) -> Vector4:
	var start = 1 if str_val[0] == '(' else 0
	var end = str_val.length() - 1 if str_val[-1] == ')' else str_val.length()
	var inner = str_val.substr(start, end - start)
	var parts = inner.split(",")
	
	if parts.size() >= 4:
		return Vector4(
			parts[0].strip_edges().to_float(),
			parts[1].strip_edges().to_float(),
			parts[2].strip_edges().to_float(),
			parts[3].strip_edges().to_float()
		)
	return Vector4.ZERO
