@tool
extends EditorPlugin

func _enter_tree():
	add_custom_type("OpenWorldDatabase", "Node", preload("src/open_world_database.gd"), preload("icon.svg"))
	add_autoload_singleton("Syncer", "res://addons/open-world-database/src/network/Syncer.gd")

func _exit_tree():
	remove_custom_type("OpenWorldDatabase")
	remove_autoload_singleton("Syncer")
