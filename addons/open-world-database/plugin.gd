@tool
extends EditorPlugin

func _enter_tree():
	add_custom_type("OpenWorldDatabase", "Node", preload("src/open_world_database.gd"), preload("OWDB.svg"))
	add_custom_type("OWDBPosition", "Node", preload("src/OWDBPosition.gd"), preload("OWDBPosition.svg"))
	add_custom_type("OWDBSync", "Node", preload("src/network/OWDBSync.gd"), preload("OWDBSync.svg"))

func _exit_tree():
	remove_custom_type("OpenWorldDatabase")
	remove_custom_type("OWDBPosition")
	remove_custom_type("OWDBSync")
