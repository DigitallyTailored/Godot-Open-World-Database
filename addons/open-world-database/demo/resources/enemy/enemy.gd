# Enemy.gd
extends CharacterBody3D

@export var speed = 2.0
@export var max_health = 100
@export var detection_range = 10.0
@export var attack_damage = 20
@export var attack_cooldown = 2.0
@export var patrol_radius = 5.0
@export var patrol_speed = 1.0
var knockback_force = 6.0  # New knockback parameter
var attack_range = 2.0

var health: int
var player: CharacterBody3D
var is_dead = false
var can_attack = true
var is_attacking = false
var last_attack_time = 0.0

# Knockback variables
var knockback_velocity = Vector3.ZERO
var knockback_decay = 8.0  # How fast knockback decays

# Track player in range
var player_in_range = false

# Patrol variables
var start_position: Vector3
var patrol_target: Vector3
var is_patrolling = true
var patrol_wait_time = 0.0
var max_patrol_wait = 2.0

# Animation state tracking
var current_state = "idle"
var previous_state = "idle"

# Facial expression variables
var blink_timer = 0.0
var blink_interval = 2.0  # Base blink interval
var next_blink_time = 2.0
var is_blinking = false
var blink_duration = 0.15
var current_expression = ":)"
var last_expression = ""  # Track last expression to avoid unnecessary updates

@onready var mesh = $MeshInstance3D
@onready var face_mesh = $MeshInstance3D/MeshInstance3D2
@onready var attack_area = $AttackArea
@onready var hurtbox = $Hurtbox
@onready var animation = $AnimationPlayer

var health_bar_3d: Node3D
var health_bar_fill: MeshInstance3D

func _ready():
	
	face_mesh.mesh = face_mesh.mesh.duplicate()
	
	health = max_health
	start_position = global_position
	
	# Add to enemies group
	add_to_group("enemies")
	
	player = get_tree().get_first_node_in_group("player")
	
	# Keep attack area always monitoring, but only apply damage when attacking
	attack_area.monitoring = true
	attack_area.area_entered.connect(_on_attack_area_entered)
	attack_area.area_exited.connect(_on_attack_area_exited)
	
	setup_health_bar()
	update_health_bar()
	set_new_patrol_target()
	
	# Start with idle animation and neutral expression
	animation.play("idle")
	update_facial_expression()
	
	# Set initial blink time
	randomize_blink_interval()

func _on_attack_area_entered(area):
	# Check if this is the player's hurtbox
	if area.name == "Hurtbox" and area.get_parent().is_in_group("player"):
		player_in_range = true

func _on_attack_area_exited(area):
	# Check if this is the player's hurtbox
	if area.name == "Hurtbox" and area.get_parent().is_in_group("player"):
		player_in_range = false

func is_currently_attacking() -> bool:
	return is_attacking

func randomize_blink_interval():
	# Randomize next blink time between 1-4 seconds
	next_blink_time = randf_range(1.0, 4.0)
	blink_timer = 0.0

func update_facial_expression():
	if is_dead:
		return
		
	var new_expression = ":|"
	
	# Determine expression based on current state and health
	if is_attacking:
		new_expression = "}:D"
	elif current_state == "run" and not is_patrolling:
		# Chasing player
		new_expression = "}:("
	elif health <= max_health * 0.6:
		# Low health - worried/hurt
		new_expression = ":("
	elif current_state == "run" and is_patrolling:
		# Just patrolling
		new_expression = ":|"
	else:
		# Idle/neutral
		new_expression = ":)"
	
	# Only update if expression has changed
	if new_expression != last_expression:
		current_expression = new_expression
		last_expression = new_expression
		
		# Apply the expression (unless currently blinking)
		if not is_blinking:
			face_mesh.mesh.text = current_expression

func setup_health_bar():
	health_bar_3d = Node3D.new()
	health_bar_3d.name = "HealthBar3D"
	add_child(health_bar_3d)
	health_bar_3d.position = Vector3(0, 1, 0)
		
	health_bar_fill = MeshInstance3D.new()
	health_bar_fill.name = "HealthBarFill"
	var fill_mesh = QuadMesh.new()
	fill_mesh.size = Vector2(1.0, 0.1)
	health_bar_fill.mesh = fill_mesh
	health_bar_fill.position = Vector3(0, 0, -0.001)
	
	var fill_material = StandardMaterial3D.new()
	fill_material.albedo_color = Color.GREEN
	fill_material.flags_unshaded = true
	fill_material.no_depth_test = true
	fill_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	health_bar_fill.material_override = fill_material
	
	health_bar_3d.add_child(health_bar_fill)

func update_health_bar():
	if not health_bar_fill or not health_bar_fill.mesh:
		return
		
	var health_percentage = float(health) / float(max_health)
	
	var fill_mesh = health_bar_fill.mesh as QuadMesh
	fill_mesh.size.x = 1.0 * health_percentage
	health_bar_fill.position.x = -0.5 + (0.5 * health_percentage)
	
	var material = health_bar_fill.material_override as StandardMaterial3D
	if health_percentage > 0.6:
		material.albedo_color = Color.GREEN
	elif health_percentage > 0.3:
		material.albedo_color = Color.YELLOW
	else:
		material.albedo_color = Color.RED

func set_new_patrol_target():
	var angle = randf() * TAU
	var distance = randf() * patrol_radius
	patrol_target = start_position + Vector3(cos(angle) * distance, 0, sin(angle) * distance)
func _physics_process(delta):
	# Apply knockback decay (always runs, even when dead)
	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, knockback_decay * delta)
	
	# If dead, only apply knockback and gravity, then return
	if is_dead:
		velocity.x = knockback_velocity.x
		velocity.y = knockback_velocity.y
		velocity.z = knockback_velocity.z
		
		if not is_on_floor():
			velocity += get_gravity() * delta
		
		move_and_slide()
		return
	
	# Early return if no player (but not dead)
	if not player:
		return
		
	var distance_to_player = global_position.distance_to(player.global_position)
	var is_moving = false
	var is_chasing = false
	
	if distance_to_player <= detection_range and can_see_player():
		is_patrolling = false
		is_chasing = true
		var direction = (player.global_position - global_position).normalized()
		
		if distance_to_player > attack_range:
			# Chase the player with knockback consideration
			velocity.x = direction.x * speed + knockback_velocity.x
			velocity.z = direction.z * speed + knockback_velocity.z
			is_moving = true
			
			# Look at player - FIXED ROTATION CALCULATION
			var target_rotation = atan2(direction.x, direction.z)
			rotation.y = lerp_angle(rotation.y, target_rotation, 5.0 * delta)
		else:
			# In attack range - stop moving but apply knockback
			velocity.x = knockback_velocity.x
			velocity.z = knockback_velocity.z
			
			# Still face the player when in attack range - FIXED ROTATION CALCULATION
			var target_rotation = atan2(direction.x, direction.z)
			rotation.y = lerp_angle(rotation.y, target_rotation, 5.0 * delta)
			
			# Attack if we can and player is in range
			if can_attack:
				attack_player()
	else:
		# Not chasing player - patrol with knockback consideration
		if not is_patrolling:
			is_patrolling = true
			set_new_patrol_target()
		
		is_moving = patrol(delta)
	
	if not is_on_floor():
		velocity += get_gravity() * delta
	
	move_and_slide()
	
	# Update animations based on current state
	update_animations(is_moving, is_chasing)

func patrol(delta) -> bool:
	var distance_to_patrol_target = global_position.distance_to(patrol_target)
	var is_moving = false
	
	if distance_to_patrol_target > 0.5:
		var direction = (patrol_target - global_position).normalized()
		velocity.x = direction.x * patrol_speed + knockback_velocity.x
		velocity.z = direction.z * patrol_speed + knockback_velocity.z
		is_moving = true
		
		# Look towards patrol direction - FIXED ROTATION CALCULATION
		var target_rotation = atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, target_rotation, 3.0 * delta)
		
		patrol_wait_time = 0.0
	else:
		velocity.x = knockback_velocity.x
		velocity.z = knockback_velocity.z
		
		patrol_wait_time += delta
		if patrol_wait_time >= max_patrol_wait:
			set_new_patrol_target()
			patrol_wait_time = 0.0
	
	return is_moving

func update_animations(is_moving: bool, is_chasing: bool):
	# Determine current state based on conditions
	# Priority: attack > run (chase/patrol) > idle
	
	var new_state = "idle"
	
	if is_attacking:
		new_state = "attack"
	elif is_moving:
		new_state = "run"
	else:
		new_state = "idle"
	
	# Only change animation if state changed
	if new_state != current_state:
		previous_state = current_state
		current_state = new_state
		
		# Don't interrupt attack animations
		if previous_state != "attack" or new_state == "attack":
			animation.play(current_state)
		
		# Update facial expression when state changes
		update_facial_expression()

func can_see_player() -> bool:
	if not player:
		return false
	
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0, 1, 0),
		player.global_position + Vector3(0, 1, 0)
	)
	
	query.exclude = [get_rid()]
	var result = space_state.intersect_ray(query)
	
	if result.is_empty():
		return true
	
	if result.has("collider") and result.collider == player:
		return true
	
	return false

func attack_player():
	if not can_attack:
		return
	$sfx/attack.play()
	can_attack = false
	is_attacking = true
	current_state = "attack"
	animation.play("attack")
	
	# Update expression for attacking
	update_facial_expression()
		
	# Check if player is blocking before applying damage
	var damage_to_apply = attack_damage
	
	# Apply damage and knockback to player if they're in range
	if player_in_range and player.has_method("take_damage"):
		# Calculate knockback direction from enemy to player
		var knockback_direction = (player.global_position - global_position).normalized()
		player.take_damage(damage_to_apply, knockback_direction)
	
	# Attack visual effect
	var tween = create_tween()
	tween.tween_property(mesh, "scale", Vector3(1.3, 1.0, 1.3), 0.15)
	tween.tween_property(mesh, "scale", Vector3.ONE, 0.15)
	
	# Wait for attack animation to finish (adjust timing based on your attack animation length)
	await get_tree().create_timer(0.5).timeout  # Adjust this to match your attack animation duration
	is_attacking = false
	
	# Update expression after attack
	update_facial_expression()
	
	# Cooldown period
	await get_tree().create_timer(attack_cooldown).timeout
	can_attack = true

func take_damage(damage: int, knockback_direction: Vector3 = Vector3.ZERO):
	if is_dead:
		return
	
	health -= damage
	update_health_bar()
	
	# Apply knockback
	if knockback_direction != Vector3.ZERO:
		knockback_velocity = knockback_direction * knockback_force
	
	# Update expression based on new health
	update_facial_expression()
	
	if health <= 0:
		$sfx/hit.pitch_scale = randf_range(0.4,0.6)
		$sfx/hit.play()
	else:
		$sfx/hit.pitch_scale = randf_range(0.8,1.2)
		$sfx/hit.play()
		
	# Brief hurt expression - force update regardless of last expression
	if not is_dead:
		var original_expression = current_expression
		face_mesh.mesh.text = "Xo"
		last_expression = "Xo"  # Update tracking variable
		await get_tree().create_timer(0.3).timeout
		if not is_dead:  # Check again in case enemy died during the wait
			face_mesh.mesh.text = original_expression
			last_expression = original_expression  # Update tracking variable
			
	if health <= 0:
		Particle.setup(self, position, Color.YELLOW, 20)
		knockback_velocity = knockback_velocity * 2
		die()
	else:
		Particle.setup(self, position, Color.YELLOW, 2)

func die():
	face_mesh.mesh.text = "X|"
	last_expression = "X|"  # Update tracking variable for consistency
	is_dead = true
	current_state = "dead"
	
	if health_bar_3d:
		health_bar_3d.visible = false
	
	# Stop all animations
	animation.stop()
	
	var tween = create_tween()
	tween.tween_property(self, "scale", Vector3(0.01,0.01,0.01), 2)
	tween.tween_callback(queue_free)
