# Open World Database (OWDB) for Godot

A Godot addon that brings efficient world streaming to your indie game, inspired by the massive open worlds of modern RPGs and adventure games. No more choosing between "small interesting world" and "performance nightmare" - now you can have both.

## The Problem: When Worlds Get Too Big

Large, detailed open worlds are incredible to explore, but they present a significant technical challenge. Those expansive landscapes that feel infinite are actually cleverly managed behind the scenes.

In Godot, dropping thousands of objects, AI agents, physics bodies, or nodes into a single scene will severely impact performance. Traditional solutions involve custom LOD systems or splitting your world into separate scenes - all of which break your creative flow and make iteration painful.

**OWDB changes that.**

## The Solution: Smart World Streaming

Open World Database automatically transforms your sprawling world through intelligent chunk-based streaming.

Simply parent your world content to an OWDB node, and the system handles the rest:
- **Batch Processing**: Smooth loading with configurable time limits (no more frame drops)
- **Intelligent Chunking**: Different strategies for different content types
- **Persistent Worlds**: Your world state survives restarts
- **Zero Workflow Disruption**: Works exactly like normal Godot scenes
- **Memory Efficient**: Only loads what players are close to relative to each item's size

## Key Features

### Batch Processing System
Gone are the hitches and stutters! The new batch processing system loads/unloads content over multiple frames:
- Configurable time budgets (default: 5ms per frame)
- Smart operation queuing prevents redundant work
- Smooth performance even with hundreds of objects

### Size-Based Intelligence
Automatic distance-based management system for entire objects:
- **Tiny Props** (small items, decorations): Ultra-fine 8×8m chunks (default)
- **Medium Objects** (characters, furniture): 16×16m chunks (default)
- **Large Structures** (buildings, vehicles): 64×64m chunks (default)
- **Massive Elements** (terrain features, major structures): Always loaded

### O(1) Performance
- Lightning-fast node lookups (no more searching entire trees)
- Cached loaded nodes for instant access
- Optimized chunk operations

### Advanced Database Features
- **Multiple Save States**: Test different world configurations
- **Custom Databases**: Save to user directory to keep user gameplay progress

### Developer-Friendly
- **Editor Integration**: Works seamlessly with Godot's scene system
- **Property Preservation**: All your custom exports and properties survives streaming
- **Live Debug Info**: See exactly what's happening in real-time

## Installation

1. **Download** the addon from the Godot Asset Library or GitHub
2. **Extract** to your project's `addons/` folder
3. **Enable** in Project Settings → Plugins → Open World Database
4. **Ready!** Start building your world

## Using OWDB: From Concept to Implementation

### In the Editor

**Step 1: Set Up Your World**
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
	└── Important Landmarks
```

**Step 2: Configure Your World**
```gdscript
# In the inspector, tune these settings:
@export var size_thresholds: Array[float] = [0.5, 2.0, 8.0]  # Size categories
@export var chunk_sizes: Array[float] = [8.0, 16.0, 64.0]    # Chunk dimensions
@export var chunk_load_range: int = 3                        # View distance
@export var debug_enabled: bool = true                       # See the system work
```

**Step 3: Batch Processing Configuration**
```gdscript
# Fine-tune performance settings
@export var batch_time_limit_ms: float = 5.0    # Max time per frame
@export var batch_interval_ms: float = 100.0    # Time between batches
@export var batch_processing_enabled: bool = true
```

**That's it!** Just parent your content and watch OWDB automatically:
- Generate unique IDs for everything
- Calculate object sizes and assign chunk categories
- Create a `.owdb` database alongside your scene
- Monitor for changes as you work

### In the Game

**Basic Setup:**
```gdscript
extends Node3D

@onready var world_db = $OpenWorldDatabase
@onready var player = $Player

func _ready():
	# Point OWDB at your camera (auto-detects if you don't)
	world_db.camera = player.get_node("Camera3D")
	
	# Optional: Load a specific world state
	# world_db.load_database("custom_world_state")
```

**Advanced Usage:**
```gdscript
# Check what's happening (great for debugging)
func debug_world_state():
	var stats = world_db.batch_processor.get_queue_info()
	print("Loading: ", stats.load_operations_queued, " objects")
	print("Unloading: ", stats.unload_operations_queued, " objects")
	print("Total in world: ", world_db.get_total_database_nodes())
	print("Currently loaded: ", world_db.get_currently_loaded_nodes())

# Save different world states (perfect for testing)
func save_world_variation(name: String):
	world_db.save_database(name)  # Saves to user://name.owdb

# List all saved worlds
func get_saved_worlds() -> Array[String]:
	return world_db.list_custom_databases()
```

### Batch Processing Control
```gdscript
# Pause streaming during intense action
world_db.batch_processor.batch_processing_enabled = false

# Resume with custom settings
world_db.batch_time_limit_ms = 2.0  # Tighter timing during combat
world_db.update_batch_settings()
world_db.batch_processor.batch_processing_enabled = true

# Force immediate loading (use sparingly!)
world_db.batch_processor.force_process_queues()
```

## Best Practices

### Do's ✅
- **Use hierarchical organization** - group related objects under parent nodes
- **Test different chunk ranges** - find your performance sweet spot
- **Save regularly** - OWDB auto-saves when you save the scene. It's easy to read text-based format works great with versioning software like Git
- **Use meaningful node names** - you can rename any node with a simpler name such as 'Gems', 'Town', 'Items'

### Don'ts ❌
- **Don't nest OWDB nodes** (yet - this is planned!)
- **Don't put UI elements** under OWDB - it's for world content only

## Roadmap

- **Nested OWDB Support**: Buildings with detailed interiors that can be independently chunked
- **Compression**: Smaller `.owdb` files for distribution and to hide spoilers
- **Multiplayer Support**: Synchronized world streaming for online games

## Contributing

Found a bug? Have an idea? Want to improve the system?

We welcome contributions! This addon is built by a developer, for developers. Whether you're fixing typos or adding major features, every contribution makes OWDB better.

**Ways to help:**
- Report bugs with detailed reproduction steps
- Suggest features (especially if you're building something interesting)
- Submit pull requests (check the issues for good first contributions)
- Improve documentation
- Share your projects using OWDB (we love seeing what you create)

## Games Using OWDB

*Building something amazing? Let us know and we'll feature it here!*

## License

MIT License

---
