extends Node3D
## Bolt-action sniper rifle. Hitscan shot, hold right mouse to scope in,
## R to reload. Feedback: muzzle flash, impact marker, ammo signal.

signal ammo_changed(mag: int, reserve: int)
signal hit_confirmed(spot: Vector3, killed: bool)

const IMPACT_LIFE := 0.35

## Audio: existing project sound effects found in the asset store.
const REPORT_SFX := "res://assets/models/sfx_powerful_assault_rifle_gunshot_.wav"
const BOLT_SFX := "res://assets/models/sfx_hunting_rifle_bolt_action_mech_.wav"
const RELOAD_SFX := "res://assets/models/6061a323-baf9-45ef-b40f-3cfed8f64741_sfx_a_short_heavy_wooden_click_li__1786070503782.wav"
const IMPACT_SFX := "res://assets/models/sfx_bullet_impact_on_concrete_wall_.wav"

const BOLT_DELAY := 0.34  ## the bolt is worked a beat after the shot
const REPORT_DB := -3.0
const BOLT_DB := -10.0
const RELOAD_DB := -12.0
const IMPACT_DB := -6.0

@export var damage := 95.0
@export var max_range := 400.0
@export var mag_size := 5
@export var reserve_start := 25
@export var reload_time := 2.6
@export var fire_cooldown := 1.15
@export var spread_hip := 0.050
@export var spread_scoped := 0.0012

var ammo := 5
var reserve := 25
var reloading := false

var _cooldown := 0.0
var _reload_timer := 0.0
var _recoil := 0.0
var _flash_timer := 0.0
var _player: Node
var _camera: Camera3D
var _muzzle: Node3D
var _flash: Node3D
var _effects: Node3D
var _base_pos := Vector3.ZERO
var _impact_mesh: SphereMesh
var _impact_mat: StandardMaterial3D
var _report: AudioStreamPlayer3D
var _bolt: AudioStreamPlayer
var _reload: AudioStreamPlayer
var _impact_sound: AudioStream
var _bolt_timer := 0.0
## The held rifle mesh (WeaponHolder/Rifle), hidden while scoped or down.
var _viewmodel: Node3D

func _ready() -> void:
	add_to_group("weapon")
	ammo = mag_size
	reserve = reserve_start
	_base_pos = position
	_camera = get_parent() as Camera3D
	_muzzle = get_node_or_null("Muzzle")
	_flash = get_node_or_null("Muzzle/MuzzleFlash")
	_impact_mesh = SphereMesh.new()
	_impact_mesh.radius = 0.07
	_impact_mesh.height = 0.14
	_impact_mat = StandardMaterial3D.new()
	_impact_mat.albedo_color = Color(1.0, 0.93, 0.62)
	_impact_mat.emission_enabled = true
	_impact_mat.emission = Color(1.0, 0.82, 0.35)
	_impact_mat.emission_energy_multiplier = 2.0
	if _muzzle:
		_muzzle.visible = false
	_viewmodel = get_node_or_null("Rifle") as Node3D
	_setup_audio()

## Wires the rifle's report, bolt cycle and reload players. The scene provides
## them; a missing one is created here so the gun is never silent.
func _setup_audio() -> void:
	_impact_sound = _load_sfx(IMPACT_SFX)
	var rp := get_node_or_null("Report") as AudioStreamPlayer3D
	if rp == null:
		rp = AudioStreamPlayer3D.new()
		rp.name = "Report"
		add_child(rp)
	if rp.stream == null:
		rp.stream = _load_sfx(REPORT_SFX)
	rp.volume_db = REPORT_DB
	rp.unit_size = 12.0
	rp.max_distance = 400.0
	_report = rp
	_bolt = _resolve_player("Bolt", BOLT_SFX, BOLT_DB)
	_reload = _resolve_player("Reload", RELOAD_SFX, RELOAD_DB)

## Non-positional one-shot player on the weapon (bolt cycle, magazine click).
func _resolve_player(node_name: String, path: String, db: float) -> AudioStreamPlayer:
	var p := get_node_or_null(node_name) as AudioStreamPlayer
	if p == null:
		p = AudioStreamPlayer.new()
		p.name = node_name
		add_child(p)
	if p.stream == null:
		p.stream = _load_sfx(path)
	p.volume_db = db
	return p

## Loads a project sound effect, or null when it is not in the project.
func _load_sfx(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as AudioStream

## Camera the weapon aims along (WeaponHolder -> Camera3D).
func get_camera() -> Camera3D:
	return _camera

## Owning player node (WeaponHolder -> Camera3D -> Head -> Player).
func get_player() -> Node:
	if _player == null and _camera:
		var head := _camera.get_parent()
		if head:
			_player = head.get_parent()
	return _player

## True when the peer running this code also plays this weapon. On a remote
## peer's copy of a player, this is false: that copy reads no fire, aim or
## reload input and never fires here, so two peers cannot shoot each other's gun.
func is_local_owner() -> bool:
	var p := get_player()
	if p != null:
		return p.is_multiplayer_authority()
	return is_multiplayer_authority()

func _process(delta: float) -> void:
	if not is_local_owner():
		return  ## the local peer does not own this weapon
	_cooldown = maxf(0.0, _cooldown - delta)
	if _bolt_timer > 0.0:
		# the bolt is worked a beat after the shot
		_bolt_timer -= delta
		if _bolt_timer <= 0.0:
			_bolt_timer = 0.0
			if _bolt and _bolt.stream:
				_bolt.play()
	if _reloading():
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_finish_reload()
	_recoil = move_toward(_recoil, 0.0, delta * 7.0)
	position = _base_pos + Vector3(0.0, 0.0, 0.09 * _recoil)
	rotation.x = 0.16 * _recoil
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0 and _flash:
			_flash.visible = false
	var p := get_player()
	var down := false
	if p and "is_dead" in p:
		down = bool(p.is_dead)
	if down:
		# dead players cannot aim, fire or reload
		if _flash:
			_flash.visible = false
		if _muzzle:
			_muzzle.visible = false
		if p.has_method("set_scope"):
			p.set_scope(false)
		_show_viewmodel(false)
		return
	if p and p.has_method("set_scope"):
		p.set_scope(Input.is_action_pressed("aim"))
	var holding_scope: bool = bool(p.scoped) if p and "scoped" in p else false
	_show_viewmodel(not holding_scope)
	if Input.is_action_pressed("shoot"):
		fire()
	if Input.is_action_just_pressed("reload"):
		start_reload()

func _reloading() -> bool:
	return _reload_timer > 0.0

func fire() -> void:
	if not is_local_owner():
		return
	if _cooldown > 0.0 or _reloading():
		return
	if ammo <= 0:
		start_reload()
		return
	ammo -= 1
	_cooldown = fire_cooldown
	_recoil = 1.0
	emit_signal("ammo_changed", ammo, reserve)
	_show_flash()
	if _report and _report.stream:
		_report.play()
	_bolt_timer = BOLT_DELAY

	var p := get_player()
	var scoped: bool = bool(p.scoped) if p and "scoped" in p else false
	var spread: float = spread_scoped if scoped else spread_hip
	var origin := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	if spread > 0.0:
		dir = dir.rotated(_camera.global_transform.basis.x.normalized(), randf_range(-spread, spread))
		dir = dir.rotated(_camera.global_transform.basis.y.normalized(), randf_range(-spread, spread))
	dir = dir.normalized()
	var end := origin + dir * max_range

	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, end)
	q.collision_mask = 1 | 2 | 4 | 8 | 16
	if p is CollisionObject3D:
		q.exclude = [(p as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(q)
	var killed := false
	if not hit.is_empty():
		end = hit.position
		var col = hit.collider
		# Never damage a teammate. Both sides' snipers use the same rooftops, so
		# a stray round into one is easy, and a team kill would score a point for
		# the opposing team. The stand-ins block this themselves; this is the
		# same rule for the player's rifle.
		if col and col.has_method("take_damage") and not _is_teammate(col, p):
			killed = col.take_damage(damage, self)
	_spawn_impact(end)
	emit_signal("hit_confirmed", end, killed)

## True when the round landed on someone on the shooter's own team. Anything
## with no team - the arena geometry - is never a teammate.
func _is_teammate(col, p) -> bool:
	if col == null or p == null:
		return false
	if not ("team" in col) or not ("team" in p):
		return false
	return int(col.team) == int(p.team)

func start_reload() -> void:
	if not is_local_owner():
		return
	if _reloading() or ammo >= mag_size or reserve <= 0:
		return
	_reload_timer = reload_time
	if _reload and _reload.stream:
		_reload.play()

func _finish_reload() -> void:
	_reload_timer = 0.0
	var take: int = mini(mag_size - ammo, reserve)
	ammo += take
	reserve -= take
	emit_signal("ammo_changed", ammo, reserve)

func _show_flash() -> void:
	if _flash:
		_flash.visible = true
		_flash_timer = 0.055
	if _muzzle:
		_muzzle.visible = true
		_muzzle_hide()

func _muzzle_hide() -> void:
	# the muzzle node stays visible for the same short window as the flash
	pass

## Shows or hides the held rifle. It goes away while the player is scoped in,
## because the scope picture takes over the screen, and while they are down.
func _show_viewmodel(shown: bool) -> void:
	if _viewmodel:
		_viewmodel.visible = shown

func _spawn_impact(spot: Vector3) -> void:
	if _effects == null:
		_effects = get_tree().get_first_node_in_group("effects") as Node3D
	_play_impact(spot)
	if _effects == null:
		return
	var m := MeshInstance3D.new()
	m.mesh = _impact_mesh
	m.material_override = _impact_mat
	_effects.add_child(m)
	m.global_position = spot
	var tw := create_tween()
	tw.tween_property(m, "scale", Vector3(0.05, 0.05, 0.05), IMPACT_LIFE)
	tw.tween_callback(m.queue_free)

## One-shot impact audio at the exact spot the bullet landed. The player node
## is spawned under Effects and freed when the clip ends.
func _play_impact(spot: Vector3) -> void:
	if _impact_sound == null:
		return
	var parent: Node3D = _effects
	if parent == null:
		parent = get_tree().current_scene as Node3D
	if parent == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = _impact_sound
	p.volume_db = IMPACT_DB
	p.unit_size = 8.0
	p.max_distance = 400.0
	parent.add_child(p)
	p.global_position = spot
	p.finished.connect(p.queue_free)
	p.play()

func _exit_tree() -> void:
	if _muzzle:
		_muzzle.visible = false
