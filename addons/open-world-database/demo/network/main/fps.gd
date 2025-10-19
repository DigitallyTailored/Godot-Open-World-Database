# fps.gd
extends Label

var update_timer := 0.0
var frame_count := 0
var last_fps := 0

func _process(delta: float) -> void:
	frame_count += 1
	update_timer += delta
	
	if update_timer >= 0.5:  # Update twice per second instead of every frame
		last_fps = int(frame_count / update_timer)
		text = str(last_fps)
		frame_count = 0
		update_timer = 0.0
