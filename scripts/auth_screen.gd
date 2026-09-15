extends CanvasLayer
## Sign in / create account panel, driven by the AuthClient autoload.
##
## Opened from the multiplayer menu's ACCOUNT button. Everything here is an
## ordinary Control, so touch works, and it never captures the mouse - looking
## around is reserved for actually playing.
##
## All validation that matters lives on the server, which knows the real rules
## (username 3-20 characters, password 8 or more). This screen only checks that
## the fields are not empty, so the server's own message is what the player
## reads when a name is taken or too short.

signal closed()

var _user: LineEdit
var _pass: LineEdit
var _register: Button
var _login: Button
var _sign_out: Button
var _status: Label
var _close: Button
var _auth: Node


func _ready() -> void:
	_user = find_child("UsernameField", true, false) as LineEdit
	_pass = find_child("PasswordField", true, false) as LineEdit
	_register = find_child("RegisterButton", true, false) as Button
	_login = find_child("LoginButton", true, false) as Button
	_sign_out = find_child("SignOutButton", true, false) as Button
	_status = find_child("StatusLine", true, false) as Label
	_close = find_child("CloseButton", true, false) as Button

	if _register:
		_register.pressed.connect(_on_register_pressed)
	if _login:
		_login.pressed.connect(_on_login_pressed)
	if _sign_out:
		_sign_out.pressed.connect(_on_sign_out_pressed)
	if _close:
		_close.pressed.connect(close)

	_auth = get_node_or_null("/root/AuthClient")
	if _auth != null:
		_auth.signed_in.connect(_on_signed_in)
		_auth.signed_out.connect(_on_signed_out)
		_auth.auth_failed.connect(_on_auth_failed)
		_auth.busy_changed.connect(_on_busy_changed)

	visible = false
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	# Escape closes this panel. The cursor is never captured here, but the
	# multiplayer menu behind it relies on escape being handled the same way.
	if visible and event.is_action_pressed("ui_cancel"):
		close()


# --- open / close ----------------------------------------------------------


func open() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh()
	if _user and not _is_signed_in():
		_user.grab_focus()


func close() -> void:
	visible = false
	closed.emit()


# --- buttons ---------------------------------------------------------------


func _on_register_pressed() -> void:
	_submit("register")


func _on_login_pressed() -> void:
	_submit("login")


func _on_sign_out_pressed() -> void:
	if _auth != null:
		_auth.log_out()


func _submit(what: String) -> void:
	if _auth == null:
		_set_status("the accounts client is missing from this build", true)
		return
	var username := _user.text.strip_edges() if _user else ""
	var password := _pass.text if _pass else ""
	if username.is_empty() or password.is_empty():
		_set_status("enter a username and a password", true)
		return
	_set_status("creating the account..." if what == "register" else "signing in...", false)
	if what == "register":
		_auth.register_user(username, password)
	else:
		_auth.log_in(username, password)


# --- client callbacks ------------------------------------------------------


func _on_signed_in(user_id: int, username: String) -> void:
	# The password is only held in the field, so clear it as soon as it has
	# been used rather than leaving it on screen.
	if _pass:
		_pass.text = ""
	_set_status("signed in as %s (id %d)" % [username, user_id], false)
	_refresh()


func _on_signed_out() -> void:
	_set_status("signed out", false)
	_refresh()


func _on_auth_failed(action: String, error: String, message: String) -> void:
	# not_configured and busy are build or timing problems, not credential
	# problems, so they are shown as they are instead of being relabelled.
	if error == "not_configured":
		_set_status(message, true)
	elif error == "busy":
		_set_status(message, false)
	else:
		_set_status("%s: %s" % [action, message], true)
	_refresh()


func _on_busy_changed(busy: bool) -> void:
	_set_buttons_enabled(not busy)


# --- presentation ----------------------------------------------------------


func _is_signed_in() -> bool:
	return _auth != null and bool(_auth.is_signed_in())


func _refresh() -> void:
	var signed := _is_signed_in()
	if _register:
		_register.visible = not signed
	if _login:
		_login.visible = not signed
	if _sign_out:
		_sign_out.visible = signed
	if _user:
		_user.editable = not signed
	if _pass:
		_pass.editable = not signed
	if _close:
		_close.text = "BACK TO GAME" if not signed else "DONE"
	if not signed and _auth != null and not bool(_auth.is_configured()):
		_set_status(
			"no accounts server is configured yet (set API_BASE in scripts/auth_client.gd)",
			true
		)


func _set_buttons_enabled(enabled: bool) -> void:
	for button in [_register, _login, _sign_out]:
		if button:
			button.disabled = not enabled


func _set_status(text: String, is_error: bool) -> void:
	if _status == null:
		return
	_status.text = text
	_status.add_theme_color_override(
		"font_color",
		Color(1.0, 0.45, 0.45) if is_error else Color(0.75, 0.85, 0.75)
	)
