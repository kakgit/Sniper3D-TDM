extends Node
## Accounts client for the TDM Sniper Arena backend (res://server/auth_api.py).
##
## Autoloaded as AuthClient. This is the only place in the game that talks to
## the accounts API: register, log in, confirm a saved token, log out. The token
## is kept in user://auth.cfg, so a sign in survives closing the game.
##
## Failures arrive as {"error": "...", "message": "..."} from the server, and
## every signal below carries both: `error` is the machine-readable name,
## `message` is the sentence worth showing a player.
##
## The token is stored in the app's private user:// area, which is not readable
## by other apps on Android, but it is NOT encrypted on disk. That is the normal
## tradeoff for a game client token; if this ever protects anything valuable,
## the token lifetime on the server is the real control, not this file.

## The deployed API domain. Replace this with your own Railway service domain,
## for example "https://tdm-accounts-production.up.railway.app".
##
## Until you do, every call fails immediately with the error "not_configured",
## so a build pointed at nothing says so plainly instead of looking like a
## network fault.
const API_BASE := "https://sniper3d-tdm-production.up.railway.app"

const CREDENTIALS_PATH := "user://auth.cfg"
const TIMEOUT := 15.0

## Emitted on a fresh register/login and again when a saved token is confirmed.
signal signed_in(user_id: int, username: String)
## Emitted on logout, or when the server rejects a saved token.
signal signed_out()
## Emitted for every failure that is worth telling the player about.
signal auth_failed(action: String, error: String, message: String)
## Emitted when a request starts or the last one finishes.
signal busy_changed(busy: bool)

var _user_id := 0
var _username := ""
var _token := ""

var _busy := false
var _in_flight := 0


func _ready() -> void:
	_load_session()
	# A saved token is only believed once the server confirms it, so a token
	# that expired or was revoked elsewhere does not leave this device looking
	# signed in. A network failure here keeps the session: only a 401 clears it.
	if not _token.is_empty() and is_configured():
		_request("me", HTTPClient.METHOD_GET, "/v1/me", "", _token)


# --- state -----------------------------------------------------------------


## False while API_BASE is still the placeholder. The UI uses this to explain
## itself rather than firing a doomed request.
func is_configured() -> bool:
	return not API_BASE.contains("YOUR-SERVICE")


func is_signed_in() -> bool:
	return not _token.is_empty()


func is_busy() -> bool:
	return _busy


func username() -> String:
	return _username


func user_id() -> int:
	return _user_id


func token() -> String:
	return _token


# --- actions ---------------------------------------------------------------


func register_user(username: String, password: String) -> void:
	if not _guard("register"):
		return
	_send_credentials("register", "/v1/register", username, password)


func log_in(username: String, password: String) -> void:
	if not _guard("login"):
		return
	_send_credentials("login", "/v1/login", username, password)


## Clears the local session whatever the server says. The token is dropped
## either way, so a refusal or an unreachable server must not strand the player
## in a signed-in state they cannot leave.
func log_out() -> void:
	if _token.is_empty():
		_clear_session()
		signed_out.emit()
		return
	if not is_configured():
		_clear_session()
		signed_out.emit()
		return
	_request("logout", HTTPClient.METHOD_POST, "/v1/logout", "", _token)


# --- requests --------------------------------------------------------------


func _send_credentials(action: String, path: String, username: String, password: String) -> void:
	var body := JSON.stringify({"username": username, "password": password})
	_request(action, HTTPClient.METHOD_POST, path, body, "")


func _request(action: String, method: int, path: String, body: String, token: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	add_child(http)
	_in_flight += 1
	_set_busy(true)

	var headers := PackedStringArray(["Content-Type: application/json"])
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)

	var err := http.request(API_BASE + path, headers, method, body)
	if err != OK:
		_in_flight -= 1
		_set_busy(_in_flight > 0)
		http.queue_free()
		_fail(action, "request_failed", "could not start the request (%d)" % err)
		return

	http.request_completed.connect(_on_completed.bind(http, action))


func _on_completed(
	result: int, code: int, _headers: PackedStringArray,
	body: PackedByteArray, http: HTTPRequest, action: String
) -> void:
	_in_flight -= 1
	_set_busy(_in_flight > 0)
	http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS:
		_fail(action, "network", "could not reach the accounts server (%d)" % result)
		return

	var text := body.get_string_from_utf8()
	var data: Variant = JSON.parse_string(text) if not text.is_empty() else null

	if code >= 400:
		var name := "http_%d" % code
		var message := "the server refused the request"
		if data is Dictionary:
			name = str(data.get("error", name))
			message = str(data.get("message", message))
		# A rejected saved token, or a logout the server would not honour:
		# both end with the local session gone, and neither is worth an error
		# popup. Only an explicit 401 on "me" means the token is dead.
		if action == "logout" or (action == "me" and code == 401):
			_clear_session()
			signed_out.emit()
			return
		_fail(action, name, message)
		return

	_succeeded(action, data)


func _succeeded(action: String, data: Variant) -> void:
	match action:
		"register", "login":
			if not (data is Dictionary) or str((data as Dictionary).get("token", "")).is_empty():
				_fail(action, "bad_response", "the server did not return a token")
				return
			var payload := data as Dictionary
			_user_id = int(payload.get("user_id", 0))
			_username = str(payload.get("username", ""))
			_token = str(payload.get("token", ""))
			_save_session()
			signed_in.emit(_user_id, _username)
		"me":
			if data is Dictionary:
				var payload := data as Dictionary
				_user_id = int(payload.get("user_id", _user_id))
				_username = str(payload.get("username", _username))
			signed_in.emit(_user_id, _username)
		"logout":
			_clear_session()
			signed_out.emit()


# --- helpers ---------------------------------------------------------------


## Returns false when the action must not be attempted, after reporting why.
func _guard(action: String) -> bool:
	if not is_configured():
		_fail(
			action, "not_configured",
			"no accounts server is configured (set API_BASE in scripts/auth_client.gd)"
		)
		return false
	if _busy:
		_fail(action, "busy", "a sign in is already running")
		return false
	return true


func _fail(action: String, error: String, message: String) -> void:
	auth_failed.emit(action, error, message)


func _set_busy(busy: bool) -> void:
	if busy == _busy:
		return
	_busy = busy
	busy_changed.emit(_busy)


func _save_session() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("auth", "user_id", _user_id)
	cfg.set_value("auth", "username", _username)
	cfg.set_value("auth", "token", _token)
	cfg.save(CREDENTIALS_PATH)


func _load_session() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CREDENTIALS_PATH) != OK:
		return
	_user_id = int(cfg.get_value("auth", "user_id", 0))
	_username = str(cfg.get_value("auth", "username", ""))
	_token = str(cfg.get_value("auth", "token", ""))


func _clear_session() -> void:
	_user_id = 0
	_username = ""
	_token = ""
	if FileAccess.file_exists(CREDENTIALS_PATH):
		DirAccess.remove_absolute(CREDENTIALS_PATH)
