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

const CLAIM_STICK := "@stick"    ## pointer claims, kept apart from action names
const CLAIM_LOOK := "@look"
const CLAIM_MENU := "@menu"
const CLAIM_TOGGLE := "@toggle"  ## a latched button, let go by a later tap
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

func _ready() -> void:
	_shield = get_node_or_null("Shield") as Control
	_pad = get_node_or_null("Shield/MovePad") as Control
	_knob = get_node_or_null("Shield/MovePad/Knob") as Control
	_look_area = get_node_or_null("Shield/LookArea") as Control
	_menu_button = get_node_or_null("Shield/MenuButton") as Control
	_collect_buttons()
	_set_stick_offset(Vector2.ZERO)
	_refresh_visible()

func _process(delta: float) -> void:
	_refresh_visible()
	if not visible:
		return
	_tick_taps(delta)
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
	if pressed:
		return _claim(_to_shield(position), index)
	return _release_claim(index)


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
