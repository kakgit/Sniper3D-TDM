extends CharacterBody3D
## Tactical first-person controller: walk / sprint / crouch / jump, mouse look,
## Escape releases the mouse, and the camera drops while scoped.
## Also owns health, death and the 20 s respawn window.

signal health_changed(health: float, max_health: float)
signal died(respawn_delay: float)
signal respawned()

const STAND_SPEED := 5.2
const SPRINT_SPEED := 8.2
const CROUCH_SPEED := 2.6
const AIR_CONTROL := 0.35
const JUMP_VELOCITY := 4.5
const ACCEL := 14.0

const STAND_HEIGHT := 1.78
const CROUCH_HEIGHT := 1.12
const EYE_STAND := 1.62
const EYE_CROUCH := 0.98
const EYE_SCOPE_OFFSET := -0.04

const CROUCH_LERP := 9.0

## Remote presentation: how fast a networked body chases its last update, and
## the distance past which the body is put straight onto the reported spot
## (a respawn, not a walk).
const REMOTE_LERP := 14.0
const REMOTE_SNAP := 6.0

## Audio: existing project sound effects for going down and coming back.
const DEATH_SFX := "res://assets/models/e95fd3cc-b6b8-46e6-9468-68254efbe09e_sfx_heavy_body_impact_thud_player__1785424046667.wav"
const RESPAWN_SFX := "res://assets/models/891457d5-a24f-4514-aa57-90b5e7a3564a_sfx_very_short_one_shot_ultra_qui__1786049864461.wav"

const DEATH_DB := -6.0
const RESPAWN_DB := -14.0

@export var mouse_sensitivity := 0.0021
@export var pitch_min := -87.0
@export var pitch_max := 87.0
@export var spawn_marker: NodePath
@export var team := 0
@export var spawn_group_a := "spawn_a"
@export var spawn_group_b := "spawn_b"
@export var max_health := 100.0
@export var respawn_delay := 20.0
@export var hip_fov := 78.0            ## field of view off the scope
@export var scope_fov := 24.0          ## field of view fully zoomed in
@export var fov_speed := 14.0          ## how fast the zoom blends
@export var ads_sens_mult := 0.7       ## scoped look sensitivity as a fraction of the
                                       ## zoom-compensated value: 1.0 tracks a drag as
                                       ## fast as hip fire does on screen, lower is
                                       ## steadier aim
@export var scope_move_speed := 1.4    ## walking speed cap while scoped
@export var scope_sway := 0.0026       ## rifle drift in radians while scoped
@export var breath_sway := 0.0005      ## drift left while holding breath

var yaw := 0.0
var pitch := 0.0
var spawn_slot := -1     ## place inside the team, handed out by the room
var _spawn_index := -1
var crouching := false
var scoped := false
var health := 100.0
var is_dead := false
var respawn_timer := 0.0
var damage_flash := 0.0
var last_damage_dir := Vector3.ZERO
var _target_fov := 78.0
var _sway := Vector2.ZERO
var _sway_t := 0.0

var _head: Node3D
var _camera: Camera3D
var _weapon: Node
var _capsule: CollisionShape3D
var _death_cue: AudioStreamPlayer
var _respawn_cue: AudioStreamPlayer
var _height := STAND_HEIGHT
var _gravity := 9.8
var _parked_offline := false
var _solo_layer := 1
var _solo_mask := 26

func _ready() -> void:
	_head = get_node_or_null("Head")
	_capsule = get_node_or_null("CollisionShape3D")
	if _head:
		_camera = _head.get_node_or_null("Camera3D")
	_target_fov = hip_fov
	if _camera:
		_camera.fov = hip_fov
		_weapon = _camera.get_node_or_null("WeaponHolder")
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	add_to_group("player")
	health = max_health
	_solo_layer = collision_layer
	_solo_mask = collision_mask
	if _capsule and _capsule.shape:
		# one shape per body: several players must crouch independently
		_capsule.shape = _capsule.shape.duplicate() as Shape3D
	if not spawn_marker.is_empty():
		var m := get_node_or_null(spawn_marker)
		if m:
			global_position = m.global_position + Vector3(0.0, 0.15, 0.0)
			yaw = m.global_rotation.y
			rotation.y = yaw
	else:
		teleport_to_spawn()
	_setup_audio()
	# Only the owning peer drives the camera and the mouse. Every other peer
	# sees a soldier standing in the world instead of a first-person view.
	_apply_presentation(is_multiplayer_authority())
	if is_multiplayer_authority():
		claim_local_view()

## Death and respawn cues. The scene provides both players; a missing one is
## created here so the player is never silent.
func _setup_audio() -> void:
	_death_cue = _cue_player("DeathCue", DEATH_SFX, DEATH_DB)
	_respawn_cue = _cue_player("RespawnCue", RESPAWN_SFX, RESPAWN_DB)

func _cue_player(node_name: String, path: String, db: float) -> AudioStreamPlayer:
	var p := get_node_or_null(node_name) as AudioStreamPlayer
	if p == null:
		p = AudioStreamPlayer.new()
		p.name = node_name
		add_child(p)
	if p.stream == null and ResourceLoader.exists(path):
		p.stream = load(path) as AudioStream
	p.volume_db = db
	return p

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return  ## a remote player's copy never reads this machine's input
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		apply_look_delta(event.relative)
	elif event.is_action_pressed("ui_cancel"):
		# hard rule: the player must always be able to free the cursor
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not _ui_holds_cursor():
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_T:
		switch_team()

## Applies one look delta in pixels, exactly as the mouse does: yaw and pitch
## move by the same sensitivity and pitch keeps the same clamp. The touch layer
## calls this too, so a finger drag and a mouse drag are the same math, and a
## remote body is never driven by this machine's touch.
func apply_look_delta(look_delta: Vector2) -> void:
	if not is_multiplayer_authority():
		return
	var sens := mouse_sensitivity * _look_scale()
	yaw -= look_delta.x * sens
	pitch -= look_delta.y * sens
	pitch = clampf(pitch, deg_to_rad(pitch_min), deg_to_rad(pitch_max))
	rotation.y = yaw
	if _head:
		_head.rotation.x = pitch

## Sensitivity scale for one pixel of look. Zooming to scope_fov magnifies the view
## by hip_fov/scope_fov, so the same yaw sweeps the target that much faster on
## screen; this divides the sensitivity back down by that magnification and then
## applies ads_sens_mult, so scoped aim comes out steadier than hip fire rather
## than merely matching it. Hip fire is always exactly 1.0.
func _look_scale() -> float:
	if _camera == null or hip_fov <= scope_fov:
		return 1.0
	var zoom: float = clampf((hip_fov - _camera.fov) / (hip_fov - scope_fov), 0.0, 1.0)
	var ads: float = (scope_fov / hip_fov) * ads_sens_mult
	return lerpf(1.0, ads, zoom)

## Moves the player onto its place on the current team's spawn line. Offline the
## body steps to the next marker on each respawn; in a session the room gave this
## body a fixed slot, so it always comes back to the same spot.
func teleport_to_spawn() -> void:
	var grp := spawn_group_a if team == 0 else spawn_group_b
	var marks := get_tree().get_nodes_in_group(grp)
	if marks.is_empty():
		return
	var count := marks.size()
	if spawn_slot >= 0:
		_spawn_index = spawn_slot % count
	else:
		_spawn_index = (_spawn_index + 1) % count
	var m: Node3D = marks[_spawn_index]
	var spot := m.global_position
	if spawn_slot >= 0:
		# a team has more places than the map has markers, so each wrapping
		# group shifts sideways and two players never stand inside each other
		spot += m.global_transform.basis.x * floorf(float(spawn_slot) / float(count)) * 1.1
	global_position = spot + Vector3(0.0, 0.2, 0.0)
	yaw = m.global_rotation.y
	rotation.y = yaw
	velocity = Vector3.ZERO
	pitch = 0.0
	if _head:
		_head.rotation.x = 0.0

## Swaps sides and respawns on the other team's line (T key). Offline this is
## immediate. While a session runs the room owns the team list, so the request
## goes to the server, which grants it only when the other side has a free place.
func switch_team() -> void:
	if is_dead:
		return
	var lan := get_node_or_null("/root/NetworkManager")
	if lan != null and bool(lan.is_online()):
		var session := get_tree().get_first_node_in_group("net_session")
		if session != null and session.has_method("request_team_switch"):
			if multiplayer.is_server():
				session.request_team_switch()
			else:
				session.request_team_switch.rpc_id(1)
		return
	team = 1 - team
	_spawn_index = -1
	teleport_to_spawn()

func set_scope(active: bool) -> void:
	scoped = active
	_target_fov = scope_fov if active else hip_fov

func _physics_process(delta: float) -> void:
	damage_flash = maxf(0.0, damage_flash - delta)
	if not is_multiplayer_authority():
		# someone else owns this body: its movement and stance arrive over the
		# network, so this copy never reads input and never moves itself
		return
	_tick_scope(delta)
	if is_dead:
		# no input while down: settle to the ground and wait out the respawn
		_tick_respawn(delta)
		if not is_on_floor():
			velocity.y -= _gravity * delta
		velocity.x = move_toward(velocity.x, 0.0, ACCEL * delta)
		velocity.z = move_toward(velocity.z, 0.0, ACCEL * delta)
		move_and_slide()
		return
	crouching = Input.is_action_pressed("crouch")
	var target_speed := STAND_SPEED
	var speed := 0.0
	if crouching:
		target_speed = CROUCH_SPEED
	elif Input.is_action_pressed("sprint"):
		target_speed = SPRINT_SPEED
	if scoped:
		target_speed = minf(target_speed, scope_move_speed)

	var dir := Vector2.ZERO
	if Input.is_action_pressed("move_forward"):
		dir.y -= 1.0
	if Input.is_action_pressed("move_back"):
		dir.y += 1.0
	if Input.is_action_pressed("move_left"):
		dir.x -= 1.0
	if Input.is_action_pressed("move_right"):
		dir.x += 1.0
	dir = dir.normalized()
	var basis := global_transform.basis
	var wish := (basis.x * dir.x + basis.z * dir.y).normalized() if dir.length() > 0.001 else Vector3.ZERO

	if not is_on_floor():
		velocity.y -= _gravity * delta
		velocity.x = move_toward(velocity.x, wish.x * target_speed, ACCEL * AIR_CONTROL * delta)
		velocity.z = move_toward(velocity.z, wish.z * target_speed, ACCEL * AIR_CONTROL * delta)
	else:
		if Input.is_action_just_pressed("jump") and not crouching:
			velocity.y = JUMP_VELOCITY
		speed = target_speed
		velocity.x = move_toward(velocity.x, wish.x * speed, ACCEL * delta)
		velocity.z = move_toward(velocity.z, wish.z * speed, ACCEL * delta)

	move_and_slide()
	_update_stance(delta)

## Blends the zoom in and out, and applies the rifle drift that a sniper
## steadies by holding breath. Standing still and crouching both calm it.
func _tick_scope(delta: float) -> void:
	if _camera == null:
		return
	if is_dead:
		_target_fov = hip_fov
	_sway_t += delta
	_camera.fov = lerpf(_camera.fov, _target_fov, minf(1.0, fov_speed * delta))
	var target := Vector2.ZERO
	if scoped and not is_dead:
		var amp := breath_sway if Input.is_action_pressed("sprint") else scope_sway
		if crouching:
			amp *= 0.6
		var moving := Vector2(velocity.x, velocity.z).length()
		amp *= 1.0 + clampf(moving / SPRINT_SPEED, 0.0, 1.0) * 1.6
		target = Vector2(sin(_sway_t * 1.9) * amp, sin(_sway_t * 1.3 + 0.9) * amp * 0.8)
	_sway = _sway.lerp(target, minf(1.0, 7.0 * delta))
	_camera.rotation.x = _sway.x
	_camera.rotation.y = _sway.y

func _update_stance(delta: float) -> void:
	var target_height := CROUCH_HEIGHT if crouching else STAND_HEIGHT
	if not crouching and _height < STAND_HEIGHT - 0.01 and _is_blocked_overhead():
		target_height = CROUCH_HEIGHT
		crouching = true
	_height = lerpf(_height, target_height, minf(1.0, CROUCH_LERP * delta))
	if _capsule:
		# resize the shape resource instead of scaling the node: Jolt rejects
		# non-uniformly scaled collision shapes
		var sh := _capsule.shape as CapsuleShape3D
		if sh:
			sh.height = _height
		_capsule.position.y = _height * 0.5
	if _head:
		var eye := EYE_CROUCH if crouching else EYE_STAND
		if scoped:
			eye += EYE_SCOPE_OFFSET
		_head.position.y = lerpf(_head.position.y, eye, minf(1.0, CROUCH_LERP * delta))

func _is_blocked_overhead() -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0.0, CROUCH_HEIGHT, 0.0),
		global_position + Vector3(0.0, STAND_HEIGHT + 0.05, 0.0))
	q.exclude = [get_rid()]
	q.collision_mask = 2 | 16
	return not space.intersect_ray(q).is_empty()

## Canonical damage entry point, returns true when this hit was the kill.
func take_damage(amount: float, source: Node = null) -> bool:
	if is_dead:
		return false
	health -= amount
	if source is Node3D:
		last_damage_dir = (source as Node3D).global_position - global_position
		last_damage_dir.y = 0.0
	damage_flash = 0.6
	health_changed.emit(maxf(0.0, health), max_health)
	if health > 0.0:
		return false
	health = 0.0
	_die()
	return true

func _die() -> void:
	is_dead = true
	respawn_timer = respawn_delay
	velocity = Vector3.ZERO
	set_scope(false)
	if _death_cue and _death_cue.stream:
		_death_cue.play()
	died.emit(respawn_delay)

## Runs the respawn window down, then puts the player back on the spawn line.
func _tick_respawn(delta: float) -> void:
	respawn_timer -= delta
	if respawn_timer > 0.0:
		return
	respawn_timer = 0.0
	health = max_health
	is_dead = false
	last_damage_dir = Vector3.ZERO
	teleport_to_spawn()
	if _respawn_cue and _respawn_cue.stream:
		_respawn_cue.play()
	health_changed.emit(health, max_health)
	respawned.emit()

func get_weapon() -> Node:
	return _weapon

func get_camera() -> Camera3D:
	return _camera

## Takes the mouse and the live camera on this machine, and puts the
## first-person hands back on the body that owns them.
func claim_local_view() -> void:
	if not is_multiplayer_authority():
		return
	_apply_presentation(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## True while another script (the host/join menu) is deliberately holding the
## cursor, so a stray click in the world does not steal it back.
func _ui_holds_cursor() -> bool:
	var tree := get_tree()
	return tree != null and not tree.get_nodes_in_group("blocking_ui").is_empty()

## Called by the session node. While a LAN session runs the scene's solo player
## steps aside, so the only players on the field are the connected peers.
func park_offline(parked: bool) -> void:
	_parked_offline = parked
	visible = not parked
	process_mode = Node.PROCESS_MODE_DISABLED if parked else Node.PROCESS_MODE_INHERIT
	if parked:
		collision_layer = 0
		collision_mask = 0
		set_physics_process(false)
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		collision_layer = _solo_layer
		collision_mask = _solo_mask
		set_physics_process(true)

## Applies one movement update from the peer that owns this body. Remote bodies
## follow the reported spot instead of simulating anything locally.
func apply_remote_state(pos: Vector3, body_yaw: float, body_pitch: float, crouch: bool, dead: bool, delta: float) -> void:
	if is_multiplayer_authority():
		return
	if global_position.distance_to(pos) > REMOTE_SNAP:
		global_position = pos
		velocity = Vector3.ZERO
	else:
		global_position = global_position.lerp(pos, clampf(REMOTE_LERP * delta, 0.0, 1.0))
	yaw = body_yaw
	pitch = body_pitch
	rotation.y = yaw
	if _head:
		_head.rotation.x = pitch
	is_dead = dead
	if dead:
		set_scope(false)
	crouching = crouch
	_apply_remote_stance(delta)

## First-person camera and held rifle for the owning peer; a plain soldier body
## for everyone else, so the other player is actually visible on the field.
func _apply_presentation(local: bool) -> void:
	if _camera:
		_camera.current = local
	if _weapon:
		_weapon.visible = local
	var model := get_node_or_null("WorldModel")
	if model:
		model.visible = not local
	var head_mesh := get_node_or_null("Head/HeadMesh")
	if head_mesh:
		head_mesh.visible = not local
	if _head:
		_head.visible = local
	_set_remote_collision(not local)
	if not local:
		_apply_remote_stance(0.0)

## Remote bodies stop pushing other players around, but keep standing on the
## collision layers target_dummy.gd filters on, so the stand-ins can still
## engage whoever is in range. Team 0 sits on the scene's original player layer,
## team 1 on layer 6 (32), which is exactly what target_dummy.gd looks for.
func _set_remote_collision(remote: bool) -> void:
	if remote:
		collision_layer = _solo_layer if team == 0 else 32
		collision_mask = 26
	else:
		collision_layer = _solo_layer
		collision_mask = _solo_mask

## Poses a remote body from its last networked stance, reading no input.
func _apply_remote_stance(delta: float) -> void:
	var target_height := CROUCH_HEIGHT if crouching else STAND_HEIGHT
	if delta <= 0.0:
		_height = target_height
	else:
		_height = lerpf(_height, target_height, minf(1.0, CROUCH_LERP * delta))
	if _capsule:
		var sh := _capsule.shape as CapsuleShape3D
		if sh:
			sh.height = _height
		_capsule.position.y = _height * 0.5
	if _head:
		_head.position.y = EYE_CROUCH if crouching else EYE_STAND
