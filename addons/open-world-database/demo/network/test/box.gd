# demo/box.gd
# Manual synchronization approach
# This box demonstrates explicit sync control - you decide exactly when to send updates

extends Node3D

var next_update = 0
var data = {} #doesn't need to be a dictionary, can be anything but dictionary for demonstration

func _ready() -> void:
	$OWDBSync.connect("input", recieved_data)
	
	data = $OWDBSync.properties("data", {}) #populate the node with the initial received data
	if not data.is_empty():
		recieved_data({"data": data}) #manually call as will not be called until next update
	
	rotate_y(randf() * PI * 2.0)

func _host_process(delta: float) -> void:
	position.y = 1 + sin(Time.get_ticks_msec() * 0.001) * 2
	
	#$OWDBSync.output(["position"]) #immediatly broadcast position update
	$OWDBSync.output_timed(["position"], 20) #send in intervals instead
	if Time.get_ticks_msec() > next_update:
		next_update = Time.get_ticks_msec() + 200
		data["text"] = Syncer.nodes.random_string()
		$Label3D.text = data["text"]
		$OWDBSync.output(["data"])

func recieved_data(new_variables):
	if new_variables.has("data"):
		data = new_variables["data"]
		if data.has("text"):
			$Label3D.text = data["text"]
	
	if new_variables.has("position"):
		position = new_variables["position"]
