extends Control

var player: Node
var terrain: Terrain3D
var visible_mode: int = 1
var loaded_count := 0
var shift_text := ""
const BYTES_TO_GB := pow(1024, 3)


func _init() -> void:
	RenderingServer.set_debug_generate_wireframes(true)


func _process(_p_delta) -> void:
	$Label.text = "FPS: %d\n" % Engine.get_frames_per_second()
	var virtual_pos := Vector3(0, 0, 0)
	var virtual_loc := Vector2i(0, 0)
	var unload := true
	if terrain and player:
		var relative_origin = get_parent().relative_origin
		virtual_pos = player.global_position + Vector3(relative_origin.x * 1024, 0, relative_origin.y * 1024)
		virtual_loc = terrain.data.get_region_location(player.global_position) + relative_origin
		unload = get_parent().unload_cache
		
	if(visible_mode == 1):
		$Label.text += "Move Speed: %.1f\n" % player.MOVE_SPEED if player else ""
		$Label.text += "Position\n"
		$Label.text += "  Real     : %.1v\n" % player.global_position if player else ""
		$Label.text += "  Virtual: %.1v\n" % virtual_pos
		$Label.text += "Region\n"
		$Label.text += "  Real     : %.1v\n" % terrain.data.get_region_location(player.global_position) if terrain and player else ""
		$Label.text += "  Virtual: %.1v\n" % virtual_loc
		$Label.text += "RAM Cached Regions: " + str(loaded_count) + "\n"
		$Label.text += "RAM Occupied: %.3fGB\n" % (OS.get_static_memory_usage() / BYTES_TO_GB)
		$Label.text += "Cache Unloading: " + ("On" if unload else "Off") + "\n"
		$Label.text += shift_text + "\n\n"
		$Label.text += """
			Player
			Move: WASDEQ,Space,Mouse
			Move speed: Wheel,+/-,Shift
			Camera View: V
			Gravity toggle: G
			Collision toggle: C

			Window
			Quit: F8
			UI toggle: F9
			Render mode: F10
			Full screen: F11
			Mouse toggle: Escape / F12
			"""


func _unhandled_key_input(p_event: InputEvent) -> void:
	if p_event is InputEventKey and p_event.pressed:
		match p_event.keycode:
			KEY_F8:
				get_tree().quit()
			KEY_F9:
				visible_mode = (visible_mode + 1 ) % 3
				$Label/Panel.visible = (visible_mode == 1)
				visible = visible_mode > 0
			KEY_F10:
				var vp = get_viewport()
				vp.debug_draw = (vp.debug_draw + 1 ) % 6
				get_viewport().set_input_as_handled()
			KEY_F11:
				toggle_fullscreen()
				get_viewport().set_input_as_handled()
			KEY_ESCAPE, KEY_F12:
				if Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE:
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				else:
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				get_viewport().set_input_as_handled()
		
		
func toggle_fullscreen() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN or \
		DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2(1280, 720))
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
