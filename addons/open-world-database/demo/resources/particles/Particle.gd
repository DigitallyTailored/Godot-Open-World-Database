class_name Particle

const PARTICLE_SCENE = preload("res://addons/open-world-database/demo/resources/particles/particles.tscn")

static func setup(parent: Node, pos: Vector3, color: Color = Color.WHITE, amount :int= 5):
	var particle = PARTICLE_SCENE.instantiate()
	parent.get_tree().root.add_child(particle)
	particle.setup(parent, pos, color, amount)
