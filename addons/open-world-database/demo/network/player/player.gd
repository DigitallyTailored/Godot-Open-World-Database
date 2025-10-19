# Movement-based synchronization
# This player demonstrates selective sync - only send updates when meaningful changes occur  

# scenes/player/player.gd
extends CharacterBody3D

# Movement parameters
@export var speed = 20.0
@export var gravity = 9.8
@export var rotation_speed = 10.0

var position_old : Vector3

func _host_physics_process(delta):
		
	if not is_on_floor():
		velocity.y -= gravity * delta
	
	var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var direction = Vector3(input_dir.x, 0, input_dir.y).normalized()
	
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		var target_rotation = atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
	
	move_and_slide()

	if position.distance_squared_to(position_old) > 0.25:
		position_old = position
		$Sync.output(["position", "rotation.y"])
