# main.gd - Updated for networked OWDB
extends Node


@onready var host_button = $Host
@onready var join_button = $Join
@onready var owdb = $OpenWorldDatabase  # Reference to OWDB

func _ready() -> void:
	# Connect UI buttons
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	
	# Connect multiplayer signals
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	
func _on_host_pressed() -> void:
	# Create server
	var peer = ENetMultiplayerPeer.new()
	peer.create_server(7777)
	multiplayer.multiplayer_peer = peer
	
	# Disable UI
	_disable_buttons()
	
	get_window().title = "SERVER - " + str(multiplayer.get_unique_id())
	
	# Add a player for the server (with OWDBPosition)
	_add_player(1)
	Syncer.handle_peer_connected(1)

func _on_join_pressed() -> void:
	# Connect to server
	var peer = ENetMultiplayerPeer.new()
	peer.create_client("127.0.0.1", 7777)
	multiplayer.multiplayer_peer = peer
	
	# Disable UI
	_disable_buttons()
	
	get_window().title = "CLIENT - " + str(multiplayer.get_unique_id())

func _disable_buttons() -> void:
	host_button.visible = false
	join_button.visible = false

func _on_peer_connected(id: int) -> void:
	# Server adds a player for the connected client
	if multiplayer.is_server():
		_add_player(id)
		Syncer.handle_peer_connected(id)

func _on_connected_to_server() -> void:
	# Client connected to server - handle pre-existing sync nodes
	Syncer.handle_client_connected_to_server()

func _add_player(id: int) -> void:
	if not multiplayer.is_server():
		return
		
	var node_name = str(id)
	var rng = RandomNumberGenerator.new()
	
	# Create player with both Sync and OWDBPosition
	var player_scene = load("res://addons/open-world-database/demo/network/player/player.tscn")
	var player = player_scene.instantiate()
	player.name = node_name
	player.position = Vector3(
		rng.randi_range(-10, 10),
		2,
		rng.randi_range(-10, 10)
	)
	
	# Setup sync node
	var sync_node = player.find_child("Sync")
	if sync_node:
		sync_node.peer_id = id
	
	# Setup OWDBPosition (it will automatically get the peer_id from Sync node)
	var owdb_position = player.find_child("OWDBPosition")
	if owdb_position:
		owdb_position.refresh_peer_registration()
	
	# Add player to the scene
	$SyncNodes.add_child(player)
	
	# Make player visible to appropriate peers
	Syncer.entity_peer_visible(id, node_name, true)
	
	# Make all players visible to each other
	for peer_id in Syncer.get_peer_nodes_observing().keys():
		if peer_id != id:
			Syncer.entity_peer_visible(peer_id, node_name, true)
			Syncer.entity_peer_visible(id, str(peer_id), true)

func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		Syncer.handle_peer_disconnected(id)
