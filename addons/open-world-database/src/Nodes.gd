extends Node
class_name Nodes

signal batch_completed(count)
signal all_entities_loaded
signal batch_removed(count) 
signal all_entities_removed

var _loaded := {}
var _free_node_name = 1
var tree : SceneTree
var parent : Node
var batch_processor: BatchProcessor

func get_loaded() -> Dictionary:
	return _loaded

func _init(parent_in) -> void:
	parent = parent_in
	tree = parent.get_tree()
	
	# Create batch processor with parent reference
	batch_processor = BatchProcessor.new(null, parent)
	batch_processor.batch_time_limit_ms = 10.0
	batch_processor.batch_interval_ms = 50.0
	batch_processor.batch_processing_enabled = true
	
	# Setup manually since we don't have OWDB
	batch_processor.setup()
	
	# Connect to batch completion
	batch_processor.add_batch_complete_callback(_on_batch_complete)

func add(entity_path: String, parent_path: String = "", callback: Callable = Callable()) -> String:
	var node_name = entity_path.get_basename().get_file() + str(_free_node_name)
	_free_node_name += 1
	
	return add_id(node_name, entity_path, parent_path, callback)

func add_id(node_name: String, entity_path: String, parent_path = "", callback: Callable = Callable()) -> String:
	batch_processor.instantiate_scene(entity_path, node_name, parent_path, callback)
	return node_name

func remove(node_name: String) -> void:
	batch_processor.remove_scene_node(node_name)
	_loaded.erase(node_name)

func get_node_by_name(node_name: String) -> Node:
	if _loaded.has(node_name):
		return _loaded[node_name]
	
	if tree.current_scene.has_node(node_name):
		return tree.current_scene.get_node(node_name)
	
	return get_node("/root").find_child(node_name, true, false)

func _on_batch_complete():
	# Update loaded registry - scan for new nodes
	var current_nodes = {}
	_scan_for_loaded_nodes(tree.current_scene, current_nodes)
	
	# Compare with previous state to detect changes
	var newly_loaded = []
	var newly_removed = []
	
	for node_name in current_nodes:
		if not _loaded.has(node_name):
			newly_loaded.append(node_name)
	
	for node_name in _loaded:
		if not current_nodes.has(node_name):
			newly_removed.append(node_name)
	
	_loaded = current_nodes
	
	if newly_loaded.size() > 0:
		batch_completed.emit(newly_loaded.size())
	
	if newly_removed.size() > 0:
		batch_removed.emit(newly_removed.size())

func _scan_for_loaded_nodes(node: Node, registry: Dictionary):
	# Only count nodes that look like they were instantiated by us
	if node != tree.current_scene and node.name.contains(str(_free_node_name - 1).substr(0, 3)):
		registry[node.name] = node
	
	for child in node.get_children():
		_scan_for_loaded_nodes(child, registry)

func random_string(length: int = 3) -> String:
	var characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	var result = ""
	
	for i in range(length):
		var random_index = randi() % characters.length()
		result += characters[random_index]
	
	return result
