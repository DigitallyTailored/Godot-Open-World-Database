# demo/box2.gd
# Automatic watch system approach  
# This box demonstrates hands-off sync - just mark what to watch and it handles the rest

extends Node3D

var next_update = 0
var game_data = {}  #doesn't need to be a dictionary, can be anything but dictionary for demonstration

func _ready() -> void:
	$OWDBSync.connect("input", recieved_data)
	
	rotate_y(randf() * PI * 2.0)
		
	# Setup watch system - now we can watch any variables!
	$OWDBSync.watch(["game_data", "position"]) #this also populates these values with any received data
	$OWDBSync.set_interval(200) #interval for automatic updates
	
func _host_process(delta: float) -> void:
	position.y = 1 + sin(Time.get_ticks_msec() * 0.001) * 2
	
	if Time.get_ticks_msec() > next_update:
		next_update = Time.get_ticks_msec() + $OWDBSync.interval
		game_data["text"] = Syncer.nodes.random_string()
		$Label3D.text = game_data["text"]
		# Watch system automatically detects changes!

func recieved_data(new_variables):
	# Handle any received variables
	if new_variables.has("game_data"):
		game_data = new_variables["game_data"]
		if game_data.has("text"):
			$Label3D.text = game_data["text"]
