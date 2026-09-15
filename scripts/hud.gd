extends Control
## HUD: crosshair with scope-aware spread, ammo readout, reload status,
## health bar, incoming-fire indicator and the respawn countdown.

var _weapon: Node
var _player
var _match: Node
var _mag := 0
var _reserve := 0
var _gap := 26.0
var _hit_marker := 0.0
var _killed := false
var _reloading := false

@onready var _mag_label: Label = get_node_or_null("AmmoMag")
@onready var _reserve_label: Label = get_node_or_null("AmmoReserve")
@onready var _status: Label = get_node_or_null("Status")
@onready var _clock: Label = get_node_or_null("Clock")
@onready var _scoreboard: Label = get_node_or_null("Scoreboard")
@onready var _banner: Label = get_node_or_null("Banner")

func _ready() -> void:
	add_to_group("hud")
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bind_local_player()

## Points the HUD at this peer's own player and that player's rifle. In solo
## play there is only one player; in a LAN session this picks the body this peer
## owns, so health, ammo and the score readout describe the local player instead
## of whichever node happens to come first in the group.
func _bind_local_player() -> void:
	var p := _find_local_player()
	_player = p
	var w = p.get_weapon() if p != null and p.has_method("get_weapon") else null
	if w == null:
		w = get_tree().get_first_node_in_group("weapon")
	if w == null or w == _weapon:
		return
	_weapon = w
	w.ammo_changed.connect(_on_ammo_changed)
	w.hit_confirmed.connect(_on_hit_confirmed)
	_on_ammo_changed(w.ammo, w.reserve)

## The player this peer owns: the local session body when a session runs, else
## the single player the scene provides. The scene's solo player is parked while
## a session runs, so it is only used as a last resort.
func _find_local_player() -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if p is Node and p.is_multiplayer_authority() and not bool(p.get("_parked_offline")):
			return p
	for p in get_tree().get_nodes_in_group("player"):
		if p is Node and p.is_multiplayer_authority():
			return p
	return null

## Cheap re-check: rebinds only when the held player is gone, or the scene's
## solo player was parked because a session took over.
func _ensure_local_player() -> void:
	if _player != null and is_instance_valid(_player) and not bool(_player.get("_parked_offline")):
		return
	var p := _find_local_player()
	if p != _player:
		_bind_local_player()

func _on_ammo_changed(mag: int, reserve: int) -> void:
	_mag = mag
	_reserve = reserve
	if _mag_label:
		_mag_label.text = str(mag)
	if _reserve_label:
		_reserve_label.text = "/ %d" % reserve

func _on_hit_confirmed(_spot: Vector3, killed: bool) -> void:
	_hit_marker = 0.45
	_killed = killed

func _process(delta: float) -> void:
	_ensure_local_player()
	if _weapon:
		_reloading = _weapon.reloading
	var target := 26.0
	if _player and "scoped" in _player and _player.scoped:
		target = 8.0
	_gap = lerpf(_gap, target, minf(1.0, 10.0 * delta))
	_hit_marker = maxf(0.0, _hit_marker - delta)
	if _status:
		_status.text = "RELOADING" if _reloading else ""
	if _match == null or not is_instance_valid(_match):
		_match = get_tree().get_first_node_in_group("match")
	_update_match_readout()
	queue_redraw()

## Score, match clock and the match-over banner, read straight off the manager.
func _update_match_readout() -> void:
	if _match == null:
		return
	var a: int = int(_match.alpha)
	var b: int = int(_match.bravo)
	if _scoreboard:
		_scoreboard.text = "ALPHA  %d        BRAVO  %d" % [a, b]
	if _clock:
		var left: int = int(ceilf(float(_match.time_left)))
		_clock.text = "%02d:%02d" % [left / 60, left % 60]
	if _banner == null:
		return
	if bool(_match.running):
		_banner.text = ""
		return
	var w: int = int(_match.winner)
	if w == 0:
		_banner.text = "MATCH OVER - ALPHA WINS  %d - %d\nPress ENTER to play again" % [a, b]
	elif w == 1:
		_banner.text = "MATCH OVER - BRAVO WINS  %d - %d\nPress ENTER to play again" % [a, b]
	else:
		_banner.text = "MATCH OVER - DRAW  %d - %d\nPress ENTER to play again" % [a, b]

func _draw() -> void:
	_draw_feed()
	if _player and "is_dead" in _player and _player.is_dead:
		_draw_dead()
		return
	var zoom := _scope_blend()
	if zoom > 0.02:
		_draw_scope(zoom)
	else:
		_draw_crosshair()
	_draw_hit_marker()
	_draw_health()
	_draw_incoming()

## How far into the scope we are: 0 is hip fire, 1 is fully zoomed.
func _scope_blend() -> float:
	if _player == null or not is_instance_valid(_player):
		return 0.0
	if not ("scoped" in _player) or not _player.scoped:
		return 0.0
	var cam: Camera3D = _player.get_camera() if _player.has_method("get_camera") else null
	if cam == null:
		return 1.0
	var hip: float = float(_player.hip_fov) if "hip_fov" in _player else 78.0
	var sc: float = float(_player.scope_fov) if "scope_fov" in _player else 24.0
	if absf(hip - sc) < 0.01:
		return 1.0
	return clampf((hip - cam.fov) / (hip - sc), 0.0, 1.0)

## Hip-fire crosshair: four ticks that tighten as you settle.
func _draw_crosshair() -> void:
	var c := size * 0.5
	var col := Color(0.96, 0.96, 0.92, 0.92)
	if _reloading:
		col.a = 0.3
	for d in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		draw_line(c + d * _gap, c + d * (_gap + 9.0), col, 1.6)
	draw_rect(Rect2(c - Vector2(1, 1), Vector2(2, 2)), col)

## Hit or kill marker, drawn over either sight picture.
func _draw_hit_marker() -> void:
	if _hit_marker <= 0.0:
		return
	var c := size * 0.5
	var k := Color(1.0, 0.25, 0.2) if _killed else Color(1.0, 1.0, 1.0)
	k.a = minf(1.0, _hit_marker * 3.0)
	for v in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		draw_line(c + v * 6.0, c + v * 14.0, k, 2.2)

## Scope picture: blacked-out periphery, lens bezel and a mil-dot reticle.
## The vignette is one very thick ring, because a CanvasItem has no way to
## punch a hole through a filled rectangle.
func _draw_scope(zoom: float) -> void:
	var c := size * 0.5
	var radius := minf(size.x, size.y) * 0.44
	draw_arc(c, radius + 1500.0, 0.0, TAU, 160, Color(0.0, 0.0, 0.0, 0.98 * zoom), 3000.0, true)
	draw_arc(c, radius, 0.0, TAU, 160, Color(0.04, 0.04, 0.05, zoom), 16.0, true)
	draw_arc(c, radius - 10.0, 0.0, TAU, 160, Color(0.0, 0.0, 0.0, 0.45 * zoom), 10.0, true)
	var ink := Color(0.03, 0.03, 0.03, 0.95 * zoom)
	var edge := radius - 16.0
	var inner := radius * 0.30
	# fine cross through the lens, with heavy duplex posts toward the rim
	draw_line(Vector2(c.x, c.y - edge), Vector2(c.x, c.y + edge), ink, 1.3)
	draw_line(Vector2(c.x - edge, c.y), Vector2(c.x + edge, c.y), ink, 1.3)
	draw_line(Vector2(c.x, c.y - edge), Vector2(c.x, c.y - inner), ink, 3.6)
	draw_line(Vector2(c.x, c.y + edge), Vector2(c.x, c.y + inner), ink, 3.6)
	draw_line(Vector2(c.x - edge, c.y), Vector2(c.x - inner, c.y), ink, 3.6)
	draw_line(Vector2(c.x + edge, c.y), Vector2(c.x + inner, c.y), ink, 3.6)
	# mil-dot ladder along each axis
	var span := edge - inner - 12.0
	for i in range(1, 6):
		var d := inner + 12.0 + span * (float(i) / 6.0)
		if d > edge - 6.0:
			break
		draw_circle(Vector2(c.x + d, c.y), 2.0, ink)
		draw_circle(Vector2(c.x - d, c.y), 2.0, ink)
		draw_circle(Vector2(c.x, c.y + d), 2.0, ink)
		draw_circle(Vector2(c.x, c.y - d), 2.0, ink)
	draw_circle(c, 1.6, ink)
	if Input.is_action_pressed("sprint"):
		_center("HOLDING BREATH", 13, radius - 28.0, Color(0.8, 0.92, 0.8, 0.85 * zoom))

## Health bar in the bottom-left corner.
func _draw_health() -> void:
	if _player == null:
		return
	var hp: float = _player.health
	var hmax: float = maxf(1.0, _player.max_health)
	var frac := clampf(hp / hmax, 0.0, 1.0)
	var bar_w := 220.0
	var bar_h := 12.0
	var o := Vector2(28.0, size.y - 46.0)
	draw_rect(Rect2(o - Vector2(3, 3), Vector2(bar_w + 6, bar_h + 6)), Color(0, 0, 0, 0.45))
	draw_rect(Rect2(o, Vector2(bar_w, bar_h)), Color(0.12, 0.12, 0.12, 0.75))
	var col := Color(0.35, 0.75, 0.35)
	if frac <= 0.25:
		col = Color(0.85, 0.25, 0.2)
	elif frac <= 0.5:
		col = Color(0.9, 0.7, 0.2)
	draw_rect(Rect2(o, Vector2(bar_w * frac, bar_h)), col)
	_text(o + Vector2(0, -7), "HEALTH %d" % int(ceil(hp)), 13, Color(0.9, 0.9, 0.9, 0.85))

## Red edge wash plus a marker showing where the shot came from.
func _draw_incoming() -> void:
	if _player == null or not ("damage_flash" in _player):
		return
	var f: float = _player.damage_flash
	if f <= 0.0:
		return
	var a := minf(0.45, f * 0.75)
	for r in [
		Rect2(0.0, 0.0, size.x, 10.0),
		Rect2(0.0, size.y - 10.0, size.x, 10.0),
		Rect2(0.0, 0.0, 10.0, size.y),
		Rect2(size.x - 10.0, 0.0, 10.0, size.y),
	]:
		draw_rect(r, Color(0.75, 0.05, 0.05, a))
	var d: Vector3 = _player.last_damage_dir
	if d.length_squared() < 0.01:
		return
	var cam = _player.get_camera()
	if cam == null:
		return
	var local: Vector3 = cam.global_transform.basis.inverse() * d
	var ang := atan2(local.x, -local.z)
	var dir := Vector2(sin(ang), -cos(ang))
	var c := size * 0.5
	draw_line(c + dir * 48.0, c + dir * 72.0, Color(1.0, 0.35, 0.25, maxf(0.35, f)), 3.5)

## Kill feed, newest first, each line fading out as it ages.
func _draw_feed() -> void:
	if _match == null or not is_instance_valid(_match):
		return
	if not ("feed" in _match):
		return
	var entries: Array = _match.feed
	var f := ThemeDB.fallback_font
	var y := 34.0
	for e in entries:
		var col: Color = e["color"]
		col.a = clampf(float(e["t"]) / 1.5, 0.0, 1.0)
		var t := String(e["text"])
		var tw := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		draw_string(f, Vector2(size.x - 24.0 - tw, y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)
		y += 22.0

func _draw_dead() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.4, 0.03, 0.03, 0.33))
	_center("KILLED IN ACTION", 32, -16.0, Color(1.0, 0.86, 0.82))
	var left: int = int(ceil(maxf(0.0, _player.respawn_timer)))
	_center("respawn in %d s" % left, 20, 22.0, Color(1.0, 1.0, 1.0, 0.9))

func _text(pos: Vector2, t: String, sz: int, col: Color) -> void:
	draw_string(ThemeDB.fallback_font, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, col)

func _center(t: String, sz: int, dy: float, col: Color) -> void:
	var f := ThemeDB.fallback_font
	var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	draw_string(f, size * 0.5 + Vector2(-w * 0.5, dy), t, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, col)
