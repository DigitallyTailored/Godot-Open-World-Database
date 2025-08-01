extends Camera3D

# Movement settings
@export var move_speed: float = 10.0
@export var sprint_speed: float = 20.0
@export var acceleration: float = 20.0
@export var friction: float = 10.0

# Mouse settings
@export var mouse_sensitivity: float = 0.003
@export var pitch_limit: float = 89.0  # Degrees

# Internal variables
var velocity: Vector3 = Vector3.ZERO
var camera_rotation: Vector2 = Vector2.ZERO
var is_sprinting: bool = false

func _ready() -> void:
	# Capture mouse when the game starts
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Initialize camera rotation from current rotation
	camera_rotation.x = rotation.y
	camera_rotation.y = rotation.x

func _input(event: InputEvent) -> void:
	# Handle mouse movement
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		# Rotate the camera based on mouse movement
		camera_rotation.x -= event.relative.x * mouse_sensitivity
		camera_rotation.y -= event.relative.y * mouse_sensitivity
		
		# Clamp vertical rotation to prevent flipping
		camera_rotation.y = clamp(camera_rotation.y, -deg_to_rad(pitch_limit), deg_to_rad(pitch_limit))
		
		# Apply rotation
		rotation.y = camera_rotation.x
		rotation.x = camera_rotation.y
	
	# Toggle mouse capture with ESC
	elif event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _process(delta: float) -> void:
	# Get input direction
	var input_vector: Vector2 = Vector2.ZERO
	
	# WASD and Arrow keys
	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		input_vector.y -= 1
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		input_vector.y += 1
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		input_vector.x -= 1
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		input_vector.x += 1
	
	# Normalize input vector to prevent faster diagonal movement
	input_vector = input_vector.normalized()
	
	# Check for sprint
	is_sprinting = Input.is_key_pressed(KEY_SHIFT)
	
	# Calculate movement direction relative to camera rotation
	var direction: Vector3 = Vector3.ZERO
	if input_vector.length() > 0:
		direction = (transform.basis * Vector3(input_vector.x, 0, input_vector.y)).normalized()
	
	# Apply acceleration or friction
	var current_speed: float = sprint_speed if is_sprinting else move_speed
	
	if direction.length() > 0:
		velocity = velocity.move_toward(direction * current_speed, acceleration * delta)
	else:
		velocity = velocity.move_toward(Vector3.ZERO, friction * delta)
	
	# Vertical movement (Q/E for up/down)
	if Input.is_key_pressed(KEY_Q):
		velocity.y = move_toward(velocity.y, current_speed, acceleration * delta)
	elif Input.is_key_pressed(KEY_E):
		velocity.y = move_toward(velocity.y, -current_speed, acceleration * delta)
	else:
		velocity.y = move_toward(velocity.y, 0, friction * delta)
	
	# Apply movement
	position += velocity * delta
