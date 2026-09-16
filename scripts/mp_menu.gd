extends CanvasLayer
## Minimal LAN host/join menu.
##
## Every control here is an ordinary Control button, so a touch screen can press
## it without a keyboard. The panel is only shown on request, and the mouse is
## forced visible while it is open: capturing the cursor is reserved for
## actually playing.

const BLOCK_GROUP := "blocking_ui"
const HOME_SCENE := "res://home.tscn"

var _panel: Control
var _menu_button: Button
var _status: Label
var _net_status: Label
var _address: LineEdit
var _host_button: Button
var _join_button: Button
var _leave_button: Button
var _close_button: Button
var _account_button: Button
var _quit_button: Button
var _auth_screen: Node
var _lan: Node
var _back_at := 0.0               ## when the Android back button last fired


func _ready() -> void:
	_panel = find_child("MenuPanel", true, false) as Control
	_menu_button = find_child("MenuButton", true, false) as Button
	_status = find_child("StatusLine", true, false) as Label
	_net_status = find_child("NetStatus", true, false) as Label
	_address = find_child("AddressField", true, false) as LineEdit
	_host_button = find_child("HostButton", true, false) as Button
	_join_button = find_child("JoinButton", true, false) as Button
	_leave_button = find_child("LeaveButton", true, false) as Button
	_close_button = find_child("CloseButton", true, false) as Button
	_account_button = find_child("AccountButton", true, false) as Button
	_quit_button = find_child("QuitButton", true, false) as Button
	if _host_button:
		_host_button.pressed.connect(_on_host_pressed)
	if _join_button:
		_join_button.pressed.connect(_on_join_pressed)
	if _leave_button:
		_leave_button.pressed.connect(_on_leave_pressed)
	if _close_button:
		_close_button.pressed.connect(_on_close_pressed)
	if _account_button:
		_account_button.pressed.connect(_on_account_pressed)
	if _quit_button:
		_quit_button.pressed.connect(_on_quit_pressed)
	# The account panel is a child of this scene, so it is found rather than
	# looked up by an absolute path that would break if the tree moved.
	_auth_screen = find_child("Auth", true, false)
	if _auth_screen != null and _auth_screen.has_signal("closed"):
		_auth_screen.closed.connect(_refresh)
	_lan = get_node_or_null("/root/NetworkManager")
	if _lan != null:
		if _lan.has_signal("state_changed"):
			_lan.state_changed.connect(_refresh)
		if _lan.has_signal("client_connected"):
			_lan.client_connected.connect(_on_client_connected)
		if _lan.has_signal("session_ended"):
			_lan.session_ended.connect(_refresh)
	# Boot state is exactly the old single-player state: no panel, no blocking
	# UI, cursor captured by the player.
	_set_panel_open(false)
	_refresh()


## Hard rule: escape always frees the cursor, whatever is on screen.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## The Android back button. Project setting application/config/quit_on_go_back is
## off, so Godot no longer kills the app on that press and leaving the match is
## ours to do on purpose. Godot can deliver this notification more than once for
## a single press, so a repeat inside the debounce window is ignored - otherwise
## one press would reveal the QUIT button and the echo would hide it again.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_request()


## Back closes whatever is on top of the match. With nothing open it reveals the
## QUIT button instead of leaving the match by accident, which is what the back
## button used to do when Godot quit the app for us. Escape and the corner
## MULTIPLAYER button still behave exactly as they did.
func _on_back_request() -> void:
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now - _back_at < 0.35:
		return
	_back_at = now
	if _panel_is_open():
		_set_panel_open(false)
		return
	if _auth_is_open():
		if _auth_screen.has_method("close"):
			_auth_screen.close()
		_refresh()
		return
	_set_quit_visible(not _quit_is_visible())


func _quit_is_visible() -> bool:
	return _quit_button != null and _quit_button.visible


## The QUIT button is the only deliberate way out of a match. It is drawn at the
## top of the layer so it covers everything behind it, the cursor is freed so a
## phone can press it, and it joins blocking_ui so the touch layer steps aside
## rather than swallowing the tap.
func _set_quit_visible(show_it: bool) -> void:
	if _quit_button:
		_quit_button.visible = show_it
	if show_it:
		if not is_in_group(BLOCK_GROUP):
			add_to_group(BLOCK_GROUP)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif not _panel_is_open():
		if is_in_group(BLOCK_GROUP):
			remove_from_group(BLOCK_GROUP)
		var local := _local_player()
		if local != null and local.has_method("claim_local_view"):
			local.claim_local_view()
	_refresh()


## Leaves the match for the front page. A live session is closed first, so no
## peer is left waiting on a player who has gone.
func _on_quit_pressed() -> void:
	if _lan != null and _is_online() and _lan.has_method("leave_game"):
		_lan.leave_game()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(HOME_SCENE)


func _process(_delta: float) -> void:
	var cursor_free := Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	var show_buttons := cursor_free and not _panel_is_open() and not _auth_is_open() and not _quit_is_visible()
	if _menu_button:
		_menu_button.visible = show_buttons
	if _account_button:
		_account_button.visible = show_buttons
	_refresh()


func _panel_is_open() -> bool:
	return _panel != null and _panel.visible


## Shows or hides the panel. While it is open the cursor is visible and the
## local player is told to leave the mouse alone.
func _set_panel_open(open: bool) -> void:
	if _panel:
		_panel.visible = open
	if open:
		if not is_in_group(BLOCK_GROUP):
			add_to_group(BLOCK_GROUP)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		if is_in_group(BLOCK_GROUP):
			remove_from_group(BLOCK_GROUP)
		var local := _local_player()
		if local != null and local.has_method("claim_local_view"):
			local.claim_local_view()


## Public entry point for the on-screen touch layer: opens the same panel the
## MULTIPLAYER button opens.
func open_menu() -> void:
	_set_panel_open(true)
	_refresh()


func _refresh() -> void:
	var text := "LAN sessions unavailable"
	if _lan != null:
		text = String(_lan.status)
	if _status:
		_status.text = text
	var online := _is_online()
	if _net_status:
		# the transport status is already in StatusLine above, so this line
		# carries the room itself: how full it is and which side you are on
		_net_status.text = _room_text() if online else ""
		_net_status.visible = online
	if _leave_button:
		_leave_button.visible = online
	if _account_button:
		_account_button.text = _account_button_text()


## The room tally the server publishes, plus the side this player is on.
func _room_text() -> String:
	var line := ""
	if _lan != null and _lan.has_method("room_line"):
		line = String(_lan.room_line())
	var mine := _local_player()
	if mine != null:
		var side := "ALPHA" if int(mine.get("team")) == 0 else "BRAVO"
		line += "   -   you are %s" % side
	return line


func _is_online() -> bool:
	return _lan != null and bool(_lan.is_online())


## The player body this peer owns, wherever it lives in the tree.
func _local_player() -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if p is Node and p.is_multiplayer_authority():
			return p
	return null


func _on_host_pressed() -> void:
	if _lan == null:
		return
	if bool(_lan.host_game()):
		_set_panel_open(false)
	_refresh()


## The panel stays open while the handshake runs so the status line can report
## CONNECTING, and closes itself once the connection is actually up.
func _on_join_pressed() -> void:
	if _lan == null:
		return
	var target := ""
	if _address:
		target = _address.text.strip_edges()
	_lan.join_game(target)
	_refresh()


func _on_client_connected() -> void:
	_set_panel_open(false)
	_refresh()


func _on_leave_pressed() -> void:
	if _lan == null:
		return
	_lan.leave_game()
	_refresh()


func _on_close_pressed() -> void:
	_set_panel_open(false)
	_refresh()


## Opens the account panel. The multiplayer panel closes first, so only one
## blocking panel is ever on screen and the cursor is free for typing.
func _on_account_pressed() -> void:
	if _auth_screen == null:
		return
	_set_panel_open(false)
	_auth_screen.open()
	_refresh()


func _auth_is_open() -> bool:
	return _auth_screen != null and _auth_screen.visible


## The button doubles as a signed-in indicator, so the player can see which
## account the game will use without opening the panel.
func _account_button_text() -> String:
	var auth := get_node_or_null("/root/AuthClient")
	if auth != null and bool(auth.is_signed_in()):
		return "ACCOUNT: %s" % String(auth.username()).to_upper()
	return "ACCOUNT: SIGN IN"
