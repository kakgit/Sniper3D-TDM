extends CanvasLayer
## The Control Settings page.
##
## Two things live here. DRAG & DROP CONTROL opens a full screen copy of the real
## touch controls with edit_mode on, so a touch moves a control instead of using
## it; the layout the player leaves behind is the one the match will use. The four
## tap gestures each pick an action from a dropdown.
##
## This page reads and writes only through TouchConfig, the same helper the touch
## layer reads when a match starts, so the settings page and the game can never
## disagree about where a control is or what a tap does.

const HOME_SCENE := "res://home.tscn"

## Gesture key -> the OptionButton that chooses its action. The keys are the ones
## TouchConfig stores, so the page writes exactly what the touch layer reads.
const DROPDOWN_NODES := {
	"left_tap": "TapLeftDrop",
	"right_tap": "TapRightDrop",
	"left_double_tap": "TapLeftDoubleDrop",
	"right_double_tap": "TapRightDoubleDrop",
}

var _menu_root: Control
var _editor_root: Control
var _editor: Node
var _hint: Label
var _status: Label
var _dropdowns: Dictionary = {}      ## gesture key -> OptionButton
var _layout_touched := false         ## true once the drag editor was opened
var _back_at := 0.0                  ## when the Android back button last fired


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_menu_root = find_child("MenuRoot", true, false) as Control
	_editor_root = find_child("EditorRoot", true, false) as Control
	_editor = find_child("Editor", true, false)
	_hint = find_child("EditorHint", true, false) as Label
	_status = find_child("StatusLabel", true, false) as Label
	_connect_button("DragDropButton", _on_drag_drop_pressed)
	_connect_button("SaveButton", _on_save_pressed)
	_connect_button("ResetButton", _on_reset_pressed)
	_connect_button("BackButton", _on_back_pressed)
	_connect_button("EditorSaveButton", _on_save_pressed)
	_connect_button("EditorResetButton", _on_reset_pressed)
	_connect_button("EditorBackButton", _on_editor_back_pressed)
	_build_dropdowns()
	_show_menu()
	_refresh()


func _connect_button(node_name: String, handler: Callable) -> void:
	var b := find_child(node_name, true, false) as Button
	if b != null:
		b.pressed.connect(handler)


## Hard rule: escape always releases the cursor, and on this page it also means
## leave, the same as BACK TO HOME.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_on_back_pressed()


## The Android back button steps out of the drag editor first, and only leaves the
## page from the menu. quit_on_go_back is off, so nothing here quits the app by
## accident. Godot can deliver this more than once per press, hence the debounce.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now - _back_at < 0.35:
		return
	_back_at = now
	if _editor_root != null and _editor_root.visible:
		_on_editor_back_pressed()
		return
	_on_back_pressed()


# --- the two views ------------------------------------------------------------


func _show_menu() -> void:
	if _menu_root:
		_menu_root.visible = true
	if _editor_root:
		_editor_root.visible = false


func _on_drag_drop_pressed() -> void:
	_layout_touched = true
	if _menu_root:
		_menu_root.visible = false
	if _editor_root:
		_editor_root.visible = true
	_set_status("")
	_update_hint()


func _on_editor_back_pressed() -> void:
	_show_menu()
	_refresh()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(HOME_SCENE)


## The drag editor is always shown, including on a desktop where the touch layer
## would normally stay out of sight, so the layout can be arranged with a mouse.
func _update_hint() -> void:
	if _hint == null:
		return
	var with_mouse := not DisplayServer.is_touchscreen_available()
	_hint.text = "DRAG ANY CONTROL TO MOVE IT - THEN SAVE"
	if with_mouse:
		_hint.text = "DRAG ANY CONTROL WITH THE MOUSE - THEN SAVE"


# --- gestures -----------------------------------------------------------------


func _build_dropdowns() -> void:
	for key in DROPDOWN_NODES.keys():
		var drop := find_child(String(DROPDOWN_NODES[key]), true, false) as OptionButton
		if drop == null:
			continue
		_dropdowns[String(key)] = drop
		drop.clear()
		for entry in TouchConfig.GESTURE_ACTIONS:
			drop.add_item(String(entry[1]))
	_refresh_dropdowns()


## The dropdowns open showing what is actually stored, defaulting when nothing is.
func _refresh_dropdowns() -> void:
	var current := TouchConfig.load_gestures()
	for key in _dropdowns.keys():
		var drop := _dropdowns[key] as OptionButton
		drop.selected = _index_of_action(String(current.get(String(key), "")))


func _index_of_action(action: String) -> int:
	for i in TouchConfig.GESTURE_ACTIONS.size():
		if String(TouchConfig.GESTURE_ACTIONS[i][0]) == action:
			return i
	return 0


func _selected_gestures() -> Dictionary:
	var out := {}
	for key in _dropdowns.keys():
		var drop := _dropdowns[key] as OptionButton
		var idx: int = drop.selected
		if idx >= 0 and idx < TouchConfig.GESTURE_ACTIONS.size():
			out[String(key)] = String(TouchConfig.GESTURE_ACTIONS[idx][0])
		else:
			out[String(key)] = ""
	return out


# --- saving -------------------------------------------------------------------


## Writes the gestures, and the layout too once the editor has been opened. The
## layout is skipped until then so that saving gestures alone never freezes the
## scene's authored positions in as if the player had chosen them.
func _on_save_pressed() -> void:
	TouchConfig.save_gestures(_selected_gestures())
	if _layout_touched and _editor != null and _editor.has_method("get_layout_fractions"):
		TouchConfig.save_layout(_editor.get_layout_fractions())
	_set_status("SAVED - the match will use these settings.")


## Drops both saved files rather than overwriting them, so the next launch starts
## from the layout the scene was authored with.
func _on_reset_pressed() -> void:
	TouchConfig.clear_layout()
	TouchConfig.clear_gestures()
	if _editor != null and _editor.has_method("reset_layout"):
		_editor.reset_layout()
	_layout_touched = false
	_refresh_dropdowns()
	_set_status("RESET - default layout and gestures restored.")


func _refresh() -> void:
	_refresh_dropdowns()
	if _status != null and _status.text == "":
		_status.text = "Drag and drop the controls, or pick what each tap fires."


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text
