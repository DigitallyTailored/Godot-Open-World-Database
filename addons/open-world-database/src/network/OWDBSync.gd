# src/network/OWDBSync.gd
extends Node
class_name OWDBSync

signal input(variables)

@export var autowatch_parent_variables : Array[String]
@export var autowatch_interval_ms : int = 100

var peer_id := 1
var parent_scene := ""
var parent_name := ""
var parent_path := ""
var parent : Node3D
var is_pre_existing := false

var watched_variables := []
var synced_values := {}
var previous_values := {}
var interval := 100
var watch_timer : Timer

var property_getters := {}
var property_setters := {}

var throttled_last_send := {}

var owdb: OpenWorldDatabase = null

func _get_syncer():
	"""Get the Syncer instance from parent OWDB"""
	if not owdb:
		owdb = _find_owdb()
	
	if owdb and owdb.syncer and is_instance_valid(owdb.syncer):
		return owdb.syncer
	
	return null

func _find_owdb() -> OpenWorldDatabase:
	var results = get_tree().current_scene.find_children("*", "OpenWorldDatabase", true, false)
	return results[0] if results.size() > 0 else null

func _ready():
	parent = get_parent()
	parent_scene = parent.scene_file_path
	parent_name = parent.name
	
	parent_path = _get_parent_path()
	is_pre_existing = _check_if_pre_existing()
	
	var syncer = _get_syncer()
	if syncer:
		syncer.register_node(parent, parent_scene, peer_id, synced_values, self)
		
	if not parent.has_method("_host_process"):
		set_process(false)
	if not parent.has_method("_host_physics_process"):
		set_physics_process(false)
	
	if not autowatch_parent_variables.is_empty():
		set_interval(autowatch_interval_ms)
		watch(autowatch_parent_variables)

func _build_property_cache():
	property_getters.clear()
	property_setters.clear()
	
	for var_name in watched_variables:
		match var_name:
			"rotation.y":
				property_getters[var_name] = func(): return parent.rotation.y
				property_setters[var_name] = func(value): parent.rotation = Vector3(parent.rotation.x, value, parent.rotation.z)
			"rotation.x":
				property_getters[var_name] = func(): return parent.rotation.x
				property_setters[var_name] = func(value): parent.rotation = Vector3(value, parent.rotation.y, parent.rotation.z)
			"rotation.z":
				property_getters[var_name] = func(): return parent.rotation.z
				property_setters[var_name] = func(value): parent.rotation = Vector3(parent.rotation.x, parent.rotation.y, value)
			"position.x":
				property_getters[var_name] = func(): return parent.position.x
				property_setters[var_name] = func(value): parent.position = Vector3(value, parent.position.y, parent.position.z)
			"position.y":
				property_getters[var_name] = func(): return parent.position.y
				property_setters[var_name] = func(value): parent.position = Vector3(parent.position.x, value, parent.position.z)
			"position.z":
				property_getters[var_name] = func(): return parent.position.z
				property_setters[var_name] = func(value): parent.position = Vector3(parent.position.x, parent.position.y, value)
			"scale.x":
				property_getters[var_name] = func(): return parent.scale.x
				property_setters[var_name] = func(value): parent.scale = Vector3(value, parent.scale.y, parent.scale.z)
			"scale.y":
				property_getters[var_name] = func(): return parent.scale.y
				property_setters[var_name] = func(value): parent.scale = Vector3(parent.scale.x, value, parent.scale.z)
			"scale.z":
				property_getters[var_name] = func(): return parent.scale.z
				property_setters[var_name] = func(value): parent.scale = Vector3(parent.scale.x, parent.scale.y, value)
			"position":
				property_getters[var_name] = func(): return parent.position
				property_setters[var_name] = func(value): parent.position = value
			"rotation":
				property_getters[var_name] = func(): return parent.rotation
				property_setters[var_name] = func(value): parent.rotation = value
			"scale":
				property_getters[var_name] = func(): return parent.scale
				property_setters[var_name] = func(value): parent.scale = value
			_:
				property_getters[var_name] = func(): return parent.get(var_name)
				property_setters[var_name] = func(value): parent.set(var_name, value)

func _get_special_property_value(var_name: String):
	if property_getters.has(var_name):
		return property_getters[var_name].call()
	
	match var_name:
		"rotation.y": return parent.rotation.y
		"rotation.x": return parent.rotation.x
		"rotation.z": return parent.rotation.z
		"position.x": return parent.position.x
		"position.y": return parent.position.y
		"position.z": return parent.position.z
		"scale.x": return parent.scale.x
		"scale.y": return parent.scale.y
		"scale.z": return parent.scale.z
		"position": return parent.position
		"rotation": return parent.rotation
		"scale": return parent.scale
		_: return parent.get(var_name)

func _set_special_property_value(var_name: String, value):
	if property_setters.has(var_name):
		property_setters[var_name].call(value)
	else:
		match var_name:
			"rotation.y": parent.rotation = Vector3(parent.rotation.x, value, parent.rotation.z)
			"rotation.x": parent.rotation = Vector3(value, parent.rotation.y, parent.rotation.z)
			"rotation.z": parent.rotation = Vector3(parent.rotation.x, parent.rotation.y, value)
			"position.x": parent.position = Vector3(value, parent.position.y, parent.position.z)
			"position.y": parent.position = Vector3(parent.position.x, value, parent.position.z)
			"position.z": parent.position = Vector3(parent.position.x, parent.position.y, value)
			"scale.x": parent.scale = Vector3(value, parent.scale.y, parent.scale.z)
			"scale.y": parent.scale = Vector3(parent.scale.x, value, parent.scale.z)
			"scale.z": parent.scale = Vector3(parent.scale.x, parent.scale.y, value)
			_: parent.set(var_name, value)

func properties(property_name: String, default_value = null):
	return synced_values.get(property_name, default_value)

func apply_initial_values(initial_values: Dictionary):
	var converted_values = _convert_short_keys_to_properties(initial_values)
	
	for var_name in converted_values:
		_set_special_property_value(var_name, converted_values[var_name])
		synced_values[var_name] = converted_values[var_name]
	
	if not converted_values.is_empty():
		emit_signal_recieved_data(converted_values)

func watch(variable_names: Array) -> void:
	watched_variables = variable_names
	_build_property_cache()
	_initialize_previous_values()
	
	for var_name in watched_variables:
		var current_value = _get_special_property_value(var_name)
		if current_value != null:
			synced_values[var_name] = current_value
	
	if not watched_variables.is_empty():
		if watch_timer:
			watch_timer.queue_free()
		watch_timer = Timer.new()
		watch_timer.wait_time = interval / 1000.0
		watch_timer.timeout.connect(_check_watched_variables)
		add_child(watch_timer)
		watch_timer.start()

func set_interval(ms: int) -> void:
	interval = ms
	if watch_timer:
		watch_timer.wait_time = ms / 1000.0

func _initialize_previous_values() -> void:
	previous_values.clear()
	for var_name in watched_variables:
		var current_value = _get_special_property_value(var_name)
		if current_value != null:
			if current_value is Dictionary:
				previous_values[var_name] = current_value.hash()
			else:
				previous_values[var_name] = current_value

func _convert_properties_to_short_keys(data: Dictionary) -> Dictionary:
	var syncer = _get_syncer()
	if not syncer:
		return data
	
	var converted = {}
	for key in data:
		if syncer.transform_mappings.has(key):
			converted[syncer.transform_mappings[key]] = data[key]
		else:
			converted[key] = data[key]
	return converted

func _convert_short_keys_to_properties(data: Dictionary) -> Dictionary:
	var syncer = _get_syncer()
	if not syncer:
		return data
	
	var converted = {}
	for key in data:
		if syncer.reverse_mappings.has(key):
			converted[syncer.reverse_mappings[key]] = data[key]
		else:
			converted[key] = data[key]
	return converted

func _check_watched_variables() -> void:
	if !is_this_peer():
		return
		
	var changes = {}
	var has_changes = false
	
	for var_name in watched_variables:
		var current_value = _get_special_property_value(var_name)
		
		if current_value == null:
			continue
			
		var previous_value = previous_values.get(var_name)
		var value_changed = false
		
		if current_value is Dictionary:
			var current_hash = current_value.hash()
			if previous_value != current_hash:
				previous_values[var_name] = current_hash
				changes[var_name] = current_value
				value_changed = true
		elif current_value is Vector3:
			if previous_value == null or not current_value.is_equal_approx(previous_value):
				previous_values[var_name] = current_value
				changes[var_name] = current_value
				value_changed = true
		elif current_value is float:
			if previous_value == null or not is_equal_approx(current_value, previous_value):
				previous_values[var_name] = current_value
				changes[var_name] = current_value
				value_changed = true
		else:
			if previous_value != current_value:
				previous_values[var_name] = current_value
				changes[var_name] = current_value
				value_changed = true
		
		if value_changed:
			has_changes = true
	
	if has_changes:
		var converted_changes = _convert_properties_to_short_keys(changes)
		output(converted_changes)

func _check_if_pre_existing() -> bool:
	if not multiplayer or not multiplayer.has_multiplayer_peer():
		return true
	
	var syncer = _get_syncer()
	if not syncer:
		return true
	
	return not syncer.loaded_nodes.has(parent_name)

func _get_parent_path() -> String:
	var current_parent = parent.get_parent()
	if current_parent == get_node("/root"):
		return ""
	return current_parent.get_path()

func _process(delta: float) -> void:
	if is_this_peer():
		parent._host_process(delta)

func _physics_process(delta: float) -> void:
	if is_this_peer():
		parent._host_physics_process(delta)

func is_this_peer() -> bool:
	return peer_id == multiplayer.get_unique_id()

func output(variables_in) -> void:
	var syncer = _get_syncer()
	if not syncer:
		return
	
	var sync_data = {}
	
	if variables_in is Array:
		for var_name in variables_in:
			var current_value = _get_special_property_value(var_name)
			if current_value != null:
				sync_data[var_name] = current_value
				synced_values[var_name] = current_value
		sync_data = _convert_properties_to_short_keys(sync_data)
	elif variables_in is Dictionary:
		sync_data = variables_in
		for key in variables_in:
			synced_values[key] = variables_in[key]
	
	if not sync_data.is_empty():
		syncer.sync_variables(parent_name, sync_data, false)

func output_timed(variables_in, custom_interval: int = -1) -> void:
	var interval_to_use = custom_interval if custom_interval > 0 else interval
	var current_time = Time.get_ticks_msec()
	var key = str(variables_in) if variables_in is Array else str(variables_in.keys())
	var last_send_time = throttled_last_send.get(key, 0)
	
	if current_time - last_send_time >= interval_to_use:
		output(variables_in)
		throttled_last_send[key] = current_time

func variables_receive(variables_in: Dictionary) -> void:
	var converted_variables = _convert_short_keys_to_properties(variables_in)
	
	for key in converted_variables:
		synced_values[key] = converted_variables[key]
	
	emit_signal_recieved_data(converted_variables)
	
	for key in converted_variables:
		_set_special_property_value(key, converted_variables[key])

func emit_signal_recieved_data(variables_in: Dictionary) -> void:
	input.emit(variables_in)

func _exit_tree() -> void:
	if watch_timer:
		watch_timer.queue_free()
