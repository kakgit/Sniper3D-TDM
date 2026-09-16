extends CanvasLayer
## Touch controls for phones.
##
## A left virtual stick, a right drag-to-look area and buttons for fire, aim,
## reload, crouch, sprint, jump and the host/join menu. Every control drives the
## project's EXISTING InputMap actions through Input.action_press and
## Input.action_release, so player_controller.gd keeps its movement code exactly
## as it is and sniper_rifle.gd is not touched at all. Look cannot be an action,
## so a drag goes to player_controller.apply_look_delta, the same yaw/pitch math
## and the same pitch clamp the mouse branch uses.
##
## Every touch is read in _input and hit tested here, which is what lets one
## thumb hold the stick while another drags to look. The Button nodes are only
## the layout and look of the controls: the shield and all its children are
## MOUSE_FILTER_IGNORE, so no touch is swallowed by the GUI before it gets here.
##
## The layer hides itself when there is no touchscreen and steps aside while the
## host/join menu holds the screen. It never captures the pointer: Godot mirrors
## every touch as an emulated mouse event and those copies are consumed here, so
## the desktop mouse path is never driven by a finger.

const MOVE_DEADZONE := 0.24      ## stick deflection that counts as a direction
const STICK_TRAVEL := 54.0       ## how far the knob slides inside its pad
const KNOB_REST := Vector2(62.0, 62.0)
const TAP_HOLD := 0.12           ## one-shot actions stay held at least this long
const MOUSE_ID := -2             ## pointer id used for a real mouse drag
## Tap gestures. A press that stays short and still is a tap rather than a look
## drag, and the four combinations of side and count fire whatever the Control
## Settings page bound to them.
const TAP_MAX_TIME := 0.22       ## longer than this and it was a press, not a tap
const TAP_MAX_MOVE := 28.0       ## moved further than this and it was a look
const DOUBLE_WINDOW := 0.28      ## a second tap inside this is a double tap

const CLAIM_STICK := "@stick"    ## pointer claims, kept apart from action names
const CLAIM_LOOK := "@look"
const CLAIM_MENU := "@menu"
const CLAIM_TOGGLE := "@toggle"  ## a latched button, let go by a later tap
## Which half of the screen a tap landed on. The look area owns the right half,
## so a tap there and a tap on the empty left are different gestures.
const SIDE_LEFT := "left"
const SIDE_RIGHT := "right"
## Which button drives which existing action.
const BUTTON_ACTIONS := {
	"FireButton": "shoot",
	"AimButton": "aim",
	"CrouchButton": "crouch",
	"SprintButton": "sprint",
	"ReloadButton": "reload",
	"JumpButton": "jump",
}
const MENU_BUTTON := "MenuButton"
## One-shot actions: pressed on touch down, let go by a short timer. The rest are
## held for as long as the finger stays on the button. The stick owns the last
## four itself.
const TAP_ACTIONS := ["reload", "jump"]
## Latched actions: one tap presses them and they stay pressed until the next tap
## on the same button. sniper_rifle.gd polls aim with Input.is_action_pressed, so
## a latch holds the scope up and leaves the right thumb free to drag and fire.
const TOGGLE_ACTIONS := ["aim"]
const MOVE_ACTIONS := ["move_forward", "move_back", "move_left", "move_right"]

@export var force_visible := false   ## preview the layout on a desktop machine
@export var stick_radius := 62.0     ## drag distance that means full deflection
@export var look_scale := 1.5        ## a thumb is coarser than a mouse, so its
                                     ## drag is scaled before the shared math
@export var edit_mode := false       ## the Control Settings drag editor: a touch
                                     ## moves a control instead of firing it

var _shield: Control
var _pad: Control
var _knob: Control
var _look_area: Control
var _menu_button: Control
var _buttons: Array = []             ## every control button, for hit testing
var _button_actions: Dictionary = {} ## action -> Button
var _normal_styles: Dictionary = {}  ## Button -> its normal stylebox
var _menu: Node
var _shown := true                   ## CanvasLayer.visible before the first frame

var _pointer_claim: Dictionary = {}  ## pointer index -> claim or action name
var _held: Dictionary = {}           ## actions pressed through the InputMap
var _tap_left: Dictionary = {}       ## actions waiting out their tap release
var _latched: Dictionary = {}        ## toggle actions held between taps

var _stick_index := -1
var _stick_origin := Vector2.ZERO
var _stick_local := Vector2.ZERO
var _stick_down := false
var _look_index := -1
var _look_down := false

## Tap gestures, loaded from the Control Settings page. Empty action = the
## gesture does nothing, which is how every gesture starts except the two
## defaults in TouchConfig.
var _gestures: Dictionary = {}
var _press_at: Dictionary = {}        ## pointer -> when it landed
var _press_side: Dictionary = {}      ## pointer -> WHICH HALF it landed on
var _press_moved: Dictionary = {}     ## pointer -> how far it has travelled
var _last_tap_at: Dictionary = {}     ## side -> time of that side's last tap
var _pending_tap: Dictionary = {}     ## side -> [action, seconds left to wait]

## The drag editor. _defaults holds the scene's authored anchors and offsets so
## RESET TO DEFAULTS can put them back without reloading anything.
var _defaults: Dictionary = {}
var _drag_control: Control = null
var _drag_index := -1

func _ready() -> void:
	_shield = get_node_or_null("Shield") as Control
	_pad = get_node_or_null("Shield/MovePad") as Control
	_knob = get_node_or_null("Shield/MovePad/Knob") as Control
	_look_area = get_node_or_null("Shield/LookArea") as Control
	_menu_button = get_node_or_null("Shield/MenuButton") as Control
	_collect_buttons()
	# The authored layout is kept before anything overwrites it, so RESET TO
	# DEFAULTS can restore it without reloading the scene.
	_capture_defaults()
	_gestures = TouchConfig.load_gestures()
	# A saved layout wins over the authored one, in the game and in the editor,
	# so the settings page opens showing the coordinates actually in use.
	apply_layout(TouchConfig.load_layout())
	_set_stick_offset(Vector2.ZERO)
	_refresh_visible()

func _process(delta: float) -> void:
	_refresh_visible()
	if not visible:
		return
	_tick_taps(delta)
	_tick_gestures(delta)
	_release_orphans()

func _exit_tree() -> void:
	# never leave an action stuck down because the layer went away mid press
	_reset_input()

func _notification(what: int) -> void:
	# a call, a home button or an alt-tab can swallow the release, so the whole
	# touch state is dropped when the app loses focus
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_reset_input()


## Shown only where a finger can reach the screen, plus the optional desktop
## preview. While the host/join menu holds the screen it steps out of the way,
## so the menu keeps every touch it needs.
func _refresh_visible() -> void:
	var want := force_visible or DisplayServer.is_touchscreen_available()
	if want and _blocking_ui_open():
		want = false
	if want == _shown:
		return
	_shown = want
	visible = want
	if _shield:
		# the layer hides the drawing, this drops the Controls out of the scene
		_shield.visible = want
	if not want:
		_reset_input()

func _blocking_ui_open() -> bool:
	var tree := get_tree()
	return tree != null and not tree.get_nodes_in_group("blocking_ui").is_empty()


# --- actions ------------------------------------------------------------------
func _press(action: String) -> void:
	if _held.has(action):
		return
	_held[action] = true
	Input.action_press(action)
	_set_button_down(action, true)

func _release(action: String) -> void:
	if not _held.has(action):
		return
	_held.erase(action)
	Input.action_release(action)
	_set_button_down(action, false)

## Taps a latched action on or off. The button keeps its pressed style while the
## latch is on, which is the player's only cue that the scope is still engaged.
func _toggle(action: String) -> void:
	if _latched.has(action):
		_latched.erase(action)
		_release(action)
		return
	_latched[action] = true
	_press(action)

## Safety net: an action is let go unless a live pointer still owns it, so a
## missed release can never leave the trigger or the trigger finger stuck.
func _release_orphans() -> void:
	if _held.is_empty():
		return
	var live: Dictionary = {}
	for claim in _pointer_claim.values():
		live[String(claim)] = true
	for action in _held.keys():
		if _tap_left.has(action):
			continue  ## the tap timer releases these
		if _latched.has(action):
			continue  ## a toggle holds these until it is tapped again
		if _stick_down and MOVE_ACTIONS.has(action):
			continue
		if live.has(action):
			continue
		_release(action)


## keys() hands back a copy, so releasing inside the loop is safe.
func _tick_taps(delta: float) -> void:
	for action in _tap_left.keys():
		var left: float = float(_tap_left[action]) - delta
		if left > 0.0:
			_tap_left[action] = left
			continue
		_tap_left.erase(action)
		_release(action)


# --- touch input --------------------------------------------------------------

## One entry point for touches and, on a machine without a touchscreen, for a
## mouse so the layout can be previewed with force_visible.
func _input(event: InputEvent) -> void:
	if _shield == null or not _shield.visible:
		return
	if event.device == InputEvent.DEVICE_ID_EMULATION:
		# Godot mirrors every touch as an emulated mouse event as well. The real
		# touch already drove these controls, so the copy is swallowed here: it
		# must not reach the desktop mouse look or the click that captures the
		# pointer, and it must not double up on a button.
		get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		if _handle_press(event.pressed, event.index, event.position):
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if _handle_drag(event.index, event.relative):
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if _handle_press(event.pressed, MOUSE_ID, event.position):
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		if DisplayServer.is_touchscreen_available():
			return  ## a real mouse on a touch machine keeps its desktop look
		if _handle_drag(MOUSE_ID, event.relative):
			get_viewport().set_input_as_handled()


## Input positions arrive in viewport space, the rects live in the shield's own
## space. Converting keeps the hit tests right under any stretch or scale.
func _to_shield(p: Vector2) -> Vector2:
	return _shield.get_global_transform_with_canvas().affine_inverse() * p


## The same conversion for a direction: rotation and scale, no origin shift.
func _to_shield_dir(v: Vector2) -> Vector2:
	return _shield.get_global_transform_with_canvas().basis_xform(v)

func _handle_press(pressed: bool, index: int, position: Vector2) -> bool:
	var p := _to_shield(position)
	if pressed:
		if edit_mode:
			return _edit_claim(p, index)
		_press_at[index] = Time.get_ticks_msec() / 1000.0
		_press_moved[index] = 0.0
		# Which half the finger landed on decides which tap gesture it is.
		_press_side[index] = SIDE_LEFT if p.x < _shield.size.x * 0.5 else SIDE_RIGHT
		if _claim(p, index):
			# A finger on the look area is a look first and a tap second, so it
			# is tracked too and only counts as a tap if it barely moved.
			if String(_pointer_claim.get(index, "")) != CLAIM_LOOK:
				_press_at.erase(index)
				_press_moved.erase(index)
			return true
		return true
	if edit_mode:
		return _edit_release(index)
	if _pointer_claim.has(index):
		var claim := String(_pointer_claim[index])
		if claim == CLAIM_LOOK:
			_finish_tap(index, true)
		_press_at.erase(index)
		_press_moved.erase(index)
		return _release_claim(index)
	_finish_tap(index, false)
	_press_at.erase(index)
	_press_moved.erase(index)
	return false


## Works out what a newly landed finger got hold of: the stick, one of the
## buttons, or the empty look area on the right.
func _claim(p: Vector2, index: int) -> bool:
	if not _stick_down and _is_stick_point(p):
		_stick_down = true
		_stick_index = index
		_stick_origin = p
		_stick_local = p
		_pointer_claim[index] = CLAIM_STICK
		_set_stick_offset(Vector2.ZERO)
		return true
	if _menu_button != null and _menu_button.get_rect().grow(10.0).has_point(p):
		_pointer_claim[index] = CLAIM_MENU
		_set_down_control(_menu_button, true)
		_open_menu()
		return true
	var action := _action_at(p)
	if action != "":
		if TOGGLE_ACTIONS.has(action):
			_toggle(action)
			_pointer_claim[index] = CLAIM_TOGGLE
			return true
		_pointer_claim[index] = action
		_press(action)
		if TAP_ACTIONS.has(action):
			_tap_left[action] = TAP_HOLD
		return true
	if not _look_down and _is_look_point(p):
		_look_down = true
		_look_index = index
		_pointer_claim[index] = CLAIM_LOOK
		return true
	return false

func _release_claim(index: int) -> bool:
	if not _pointer_claim.has(index):
		return false
	var claim := String(_pointer_claim[index])
	_pointer_claim.erase(index)
	if claim == CLAIM_STICK:
		_stick_down = false
		_stick_index = -1
		_set_stick_offset(Vector2.ZERO)
	elif claim == CLAIM_MENU:
		_set_down_control(_menu_button, false)
	elif claim == CLAIM_LOOK:
		_look_down = false
		_look_index = -1
	elif claim == CLAIM_TOGGLE:
		pass  ## the latch outlives the finger that set it
	else:
		_release(claim)
	return true

func _handle_drag(index: int, relative: Vector2) -> bool:
	if edit_mode:
		return _edit_drag(index, relative)
	# how far this finger has travelled since it landed, which is what separates
	# a tap gesture from a look drag
	if _press_moved.has(index):
		_press_moved[index] = float(_press_moved[index]) + relative.length()
	if _stick_down and index == _stick_index:
		# a drag carries only its delta, so the thumb is tracked by adding each
		# delta to where it was last seen
		_stick_local += _to_shield_dir(relative)
		_set_stick_offset(_stick_local - _stick_origin)
		return true
	if _look_down and index == _look_index:
		_apply_look(relative)
		return true
	return false


# --- stick --------------------------------------------------------------------

## Stick vector, 1.0 at stick_radius. Moves the knob and drives the four
## movement actions, so player_controller.gd reads them exactly as it reads WASD.
func _set_stick_offset(offset: Vector2) -> void:
	var v := offset.limit_length(stick_radius) / stick_radius
	if _knob:
		_knob.position = KNOB_REST + v * STICK_TRAVEL
	_set_action("move_forward", v.y < -MOVE_DEADZONE)
	_set_action("move_back", v.y > MOVE_DEADZONE)
	_set_action("move_left", v.x < -MOVE_DEADZONE)
	_set_action("move_right", v.x > MOVE_DEADZONE)

func _set_action(action: String, want: bool) -> void:
	if want == _held.has(action):
		return
	if want:
		_press(action)
	else:
		_release(action)


# --- hit tests ----------------------------------------------------------------

## Hit tests in the shield's own coordinates: the pad, the look area and the
## buttons are its children, so their rects are already in that space.
func _is_stick_point(p: Vector2) -> bool:
	if _pad == null:
		return false
	return _pad.get_rect().grow(18.0).has_point(p)


## Buttons sit inside the look area, so they are tested first: a finger meant
## for FIRE must never start a look drag on the way in.
func _is_look_point(p: Vector2) -> bool:
	if _is_button_point(p):
		return false
	if _look_area != null:
		return _look_area.get_rect().has_point(p)
	return p.x > _shield.size.x * 0.5

func _is_button_point(p: Vector2) -> bool:
	for c in _buttons:
		var ctrl := c as Control
		if ctrl != null and ctrl.get_rect().grow(12.0).has_point(p):
			return true
	return false

func _action_at(p: Vector2) -> String:
	for action in _button_actions.keys():
		var b := _button_actions[action] as Control
		if b != null and b.get_rect().grow(10.0).has_point(p):
			return String(action)
	return ""

func _collect_buttons() -> void:
	_buttons.clear()
	_button_actions.clear()
	_normal_styles.clear()
	if _shield == null:
		return
	for c in _shield.get_children():
		var b := c as Button
		if b == null:
			continue
		_buttons.append(b)
		_normal_styles[b] = b.get_theme_stylebox("normal")
		var action := String(BUTTON_ACTIONS.get(String(b.name), ""))
		if action != "":
			_button_actions[action] = b


## Presses and releases are drawn by swapping the button's normal stylebox for
## its pressed one, because a non-toggle Button ignores button_pressed.
func _set_button_down(action: String, down: bool) -> void:
	if _button_actions.has(action):
		_set_down_control(_button_actions[action] as Control, down)

func _set_down_control(b: Control, down: bool) -> void:
	if b == null:
		return
	if down:
		b.add_theme_stylebox_override("normal", b.get_theme_stylebox("pressed"))
	elif _normal_styles.has(b):
		b.add_theme_stylebox_override("normal", _normal_styles[b])


# --- look ---------------------------------------------------------------------

## Hands the raw drag delta to the player controller, which applies the same
## yaw/pitch math as the mouse and refuses when this peer does not own the body.
func _apply_look(relative: Vector2) -> void:
	if relative == Vector2.ZERO:
		return
	var p := _local_player()
	if p == null or not p.has_method("apply_look_delta"):
		return
	p.apply_look_delta(relative * look_scale)

func _local_player() -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if p is Node and p.is_multiplayer_authority():
			return p
	return null


# --- menu ---------------------------------------------------------------------

## The same panel the MULTIPLAYER button opens. The layer hides itself while the
## panel is up, so the menu keeps the whole screen to itself.
func _open_menu() -> void:
	var menu := _find_menu()
	if menu == null:
		return
	menu.open_menu()
	_refresh_visible()

func _find_menu() -> Node:
	if _menu != null and is_instance_valid(_menu):
		return _menu
	var root := get_tree().current_scene
	if root == null:
		root = get_parent()
	_menu = _find_with_method(root, "open_menu")
	return _menu

func _find_with_method(node: Node, method: String) -> Node:
	if node == null:
		return null
	if node.has_method(method):
		return node
	for c in node.get_children():
		var found := _find_with_method(c, method)
		if found != null:
			return found
	return null

func _reset_input() -> void:
	_stick_down = false
	_stick_index = -1
	_look_down = false
	_look_index = -1
	_stick_origin = Vector2.ZERO
	_stick_local = Vector2.ZERO
	_pointer_claim.clear()
	_set_down_control(_menu_button, false)
	for action in _button_actions.keys():
		_set_button_down(String(action), false)
	_set_stick_offset(Vector2.ZERO)
	for action in _held.keys():
		Input.action_release(String(action))
	_held.clear()
	_tap_left.clear()
	_latched.clear()
	_press_at.clear()
	_press_side.clear()
	_press_moved.clear()
	_pending_tap.clear()
	_drag_control = null
	_drag_index = -1


# --- tap gestures -------------------------------------------------------------
#
# A tap is a press that barely moved and did not last. Which half of the screen
# it landed on names the gesture: left_tap, right_tap, and the same two again
# when a second tap follows inside DOUBLE_GAP. All four are chosen in the Control
# Settings page; nothing here is hardcoded to one action.

## How long a second tap may take to arrive and still count as a double.
const DOUBLE_GAP := 0.28

## Fires a gesture's chosen action. A toggle action latches the way its own button
## does, so a double-tap AIM leaves the scope up. Anything else is a short pulse
## driven through the same press/release pair the buttons use, which keeps
## player_controller.gd and sniper_rifle.gd reading ordinary InputMap actions.
func _fire(action: String) -> void:
	if action == "" or not InputMap.has_action(action):
		return
	if TOGGLE_ACTIONS.has(action):
		_toggle(action)
		return
	if _held.has(action):
		return  ## a finger already holds it; a pulse must not release that
	_press(action)
	_tap_left[action] = TAP_HOLD


## The config key for a tap: which half, and whether it was the second one.
func _gesture_key(side: String, double: bool) -> String:
	var suffix := "_double_tap" if double else "_tap"
	return side + suffix


## Called when a finger lifts that was never claimed by the stick or a button.
## A second tap on the same half inside the window is the double; the single is
## then held back for that window so it is never fired on the way to a double.
func _finish_tap(index: int, fire: bool) -> void:
	if not fire:
		return
	var side := String(_press_side.get(index, ""))
	if side == "":
		return
	var at := float(_press_at.get(index, -999.0))
	var moved := float(_press_moved.get(index, 0.0))
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now - at > TAP_MAX_TIME or moved > TAP_MAX_MOVE:
		return
	if _pending_tap.has(side):
		var pending: Array = _pending_tap[side]
		_pending_tap.erase(side)
		_fire(String(_gestures.get(_gesture_key(side, true), "")))
		return
	_pending_tap[side] = [String(_gestures.get(_gesture_key(side, false), "")), DOUBLE_GAP]


## Counts down the held-back single taps. A double arriving first erases the
## entry, so only a real single ever fires here.
func _tick_gestures(delta: float) -> void:
	if _pending_tap.is_empty():
		return
	for side in _pending_tap.keys():
		var pending: Array = _pending_tap[side]
		var left := float(pending[1]) - delta
		if left > 0.0:
			pending[1] = left
			continue
		_pending_tap.erase(side)
		_fire(String(pending[0]))


# --- drag editor --------------------------------------------------------------
#
# With edit_mode on, a touch moves a control instead of using it: nothing is
# pressed, so dragging FIRE across the screen can never fire the rifle. The same
# rectangles the game hit tests are the ones dragged, so what the player sees in
# the settings page is exactly what they get in a match.

## Every control the player may move, as [name, Control] pairs. LookArea is not
## here on purpose: it is the region that turns a drag into a look, not a button.
func _editable_controls() -> Array:
	var out: Array = []
	for entry in TouchConfig.DRAGGABLE:
		var want := String(entry)
		var ctrl: Control = null
		if want == "MovePad":
			ctrl = _pad
		else:
			ctrl = _button_named(want)
		if ctrl != null:
			out.append([want, ctrl])
	return out


func _button_named(want: String) -> Control:
	for c in _buttons:
		var b := c as Control
		if b != null and String(b.name) == want:
			return b
	return null


## The authored layout, kept before a saved one is applied, so RESET TO DEFAULTS
## can put everything back without reloading the scene.
func _capture_defaults() -> void:
	if _shield == null:
		return
	for entry in _editable_controls():
		_defaults[String(entry[0])] = (entry[1] as Control).position


func _edit_claim(p: Vector2, index: int) -> bool:
	var ctrl := _edit_hit(p)
	if ctrl == null:
		return false
	_drag_control = ctrl
	_drag_index = index
	return true


func _edit_release(index: int) -> bool:
	if _drag_control == null or index != _drag_index:
		return false
	_drag_control = null
	_drag_index = -1
	return true


func _edit_drag(index: int, relative: Vector2) -> bool:
	if _drag_control == null or index != _drag_index:
		return false
	_edit_move_to(_drag_control, _drag_control.get_rect().get_center() + _to_shield_dir(relative))
	return true


func _edit_hit(p: Vector2) -> Control:
	for entry in _editable_controls():
		var ctrl := entry[1] as Control
		if ctrl != null and ctrl.get_rect().has_point(p):
			return ctrl
	return null


## Centres a control on p and keeps all of it on screen, so nothing can be
## dragged off an edge and become impossible to reach again.
func _edit_move_to(ctrl: Control, p: Vector2) -> void:
	if ctrl == null or _shield == null:
		return
	var half := ctrl.size * 0.5
	var margin := 8.0
	var max_x := maxf(half.x + margin, _shield.size.x - half.x - margin)
	var max_y := maxf(half.y + margin, _shield.size.y - half.y - margin)
	var centre := Vector2(
		clampf(p.x, half.x + margin, max_x),
		clampf(p.y, half.y + margin, max_y)
	)
	ctrl.position = centre - half


## Centre of every draggable control as a fraction of the screen. Fractions, not
## pixels: the project stretches with canvas_items/expand, so the number of
## canvas units across the screen changes with the phone's aspect ratio and a
## pixel position would not keep its distance from the edge on another handset.
func get_layout_fractions() -> Dictionary:
	var out := {}
	if _shield == null or _shield.size.x <= 0.0 or _shield.size.y <= 0.0:
		return out
	for entry in _editable_controls():
		var ctrl := entry[1] as Control
		if ctrl.size.x <= 0.0 or ctrl.size.y <= 0.0:
			continue
		out[String(entry[0])] = (ctrl.position + ctrl.size * 0.5) / _shield.size
	return out


func apply_layout(fractions: Dictionary) -> void:
	if _shield == null or fractions.is_empty():
		return
	var size := _shield.size
	for entry in _editable_controls():
		var v: Variant = fractions.get(String(entry[0]), null)
		if v is Vector2:
			_edit_move_to(entry[1] as Control, (v as Vector2) * size)


func reset_layout() -> void:
	if _shield == null:
		return
	for entry in _editable_controls():
		var name := String(entry[0])
		if _defaults.has(name):
			(entry[1] as Control).position = Vector2(_defaults[name])
