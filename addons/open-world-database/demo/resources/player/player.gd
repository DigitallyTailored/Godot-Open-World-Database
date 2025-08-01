# Player.gd
extends CharacterBody3D

@export var speed = 5.0
@export var jump_velocity = 4.5
@export var mouse_sensitivity = 0.002
var camera_distance
var camera_height
@export var max_health = 100
@export var attack_damage = 25
@export var attack_range = 2.0
var knockback_force = 6.0  # New knockback parameter
@export var block_knockback_force = 4.0  # Reduced knockback when blocking

var health: int
var gems_collected = 0
var target_gems = 1
var is_attacking = false
var is_blocking = false

# Knockback variables
var knockback_velocity = Vector3.ZERO
var knockback_decay = 10.0  # How fast knockback decays

# Track enemies in range
var enemies_in_range = []

# Camera rotation variables
var camera_rotation_h = 0.0
var camera_rotation_v = 0.0
var min_camera_angle = -80.0
var max_camera_angle = 80.0

# Facial expression variables
var current_expression = ":)"

# Animation state tracking
var current_state = "idle"
var previous_state = "idle"

@onready var camera_pivot = $CameraPivot
@onready var camera = $CameraPivot/Camera3D
@onready var mesh = $MeshInstance3D
@onready var face_mesh = $MeshInstance3D/MeshInstance3D2
@onready var attack_area = $AttackArea
@onready var hurtbox = $Hurtbox
@onready var animation = $AnimationPlayer

signal health_changed(new_health)
signal gems_changed(new_count)
signal game_over(success: bool, message: String)

func _ready():
	# Make the face mesh unique for this instance
	if face_mesh and face_mesh.mesh:
		face_mesh.mesh = face_mesh.mesh.duplicate()
	
	camera_distance = global_position.distance_to(camera.global_position)
	camera_height = camera.position.y
	health = max_health
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Add to player group
	add_to_group("player")
	
	update_camera_position()
	
	health_changed.emit(health)
	gems_changed.emit(gems_collected)
	
	# Keep attack area always monitoring, but only apply damage when attacking
	attack_area.monitoring = true
	attack_area.area_entered.connect(_on_attack_area_entered)
	attack_area.area_exited.connect(_on_attack_area_exited)
	
	# Start with idle animation and neutral expression
	animation.play("idle")
	update_facial_expression()

func update_facial_expression():
	var new_expression = ":)"
	
	# Determine expression based on current state and health
	if is_attacking:
		new_expression = ">:D"  # Aggressive/determined attack face
	elif is_blocking:
		new_expression = "]:|"   # Focused/defensive
	elif current_state == "run":
		if enemies_in_range.size() > 0:
			new_expression = ":O"  # Surprised/alert when running near enemies
		else:
			new_expression = ":)"  # Happy running
	elif health <= max_health * 0.3:
		# Low health - worried/hurt
		new_expression = ":("
	elif health <= max_health * 0.6:
		# Medium health - slightly concerned
		new_expression = ";|"
	else:
		# Healthy and idle/neutral
		new_expression = ":)"
	
	current_expression = new_expression
	
	face_mesh.mesh.text = current_expression

func _on_attack_area_entered(area):
	# Check if this is an enemy hurtbox
	if area.name == "Hurtbox" and area.get_parent().is_in_group("enemies"):
		var enemy = area.get_parent()
		if enemy not in enemies_in_range:
			enemies_in_range.append(enemy)
			# Update expression when enemy enters range
			update_facial_expression()

func _on_attack_area_exited(area):
	# Check if this is an enemy hurtbox
	if area.name == "Hurtbox" and area.get_parent().is_in_group("enemies"):
		var enemy = area.get_parent()
		if enemy in enemies_in_range:
			enemies_in_range.erase(enemy)
			# Update expression when enemy leaves range
			update_facial_expression()

func _input(event):
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		camera_rotation_h -= event.relative.x * mouse_sensitivity
		camera_rotation_v += event.relative.y * mouse_sensitivity
		camera_rotation_v = clamp(camera_rotation_v, deg_to_rad(min_camera_angle), deg_to_rad(max_camera_angle))
		update_camera_position()

func update_camera_position():
	# Counter-rotate the camera pivot to compensate for player rotation
	# This keeps the camera's world rotation independent of player rotation
	camera_pivot.rotation.y = camera_rotation_h - rotation.y
	
	# Calculate camera offset with vertical rotation
	var offset = Vector3()
	offset.x = 0  # No horizontal offset since we're rotating the pivot
	offset.y = camera_distance * sin(camera_rotation_v) + camera_height
	offset.z = camera_distance * cos(camera_rotation_v)
	
	camera.position = offset
	camera.look_at(global_position + Vector3(0, camera_height * 0.5, 0), Vector3.UP)

func _physics_process(delta):
	
	if not is_on_floor():
		velocity += get_gravity() * delta

	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity

	# Handle blocking (right mouse button)
	var was_blocking = is_blocking
	is_blocking = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	
	# Update expression when blocking state changes
	if was_blocking != is_blocking:
		update_facial_expression()
	
	# Handle attack (left mouse button) - can't attack while blocking
	if (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)) and not is_blocking:
		if not is_attacking:
			attack()

	var input_dir = Vector2.ZERO
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_W):
		input_dir.y -= 1

	var direction = Vector3.ZERO
	var is_moving = false
	
	# Only allow movement if not attacking or blocking
	if input_dir != Vector2.ZERO and not is_blocking:
		# Calculate movement direction relative to camera's horizontal rotation only
		var camera_basis = Transform3D()
		camera_basis = camera_basis.rotated(Vector3.UP, camera_rotation_h)
		direction = (camera_basis.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
		
		# Rotate the entire player to face movement direction
		if direction.length() > 0:
			var target_rotation = atan2(direction.x, direction.z)
			rotation.y = lerp_angle(rotation.y, target_rotation, 10.0 * delta)
		
		is_moving = true

	# Apply knockback decay
	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, knockback_decay * delta)

	# Apply movement with knockback consideration
	if direction and not is_blocking:
		velocity.x = direction.x * speed + knockback_velocity.x
		velocity.z = direction.z * speed + knockback_velocity.z
	else:
		velocity.x = move_toward(velocity.x, 0, speed) + knockback_velocity.x
		velocity.z = move_toward(velocity.z, 0, speed) + knockback_velocity.z

	move_and_slide()
	update_camera_position()
	
	# Handle animations
	update_animations(is_moving, was_blocking)

func update_animations(is_moving: bool, was_blocking: bool):
	# Determine current state based on conditions
	var new_state = "idle"
	
	if is_attacking:
		new_state = "attack"
	elif is_blocking:
		new_state = "block"
	elif is_moving:
		new_state = "run"
	else:
		new_state = "idle"
	
	# Only change animation and expression if state changed
	if new_state != current_state:
		previous_state = current_state
		current_state = new_state
		
		# Handle animation changes
		if current_state == "attack":
			# Attack animation is handled in the attack() function
			pass
		elif current_state == "block":
			if not was_blocking:  # Just started blocking
				animation.play("block")
		elif current_state == "run":
			if animation.current_animation != "run":
				animation.play("run")
		else:  # idle
			if animation.current_animation != "idle":
				animation.play("idle")
		
		# Update facial expression when state changes
		update_facial_expression()

func attack():
	if is_attacking or is_blocking:
		return
	
	$sfx/attack.pitch_scale = randf_range(0.9,1.1)
	$sfx/attack.play()
	is_attacking = true
	current_state = "attack"
	animation.play("attack")
	
	# Update expression for attacking
	update_facial_expression()
	
	# Apply damage and knockback to all enemies currently in range
	for enemy in enemies_in_range:
		if enemy and is_instance_valid(enemy) and enemy.has_method("take_damage"):
			# Calculate knockback direction from player to enemy
			var knockback_direction = (enemy.global_position - global_position).normalized()
			enemy.take_damage(attack_damage, knockback_direction)
	
	# Attack animation
	var tween = create_tween()
	tween.tween_property(mesh, "scale", Vector3(1.2, 1.2, 1.2), 0.1)
	tween.tween_property(mesh, "scale", Vector3.ONE, 0.1)
	
	# Wait for attack animation to finish or use a timer
	await animation.animation_finished
	is_attacking = false
	
	# Update expression after attack
	update_facial_expression()

func collect_gem():
	Particle.setup(self, position, Color.GREEN)
	
	$sfx/gem.pitch_scale = randf_range(1.9,2.1)
	$sfx/gem.play()
	gems_collected += 1
	gems_changed.emit(gems_collected)
	
	# Happy expression when collecting gem
	var original_expression = current_expression
	face_mesh.mesh.text = ":D"
	await get_tree().create_timer(1.0).timeout
	face_mesh.mesh.text = original_expression
	
	if gems_collected >= target_gems:
		# Victory expression
		face_mesh.mesh.text = ":D"
		game_over.emit(true, "Success! You collected all the gems!")

func take_damage(damage: int, knockback_direction: Vector3 = Vector3.ZERO):
	# Block reduces damage by 100% and knockback
	var actual_damage = damage
	var actual_knockback_force = knockback_force
	
	if is_blocking:
		Particle.setup(self,$Sword.global_position, Color.LIGHT_YELLOW, 3)
		$sfx/blocked.pitch_scale = randf_range(0.7,1.3)
		$sfx/blocked.play()
		actual_damage = 0
		actual_knockback_force = block_knockback_force  # Reduced knockback when blocking
		
		# Apply knockback even when blocking (but reduced)
		if knockback_direction != Vector3.ZERO:
			knockback_velocity = knockback_direction * actual_knockback_force
		return
	
	Particle.setup(self, position, Color.RED)
	$sfx/hit.pitch_scale = randf_range(0.8,1.2)
	$sfx/hit.play()
	health -= actual_damage
	health = max(0, health)
	health_changed.emit(health)
	
	# Apply knockback
	if knockback_direction != Vector3.ZERO:
		knockback_velocity = knockback_direction * actual_knockback_force
	
	# Update expression based on new health
	update_facial_expression()
	
	# Brief hurt expression
	var original_expression = current_expression
	face_mesh.mesh.text = "X["
	await get_tree().create_timer(0.3).timeout
	if health > 0:  # Check if still alive
		face_mesh.mesh.text = original_expression
		
	if health <= 0:
		face_mesh.mesh.text = "Xo"  # Dead expression
		game_over.emit(false, "We need a rest...")

# Helper function to check if player is currently blocking (for enemies to use)
func is_currently_blocking() -> bool:
	return is_blocking
