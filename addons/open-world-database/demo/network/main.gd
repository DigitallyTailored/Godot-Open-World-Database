extends Node

@onready var host_button = $UI/Host
@onready var join_button = $UI/Join
@onready var owdb = $OpenWorldDatabase

func _ready():
	# Setup OWDB group for easy finding
	owdb.add_to_group("owdb")
	
	# Connect UI
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)

func _on_host_pressed():
	# Create server
	var peer = ENetMultiplayerPeer.new()
	peer.create_server(owdb.server_port)
	multiplayer.multiplayer_peer = peer
	
	# Create position tracker for server peer
	var server_pos = preload("res://addons/open-world-database/OWDBPosition.tscn").instantiate()
	server_pos.peer_id = 1
	owdb.add_child(server_pos)
	
	# Hide UI
	$UI.visible = false
	
	print("OWDB: Server started on port ", owdb.server_port)

func _on_join_pressed():
	# Connect to server
	var peer = ENetMultiplayerPeer.new()
	peer.create_client("127.0.0.1", owdb.server_port)
	multiplayer.multiplayer_peer = peer
	
	# Hide UI
	$UI.visible = false
	
	print("OWDB: Connecting to server...")

func _on_peer_connected(peer_id: int):
	if multiplayer.is_server():
		# Create position tracker for new peer
		var peer_pos = preload("res://addons/open-world-database/OWDBPosition.tscn").instantiate()
		peer_pos.peer_id = peer_id
		owdb.add_child(peer_pos)
