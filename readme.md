# Open World Database (OWDB) for Godot

A powerful Godot addon that brings efficient world streaming to your indie game, with optional multiplayer networking capabilities. Build massive open worlds that perform beautifully, inspired by the seamless worlds of modern RPGs and adventure games.

## The Problem: When Worlds Get Too Big

Large, detailed open worlds are incredible to explore, but they present a significant technical challenge. Those expansive landscapes that feel infinite are actually cleverly managed behind the scenes. In Godot, dropping thousands of objects, AI agents, physics bodies, or nodes into a single scene will severely impact performance. Traditional solutions involve custom LOD systems or splitting your world into separate scenes - all of which break your creative flow and make iteration painful.

**OWDB changes that.**

## The Solution: Smart World Streaming + Optional Networking

Open World Database automatically transforms your sprawling world through intelligent chunk-based streaming, with seamless multiplayer capabilities when you need them. The core world streaming system provides batch processing for smooth loading with configurable time limits, intelligent chunking strategies for different content types, and persistent worlds that survive restarts. Your workflow remains exactly like normal Godot scenes, while the system efficiently manages memory by only loading what players are close to relative to each item's size.

When you're ready for multiplayer, the optional networking layer adds chunk-based visibility so only entities that players can actually see get synchronized. Custom resources are automatically distributed between peers, multiple sync patterns give you control from hands-off automation to precise manual control, and seamless HOST/PEER/STANDALONE transitions let you test locally and deploy multiplayer without code changes.

## Installation

The installation process is straightforward and gets you up and running quickly. Download the addon from the Godot Asset Library or GitHub, extract it to your project's `addons/` folder, then enable it in Project Settings → Plugins → Open World Database. The Syncer autoload is configured automatically, so you're ready to start building your world immediately.

## Single-Player Quick Start

### Step 1: Set Up Your World Structure

Building your world with OWDB follows Godot's natural scene structure patterns. Create a main scene with an OpenWorldDatabase node as the root for all your world content, then organize your content hierarchically underneath it. Add areas like towns with shop buildings, interiors, and NPCs; wilderness zones with outposts, points of interest, and wildlife spawns; and important landmarks. Your player should be separate from the world database, with an OWDBPosition child node that triggers chunk loading around the player's current location.

```gdscript
# Create your scene structure like this:
Main Scene
└── OpenWorldDatabase
	├── Town
	│   ├── Shop Buildings (with interiors, NPCs)
	│   ├── Public Areas (with furniture, decorations)
	│   └── Guard Patrols (moving NPCs)
	├── Wilderness
	│   ├── Outpost Areas
	│   ├── Points of Interest
	│   └── Wildlife Spawns
	├── Important Landmarks
└── Player
	└── OWDBPosition  # This triggers chunk loading around player
```

### Step 2: Configure Your World

The OpenWorldDatabase node exposes several key settings through the inspector that control how your world streams. The chunk_sizes array defines size categories for different content types - smaller values like 8.0 for detailed objects, medium values like 16.0 for buildings, and larger values like 64.0 for terrain features. The chunk_load_range determines how many chunks around each position to keep loaded, while batch_time_limit_ms controls the maximum time per frame spent on loading operations to maintain smooth performance. Enable debug mode to see the system working in real-time as you develop.

### Step 3: Add Position Tracking

Simply add an OWDBPosition node as a child to your player or camera, and the system handles everything else automatically. The system generates unique IDs for everything under OWDB, calculates object sizes and assigns them to appropriate chunk categories, creates a `.owdb` database file alongside your scene, and monitors for changes as you work in the editor. This gives you efficient world streaming based on the player's position with zero additional code required.

## The Three Node Types

### OpenWorldDatabase - The World Manager

The OpenWorldDatabase node serves as the central coordinator for your entire world streaming system. It manages world content through intelligent chunking algorithms that categorize objects by size and importance, handles batch processing to maintain smooth performance by spreading loading operations across multiple frames, and saves/loads world state to persistent `.owdb` files so your world remembers changes between sessions. When multiplayer is enabled, it coordinates seamlessly with the networking system to ensure consistent world state across all connected peers.

### OWDBPosition - The Position Tracker

OWDBPosition nodes act as focal points that define where chunks should be loaded in your world. Add them as children to any Node3D that needs chunks loaded nearby - typically your player, but also cameras, important NPCs, or any entity that needs world content available around it. The system automatically tracks position changes and triggers appropriate loading and unloading operations. In multiplayer scenarios, these positions communicate with the Syncer for per-peer visibility culling, and you can have multiple positions active simultaneously for complex visibility requirements like split-screen or multiple important areas.

### OWDBSync - The Network Synchronizer *(Optional - Multiplayer Only)*

The OWDBSync component handles property synchronization between peers using three distinct approaches to match your needs. The automatic approach lets you configure everything through exported properties in the inspector, perfect for rapid prototyping. The script-based approach provides simple script calls for setting up property watching with automatic change detection, ideal for most game scenarios. The manual approach gives you complete control over what syncs when, perfect for performance-critical situations or complex conditional syncing requirements.

## Advanced Single-Player Features

### Multiple Save States

OWDB supports multiple world configurations, allowing you to save and load different versions of your world for testing different scenarios or providing players with multiple save slots. You can save world variations with custom names, load specific world states on demand, and list all available saved worlds. This is particularly useful during development for testing different content arrangements or maintaining separate builds for different game modes.

```gdscript
# Save different world configurations for testing
func save_world_variation(name: String):
	$OpenWorldDatabase.save_database(name)  # Saves to user://name.owdb

# Load specific world state
func load_world_variation(name: String):
	$OpenWorldDatabase.load_database(name)

# List all saved worlds
func get_available_worlds() -> Array[String]:
	return $OpenWorldDatabase.list_custom_databases()
```

### Performance Control

Fine-tuning OWDB's performance characteristics allows you to optimize the system for your specific content and hardware requirements. You can temporarily pause streaming during intensive operations to prevent frame rate drops during critical moments, while most other performance settings are controlled through the inspector configuration options.

```gdscript
# Pause streaming during intensive operations  
func perform_heavy_operation():
	owdb.batch_processor.batch_processing_enabled = false
	# Do intensive work here
	owdb.batch_processor.batch_processing_enabled = true
```

### Editor Integration

OWDB integrates seamlessly with the Godot editor to maintain your workflow without interruption. The system can follow the editor camera for testing chunk loading during development, automatically saves the database when you save your scene, provides real-time debug output showing loading and unloading operations, and preserves all your custom exports and properties through the streaming process. This means you can work naturally in the editor while the system handles the technical complexities behind the scenes.

## Adding Multiplayer (Optional)

When you're ready to add multiplayer to your world streaming game, OWDB seamlessly integrates networking without requiring changes to your existing world structure. The system automatically switches between HOST, PEER, and STANDALONE modes based on your networking state, with hosts maintaining full autonomous chunk management while serving data to peers, and peers receiving controlled chunk loading and world updates from the host.

### Basic Multiplayer Setup

Setting up basic multiplayer involves creating standard Godot networking code with a few OWDB-specific additions. You'll connect UI buttons for hosting and joining, handle standard multiplayer signals, and ensure that each player has the necessary OWDBSync and OWDBPosition components configured properly. The Syncer autoload handles the coordination between networking and world streaming automatically.

```gdscript
# main.gd - Basic networking setup
extends Node

func _ready() -> void:
	# Connect UI buttons
	$UI/Host.pressed.connect(_on_host_pressed)
	$UI/Join.pressed.connect(_on_join_pressed)
	
	# Connect multiplayer signals
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
func _on_host_pressed() -> void:
	# Create server
	var peer = ENetMultiplayerPeer.new()
	peer.create_server(7777)
	multiplayer.multiplayer_peer = peer
	
	# Add a player for the server (with OWDBPosition)
	_add_player(1)
	Syncer.handle_peer_connected(1)

func _on_join_pressed() -> void:
	# Connect to server
	var peer = ENetMultiplayerPeer.new()
	peer.create_client($UI/JoinIP.text, 7777)
	multiplayer.multiplayer_peer = peer

func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		_add_player(id)
		Syncer.handle_peer_connected(id)

func _add_player(id: int) -> void:
	var player = preload("res://Player.tscn").instantiate()
	player.name = str(id)
	
	# Setup sync and position components
	var sync_node = player.find_child("OWDBSync")
	if sync_node:
		sync_node.peer_id = id
	
	add_child(player)
	Syncer.entity_peer_visible(id, str(id), true)
```

### Network Modes

OWDB automatically manages three distinct network modes based on your multiplayer state. In HOST mode, the peer has full autonomous chunk management capabilities and serves world data to connected peers. PEER mode means chunk loading is controlled by the host while the peer receives world updates and synchronization data. STANDALONE mode operates purely locally with no networking involvement, perfect for single-player testing or offline play.

### The `_host_process` and `_host_physics_process` Methods

These special methods provide authoritative control by ensuring game logic runs only on the controlling peer of each node. By default, the host controls all world entities, but you can assign specific nodes to different peers for distributed processing. This prevents redundant calculations across all clients and ensures consistent game state by having single sources of truth for each object's behavior.

```gdscript
# These methods only execute on the peer that "owns" this node
func _host_process(delta: float) -> void:
	# Game logic, AI decisions, physics simulation
	# Only the controlling peer runs this code
	position.y = 1 + sin(Time.get_ticks_msec() * 0.001) * 2

func _host_physics_process(delta: float) -> void:
	# Physics-based updates that need to be authoritative
	handle_movement_input(delta)
	move_and_slide()
```

## The Three Synchronization Approaches

### Approach 1: Hands-Off Automation

The automation approach is perfect for simple objects and rapid prototyping where you want minimal code involvement. Configure everything through the OWDBSync node's inspector properties, including which parent variables to watch and how frequently to check for changes. The system automatically detects when watched properties change and synchronizes them across all peers without any script code required.

```gdscript
# box3.gd - Zero script configuration needed!
extends Node3D

func _ready() -> void:
	rotate_y(randf() * PI * 2.0)

func _host_process(delta: float) -> void:
	position.y = 1 + sin(Time.get_ticks_msec() * 0.001) * 2
```

### Approach 2: Script-Based Watching *(Recommended)*

Script-based watching strikes an ideal balance between simplicity and flexibility, making it perfect for custom game data and game-specific properties. You set up automatic watching through simple script calls, and the system handles change detection and synchronization automatically. This approach gives you control over what gets synchronized while maintaining the convenience of automatic change detection.

```gdscript
# box2.gd - Simple script setup with automatic detection
extends Node3D

var game_data = {}  # Custom game data
var next_update = 0

func _ready() -> void:
	$OWDBSync.connect("input", recieved_data)
	rotate_y(randf() * PI * 2.0)
	
	# Setup automatic watching - detects changes and syncs automatically
	$OWDBSync.watch(["game_data", "position"])
	$OWDBSync.set_interval(200)
	
func _host_process(delta: float) -> void:
	position.y = 1 + sin(Time.get_ticks_msec() * 0.001) * 2
	
	if Time.get_ticks_msec() > next_update:
		next_update = Time.get_ticks_msec() + $OWDBSync.interval
		game_data["text"] = "Updated: " + str(Time.get_ticks_msec())
		$Label3D.text = game_data["text"]
		# Watch system automatically detects changes!

func recieved_data(new_variables):
	if new_variables.has("game_data"):
		game_data = new_variables["game_data"]
		if game_data.has("text"):
			$Label3D.text = game_data["text"]
```

### Approach 3: Manual Control

Manual control provides complete authority over synchronization timing, perfect for performance-critical situations or complex conditional syncing requirements. You explicitly control when data gets synchronized, allowing for precise timing optimization, conditional syncing based on game state, and fine-grained network traffic management. This approach requires more code but offers maximum flexibility for complex synchronization scenarios.

```gdscript
# box.gd - Full manual control over sync timing
extends Node3D

var data = {}
var next_update = 0

func _ready() -> void:
	$OWDBSync.connect("input", recieved_data)
	
	# Get initial synced data if available
	data = $OWDBSync.properties("data", {})
	if not data.is_empty():
		recieved_data({"data": data})
	
	rotate_y(randf() * PI * 2.0)

func _host_process(delta: float) -> void:
	position.y = 1 + sin(Time.get_ticks_msec() * 0.001) * 2
	
	# Throttled position sync (every 20ms)
	$OWDBSync.output_timed(["position"], 20)
	
	if Time.get_ticks_msec() > next_update:
		next_update = Time.get_ticks_msec() + 200
		data["text"] = "Manual: " + str(Time.get_ticks_msec())
		$Label3D.text = data["text"]
		$OWDBSync.output(["data"])  # Send immediately

func recieved_data(new_variables):
	if new_variables.has("data"):
		data = new_variables["data"]
		if data.has("text"):
			$Label3D.text = data["text"]
	
	if new_variables.has("position"):
		position = new_variables["position"]
```

### Player Movement Example

Smart movement synchronization demonstrates how to optimize network traffic by only sending updates when meaningful changes occur. This approach prevents unnecessary network chatter from tiny position changes while ensuring smooth movement replication across all connected peers. The system tracks significant position changes and only synchronizes when the player has moved beyond a threshold distance.

```gdscript
# player.gd - Movement-based selective sync
extends CharacterBody3D

@export var speed = 20.0
@export var gravity = 9.8
@export var rotation_speed = 10.0

var position_old : Vector3

func _host_physics_process(delta):
	if not is_on_floor():
		velocity.y -= gravity * delta
	
	var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var direction = Vector3(input_dir.x, 0, input_dir.y).normalized()
	
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		var target_rotation = atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
	
	move_and_slide()

	# Only sync when player has moved significantly
	if position.distance_squared_to(position_old) > 0.25:
		position_old = position
		$OWDBSync.output(["position", "rotation.y"])
```

## Resource Sharing in Multiplayer

OWDB's resource sharing system automatically handles the distribution of custom content between peers, eliminating the need for manual asset distribution. Custom resources including materials, meshes, and textures are stored in the `.owdb` file, and when a peer joins, they receive the world structure first. If they're missing custom resources, these are automatically requested from the host, who sends the resource data to requesting clients. This enables the host to update maps, materials, and content in real-time without requiring client updates.

The system supports built-in resources created in code, external `.tres` and `.res` files, procedurally generated content, and custom materials and textures. This means new players automatically receive the latest version of everything, custom materials and procedural content sync seamlessly, and there's no need to distribute updated asset files to all players manually.

## Best Practices

### Single-Player Guidelines

Effective single-player usage of OWDB centers around thoughtful world organization and appropriate system configuration. Use hierarchical organization by grouping related objects under parent nodes, which helps the chunking system make intelligent decisions about what content belongs together. Test different chunk ranges to find your performance sweet spot, as this varies significantly based on your content density and target hardware. Save your work regularly since OWDB auto-saves when you save the scene, and use meaningful node names to make debugging and management easier as your world grows.

Avoid nesting OWDB nodes within each other, as this functionality is planned but not yet implemented. Don't put UI elements under OWDB since it's designed specifically for world content, and be careful not to set chunk_load_range too high as this can cause performance issues by loading too much content simultaneously.

### Multiplayer Guidelines

Successful multiplayer implementation with OWDB requires understanding the different synchronization approaches and choosing appropriate methods for your content. Use the hands-off approach for simple objects, script-based watching for most game scenarios, and manual control for performance-critical situations. Sync only what actually changes by using conditional syncing to reduce network traffic, leverage OWDB's automatic visibility system to let it handle what peers should see, and use `_host_process` methods to ensure authoritative game logic runs only where it should.

Avoid syncing unnecessary data since every synced property has network cost, don't forget about peer authority since only authoritative peers should modify shared state, and don't continuously sync frequently-changing data without throttling to prevent network congestion.

## Troubleshooting

### Common Issues

The most frequent issue in multiplayer is nodes disappearing, which typically occurs when players don't have properly configured OWDBPosition components or when chunk ranges don't cover your content appropriately. Ensure each player has an OWDBPosition component and that your chunk load ranges encompass all the content players need to see.

Performance drops during loading usually indicate that the batch processing time limit needs adjustment. Reduce `batch_time_limit_ms` for better framerate consistency, or increase it for faster loading if frame rate drops are acceptable during loading periods.

### Debug Tools

OWDB includes comprehensive debug functionality that provides detailed system status information, helping you understand exactly what the system is doing at any given moment and identify potential issues quickly.

```gdscript
# Use the built-in debug function for comprehensive system status
$OpenWorldDatabase.debugAll()
```

## Roadmap

Future development focuses on expanding OWDB's capabilities while maintaining its ease of use. Nested OWDB support will enable buildings with detailed interiors that can be independently chunked, providing even more granular control over memory usage. Advanced compression will reduce `.owdb` file sizes and network overhead, while server authority tools will enhance dedicated server capabilities. Cross-platform optimization will improve multiplayer performance across mobile and desktop platforms.

## Contributing

OWDB thrives on community involvement and feedback from developers building real games with the system. You can help by reporting bugs with detailed reproduction steps, suggesting features especially if you're building something that pushes the system's boundaries, submitting pull requests for fixes or improvements, enhancing documentation to help other developers, and sharing projects that use OWDB since we love seeing what the community creates.

## Games Using OWDB

*Building something amazing with OWDB? Let us know and we'll feature it here to inspire other developers!*

## License

MIT License
