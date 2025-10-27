# demo/box3.gd
# Config entirely managed by OWDBSync properties
# This box demonstrates hands-off sync - just set the properties of what to watch in OWDBSync and it handles the rest
extends Node3D

func _ready() -> void:
	rotate_y(randf() * PI * 2.0)

func _host_process(delta: float) -> void:
	position.y = 1 + sin(Time.get_ticks_msec() * 0.001) * 2
