@tool
extends Area3D

@export var color : Color = Color.WHITE

var mesh_instance : MeshInstance3D

func _ready() -> void:
	mesh_instance = get_child(0)
	
	if color != Color.WHITE:
		var material : StandardMaterial3D = mesh_instance.get_surface_override_material(0).duplicate()
		material.albedo_color = color
		mesh_instance.set_surface_override_material(0, material)
		
	# Connect the body_entered signal
	body_entered.connect(_on_body_entered)
	
	# Simple rotation animation
	var tween = create_tween()
	tween.set_loops()
	tween.tween_property(mesh_instance, "rotation_degrees", Vector3(0,360,0), 2.0).from(Vector3.ZERO)
	
func _on_body_entered(body):
	if body.has_method("collect_gem"):
		body.collect_gem()
		queue_free()
