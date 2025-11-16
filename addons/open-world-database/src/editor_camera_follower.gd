# src/editor/EditorCameraFollower.gd
@tool
extends RefCounted
class_name EditorCameraFollower

var owdb: OpenWorldDatabase
var _editor_camera_position: OWDBPosition = null
var _editor_camera: Camera3D = null

func _init(open_world_database: OpenWorldDatabase):
	owdb = open_world_database

func update_editor_camera_following(follow_enabled: bool):
	if follow_enabled and not _editor_camera_position:
		_create_editor_camera_position()
	elif not follow_enabled and _editor_camera_position:
		_remove_editor_camera_position()

func _get_editor_camera() -> Camera3D:
	if not Engine.is_editor_hint():
		return null
	
	var editor_viewport = EditorInterface.get_editor_viewport_3d(0)
	if editor_viewport:
		return editor_viewport.get_camera_3d()
	
	return null

func _create_editor_camera_position():
	if _editor_camera_position:
		return
	
	_editor_camera = _get_editor_camera()
	if not _editor_camera:
		owdb.debug("Could not find editor camera")
		return
	
	_editor_camera_position = OWDBPosition.new()
	_editor_camera_position.name = "EditorCameraPosition"
	
	# Add as child of the editor camera
	_editor_camera.add_child(_editor_camera_position)
	
	# Position at origin relative to camera (since it's a child, it will follow automatically)
	_editor_camera_position.position = Vector3.ZERO
	
	owdb.debug("Created editor camera OWDBPosition node under editor camera")

func _remove_editor_camera_position():
	if _editor_camera_position and is_instance_valid(_editor_camera_position):
		_editor_camera_position.queue_free()
		_editor_camera_position = null
		_editor_camera = null
		owdb.debug("Removed editor camera OWDBPosition node")

func cleanup():
	_remove_editor_camera_position()

func has_editor_camera_position() -> bool:
	return _editor_camera_position != null

func get_editor_camera_position() -> Vector3:
	if _editor_camera and is_instance_valid(_editor_camera):
		return _editor_camera.global_position
	return Vector3.ZERO
