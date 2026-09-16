extends Control
## The app's front page.
##
## The project opens here instead of straight into the arena, so the match does
## not start behind a menu: the bots, the match clock and the player's mouse
## capture all begin only once DEPLOY is pressed and main.tscn loads.
##
## Every control is an ordinary Button or LineEdit, so a touch screen works with
## no keyboard at all. The account panel is the very same auth_screen.tscn the
## in-game menu uses, instanced here under the name "Auth".

const GAME_SCENE := "res://main.tscn"
## The Control Settings page. Reachable once signed in, per the design.
const CONTROLS_SCENE := "res://control_settings.tscn"

var _auth: Node
var _auth_screen: Node
var _status: Label
var _deploy_button: Button
var _account_button: Button
var _quit_button: Button
var _controls_button: Button
var _back_at := 0.0               ## when the Android back button last fired


func _ready() -> void:
	# Nothing on this page captures the cursor, so it stays visible here.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_status = find_child("StatusLabel", true, false) as Label
	_deploy_button = find_child("DeployButton", true, false) as Button
	_account_button = find_child("AccountButton", true, false) as Button
	_quit_button = find_child("QuitButton", true, false) as Button
	_controls_button = find_child("ControlsButton", true, false) as Button
	if _deploy_button:
		_deploy_button.pressed.connect(_on_deploy_pressed)
	if _account_button:
		_account_button.pressed.connect(_on_account_pressed)
	if _quit_button:
		_quit_button.pressed.connect(_on_quit_pressed)
	if _controls_button:
		_controls_button.pressed.connect(_on_controls_pressed)
	_auth_screen = find_child("Auth", true, false)
	if _auth_screen != null and _auth_screen.has_signal("closed"):
		_auth_screen.closed.connect(_refresh)
	# AuthClient is an autoload, so a signed-in session survives the scene
	# change into the match and back out again.
	_auth = get_node_or_null("/root/AuthClient")
	if _auth != null:
		if _auth.has_signal("signed_in"):
			_auth.signed_in.connect(_on_auth_changed)
		if _auth.has_signal("signed_out"):
			_auth.signed_out.connect(_on_auth_changed)
	_refresh()


## Hard rule: escape always leaves the cursor usable.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## The Android back button. quit_on_go_back is off, which stops Godot killing the
## app on that press, so the front page keeps the normal phone behaviour itself:
## back here means leave. Godot can deliver this notification more than once for
## a single press, so a repeat inside the debounce window is ignored - without it
## one press would close the panel and then quit the app anyway.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now - _back_at < 0.35:
		return
	_back_at = now
	if _auth_screen != null and _auth_screen.visible:
		if _auth_screen.has_method("close"):
			_auth_screen.close()
		return
	get_tree().quit()


func _on_deploy_pressed() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_account_pressed() -> void:
	if _auth_screen != null and _auth_screen.has_method("open"):
		_auth_screen.open()
	_refresh()


## Opens the Control Settings page: the drag-and-drop control editor and the
## tap gesture dropdowns.
func _on_controls_pressed() -> void:
	get_tree().change_scene_to_file(CONTROLS_SCENE)


func _on_quit_pressed() -> void:
	get_tree().quit()


## signed_in carries two arguments and signed_out carries none, so this takes
## neither: a callable with fewer parameters than the signal is valid for both.
func _on_auth_changed() -> void:
	_refresh()


func _refresh() -> void:
	var signed := _auth != null and bool(_auth.is_signed_in())
	if _account_button:
		if signed:
			_account_button.text = "ACCOUNT: %s" % String(_auth.username())
		else:
			_account_button.text = "ACCOUNT"
	# The Control Settings page belongs to a signed-in player, so its button only
	# appears once there is an account to attach the settings to.
	if _controls_button:
		_controls_button.visible = signed
	if _status == null:
		return
	if signed:
		_status.text = "Signed in as %s" % String(_auth.username())
	elif _auth != null and not bool(_auth.is_configured()):
		_status.text = "Accounts unavailable: no server configured"
	else:
		_status.text = "Playing as a guest"
