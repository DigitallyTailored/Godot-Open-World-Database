extends Node3D

@onready var particles: GPUParticles3D = $GPUParticles3D

func _ready():
	# Start emitting particles
	particles.emitting = true
	
	# Connect to the finished signal to auto-delete
	particles.finished.connect(_on_particles_finished)
	
	# If particles don't have a lifetime set, use a fallback timer
	if particles.lifetime <= 0:
		var timer = Timer.new()
		add_child(timer)
		timer.wait_time = 5.0  # Fallback duration
		timer.one_shot = true
		timer.timeout.connect(_on_particles_finished)
		timer.start()

func setup(parent_node: Node, pos: Vector3, color: Color = Color.WHITE, amount :int= 5):
	"""Setup the particle effect with position and color"""
	# Don't add to scene here - let the static method handle parenting
	global_position = pos
	set_albedo_color(color)
	particles.amount = amount * 5
	particles.one_shot = true
	particles.emitting = true


func set_albedo_color(color: Color):
	if particles.draw_pass_1:
		# Get the original material
		particles.draw_pass_1 = particles.draw_pass_1.duplicate()
		var mesh_material = particles.draw_pass_1.surface_get_material(0).duplicate()
		mesh_material.albedo_color = color
		particles.draw_pass_1.surface_set_material(0, mesh_material)


func _on_particles_finished():
	"""Called when particles finish emitting"""
	queue_free()
