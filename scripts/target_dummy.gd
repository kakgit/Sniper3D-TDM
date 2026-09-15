extends CharacterBody3D
## Team member standing in for a networked opponent: takes sniper hits, drops
## out of play, then resets. When armed and hostile it also watches the nearest
## opponent it can see - the player, or a stand-in of the other team - telegraphs
## its aim, then returns fire with a hitscan shot, so both teams fight each other
## with no help from the player.
##
## It is a CharacterBody3D so it walks a patrol route under gravity inside its
## own team's half of the arena, pauses at every waypoint to watch and shoot,
## and steps to a fresh position whenever it is hit. Steering is direct, with a
## short avoidance raycast and a floor probe instead of a navmesh, because the
## arena does not exist until the game runs.
##
## Contact awareness never moves it. The solid mid barricade at z = 0 seals the
## two halves of the arena, so an enemy in the other half is unreachable: a
## stand-in that cannot see one only turns to watch the direction its team
## shared, from where it already stands.

signal killed

@export var max_health := 100.0
@export var respawn_delay := 6.0
@export var team := 1
@export var armed := true
@export var shot_damage := 55.0
@export var sight_range := 130.0
@export var aim_time := 0.9
@export var shot_interval := 2.6
@export var accuracy := 0.55

## Patrol loop in world coordinates, walked in order and then repeated. Leave it
## empty for a sentry that holds its post, which is what a stand-in standing on
## a building floor slab does.
@export var patrol_points: PackedVector3Array = PackedVector3Array()
## Seconds spent standing, watching and shooting at every waypoint.
@export var patrol_wait := 2.6
@export var move_speed := 3.2
## Speed used to break away from the spot where it just took a hit.
@export var reposition_speed := 5.2
@export var reposition_time := 2.0
@export var arrive_radius := 0.7

const SCAN_STEP := 0.1

## What the walking body collides with. Layer 2 is the arena geometry it stands
## on and bumps into, layer 1 is the player. Layer 8, the stand-in layer itself,
## is deliberately NOT in the mask: two stand-ins never shove each other, and
## the player cannot shove a stand-in out of its post the way a static body
## never could. The rifle's hitscan and the match manager still find them on
## layer 8, which is unchanged.
const BODY_MASK := 1 | 2
## The avoidance probe does watch layer 8 as well, so a stand-in steers around
## the other stand-ins instead of walking through them.
const AVOID_MASK := 1 | 2 | 8
## The mid barricade is solid at every height and each team's half is reachable
## only by spawning in it, so a stand-in never walks closer than this to z = 0.
const HALF_MARGIN := 2.0
const ARENA_LIMIT := 52.0
## A step is refused when the floor under it sits this far from the current
## feet: this is what keeps a stand-in from walking off a slab edge or into a
## stairwell hole.
const STEP_DROP := 0.7
const STEP_LOOKAHEAD := 1.4

## What a sightline and a shot both look at: arena geometry, the player, and the
## stand-ins themselves. Layer 8 has to be in here, or a shot would pass
## straight through the stand-in it is aimed at and hit the wall behind it.
const SHOT_MASK := 1 | 2 | 8
## Body heights a shot is aimed at, measured up from the feet: the player's chest
## (the height already in use) and the middle of a stand-in's own capsule.
const PLAYER_AIM_HEIGHT := 1.1
const STANDIN_AIM_HEIGHT := 0.9
## Ceiling on the line-of-sight raycasts one scan may spend choosing a target, on
## top of the single ray that re-checks the opponent it already had. Ten
## stand-ins thinking every 0.1 s must never raycast every other body in the
## arena, so candidates are ordered by distance and only the nearest few are
## tested.
const MAX_SIGHT_TESTS := 3

## Audio: shared project sound effects for the enemy stand-in.
const REPORT_SFX := "res://assets/models/sfx_powerful_assault_rifle_gunshot_.wav"
const IMPACT_SFX := "res://assets/models/sfx_bullet_impact_on_concrete_wall_.wav"
const HIT_SFX := "res://assets/models/e95fd3cc-b6b8-46e6-9468-68254efbe09e_sfx_heavy_body_impact_thud_player__1785424046667.wav"
const KILLED_SFX := "res://assets/models/4cee325f-5d20-40ea-b53a-332ed95490c5_sfx_low_effort_grunt_of_a_large_la__1786813518012.wav"

const REPORT_DB := -6.0
const HIT_DB := -5.0
const KILLED_DB := -5.0
const IMPACT_DB := -8.0

var health := 100.0

var _mesh: MeshInstance3D
var _alive: StandardMaterial3D
var _aiming: StandardMaterial3D
var _down: StandardMaterial3D
## Team identification: body and aiming telegraphs are tinted by allegiance to
## the player, kept current by _refresh_allegiance.
var _friendly_mat: StandardMaterial3D
var _enemy_mat: StandardMaterial3D
var _friendly_aim: StandardMaterial3D
var _enemy_aim: StandardMaterial3D
var _friendly := false
var _impact_mesh: SphereMesh
var _impact_mat: StandardMaterial3D
var _effects: Node3D
var _report: AudioStreamPlayer3D
var _cues: AudioStreamPlayer3D
var _report_sound: AudioStream
var _impact_sound: AudioStream
var _hit_sound: AudioStream
var _killed_sound: AudioStream
var _player
## The opponent this stand-in is currently watching, re-checked every scan.
var _target: Node
var _timer := 0.0
var _aim := 0.0
var _cooldown := 0.0
var _scan := 0.0
var _eye := Vector3(0.0, 1.45, 0.0)

# walking
var _route := PackedVector3Array()
var _home := Vector3.ZERO
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _wp := 0
var _pausing := false
var _wait := 0.0
var _goal := Vector3.ZERO
var _move_timer := 0.0
var _engaging := false

# squad layer: read from the "squad" group once, then reused
var _squad: Node

func _ready() -> void:
	# Layer 8 is what the rifle's hitscan and the match manager look for, so
	# that stays. The mask is authored as 0 in the scene, but a CharacterBody3D
	# with mask 0 collides with nothing at all and gravity would drop it
	# straight through the world, so the mask is widened here to the layers it
	# has to stand on and bump into. Nothing about layer 8 changes.
	collision_layer = 8
	collision_mask = BODY_MASK
	floor_snap_length = 0.4
	add_to_group("target")
	health = max_health
	_home = global_position
	_route = _build_route()
	_mesh = get_node_or_null("MeshInstance3D")
	# Both sides' snipers share the same rooftops, so a scoped shot has to tell
	# friend from foe at a glance: the player's own side reads cool steel blue
	# and the opposing side red, and the aiming telegraph keeps that split
	# instead of flattening everyone to one amber.
	_enemy_mat = _mat(Color(0.72, 0.22, 0.18), 0.8, false)
	_friendly_mat = _mat(Color(0.27, 0.45, 0.72), 0.8, false)
	_enemy_aim = _mat(Color(0.95, 0.72, 0.2), 0.5, true)
	_friendly_aim = _mat(Color(0.45, 0.85, 1.0), 0.5, true)
	_alive = _enemy_mat
	_aiming = _enemy_aim
	_down = _mat(Color(0.22, 0.22, 0.22), 1.0, false)
	_impact_mesh = SphereMesh.new()
	_impact_mesh.radius = 0.08
	_impact_mesh.height = 0.16
	_impact_mat = _mat(Color(1.0, 0.8, 0.5), 1.0, true)
	_impact_mat.emission = Color(1.0, 0.72, 0.35)
	_impact_mat.emission_energy_multiplier = 2.0
	_setup_audio()
	_refresh_allegiance()
	_set_state(_alive)
	set_process(armed)

## Tints the body and the aiming telegraph by allegiance to the player, so a
## teammate is never mistaken for an enemy at a shared firing position. Called
## every frame, which also re-labels both sides the moment the player presses T
## to switch teams.
func _refresh_allegiance() -> void:
	var p = _find_player()
	var friendly := false
	if p != null and ("team" in p):
		friendly = int(p.team) == team
	if friendly == _friendly:
		return
	_friendly = friendly
	_alive = _friendly_mat if friendly else _enemy_mat
	_aiming = _friendly_aim if friendly else _enemy_aim
	if _timer <= 0.0:
		_set_state(_alive)

## The stand-in's own gunfire and its hit cues, played from its position.
func _setup_audio() -> void:
	_report_sound = _load_sfx(REPORT_SFX)
	_impact_sound = _load_sfx(IMPACT_SFX)
	_hit_sound = _load_sfx(HIT_SFX)
	_killed_sound = _load_sfx(KILLED_SFX)
	_report = AudioStreamPlayer3D.new()
	_report.name = "Report"
	_report.stream = _report_sound
	_report.volume_db = REPORT_DB
	_report.unit_size = 12.0
	_report.max_distance = 300.0
	add_child(_report)
	_cues = AudioStreamPlayer3D.new()
	_cues.name = "Cues"
	_cues.volume_db = HIT_DB
	_cues.unit_size = 10.0
	_cues.max_distance = 200.0
	add_child(_cues)

func _load_sfx(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as AudioStream

## Plays one of the stand-in's cue sounds from its own position.
func _cue(s: AudioStream, db: float) -> void:
	if s == null or _cues == null:
		return
	_cues.stream = s
	_cues.volume_db = db
	_cues.play()

func _mat(c: Color, rough: float, glow: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	if glow:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = 1.4
	return m

func _set_state(m: StandardMaterial3D) -> void:
	if _mesh:
		_mesh.material_override = m

## Canonical damage entry point, returns true when this hit was the kill.
func take_damage(amount: float, source: Node = null) -> bool:
	if _timer > 0.0:
		return false
	health -= amount
	if health > 0.0:
		_cue(_hit_sound, HIT_DB)
		# Hit but still standing: break away from where the shot came from.
		_reposition_from(source)
		return false
	health = 0.0
	_timer = respawn_delay
	_aim = 0.0
	_cooldown = 0.0
	_scan = 0.0
	_move_timer = 0.0
	_release_permit()
	_set_state(_down)
	set_process(true)
	killed.emit()
	_cue(_killed_sound, KILLED_DB)
	return true

func _process(delta: float) -> void:
	_refresh_allegiance()
	if _timer > 0.0:
		_timer -= delta
		if _timer <= 0.0:
			_timer = 0.0
			health = max_health
			_set_state(_alive)
			_respawn_reset()
			if not armed:
				set_process(false)
		return
	if not armed:
		return
	_cooldown = maxf(0.0, _cooldown - delta)
	_scan -= delta
	if _scan > 0.0:
		return
	_scan = SCAN_STEP
	_think(SCAN_STEP)

## Watch for the nearest opponent it can see - the player while the player is on
## the other team, or a stand-in of the other team - telegraph the shot, then
## fire once the aim has settled. A stand-in with eyes on an enemy feeds that
## position to its team. One without eyes turns to watch the shared direction
## from where it stands and never walks toward it: the solid mid barricade seals
## the two halves of the arena, so an enemy in the other half is only ever
## engaged from an elevated post, never reached on foot. While it holds a firing
## clearance it plants and fights from where it stands.
func _think(step: float) -> void:
	var t = _pick_target()
	if t == null:
		# Nothing hostile in sight: drop the bead, hand the firing slot back and
		# watch the direction the team last shared, without moving.
		_aim = 0.0
		_engaging = false
		_release_permit()
		_set_state(_alive)
		_watch_contact(step)
		return
	var from: Vector3 = global_position + _eye
	var to: Vector3 = _aim_point(t)
	# Eyes on an enemy: this position becomes the team's contact, so the
	# teammates that cannot see it still know where it is.
	_share_contact(t.global_position)
	_engaging = true
	if _cooldown > 0.0:
		_aim = 0.0
		_release_permit()
		_set_state(_alive)
		return
	# Fire discipline, step one: line up a firing clearance with the squad
	# before opening a bead, so at most max_shooters of this team are drawing
	# a shot at the same time. A stand-in that is denied waits for a teammate to
	# free a slot instead of firing, and waits WITHOUT the amber about-to-fire
	# telegraph: only a stand-in that actually holds a clearance glows amber, so
	# a team can never stand in the open as a row of amber non-firing statues.
	if not _ask_permit():
		_set_state(_alive)
		return
	_aim = minf(_aim + step, aim_time)
	_set_state(_aiming)
	if _aim < aim_time:
		return
	# The aim has settled: the squad decides the exact moment of the shot. A
	# stand-in that is wait-listed keeps its bead on the target and fires the
	# moment the team's next gap opens instead of crowding the same instant.
	if not _take_shot():
		return
	_aim = 0.0
	_cooldown = shot_interval
	_fire(from, to)

## The player, whoever the player is currently fighting for. The caller decides
## whether the player is hostile, so switching sides with T is enough to make the
## player a target of one team and a teammate of the other again.
func _find_player():
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	return _player

## The nearest opponent this stand-in can actually see from where it stands,
## drawn from the player and the other team's stand-ins, or null when nothing
## hostile is in sight. Candidates are ordered by distance and only the nearest
## MAX_SIGHT_TESTS are ever spent a raycast on, so one scan costs a bounded
## handful of rays no matter how many stand-ins share the arena. The opponent it
## already had is re-checked with a single ray and kept while it is still hostile
## and still in sight, so a stand-in does not flicker between two enemies as it
## walks its route.
func _pick_target() -> Node:
	var from: Vector3 = global_position + _eye
	if (_target != null and is_instance_valid(_target) and _is_enemy(_target)
			and not _is_down(_target) and _in_sight(_target, from)):
		return _target
	_target = null
	var cands := _enemy_candidates()
	if cands.is_empty():
		return null
	cands.sort_custom(func(a, b): return _distance_to(a, from) < _distance_to(b, from))
	var tested := 0
	for c in cands:
		if tested >= MAX_SIGHT_TESTS:
			break
		tested += 1
		if _in_sight(c, from):
			_target = c
			return _target
	return null

## Everything hostile to this stand-in: the other team's stand-ins that are not
## down, plus the player while the player is on the other team. Its own teammates
## are never in this list, so it cannot aim at them in the first place.
func _enemy_candidates() -> Array:
	var out: Array = []
	for n in get_tree().get_nodes_in_group("target"):
		if n == self or not is_instance_valid(n):
			continue
		if _is_enemy(n) and not _is_down(n):
			out.append(n)
	var p = _find_player()
	if p != null and is_instance_valid(p) and _is_enemy(p) and not _is_down(p):
		out.append(p)
	return out

## True when this stand-in has eyes on the body right now: inside sight_range and
## a clear ray from its eye to the body's chest, with nothing in between.
func _in_sight(p, from: Vector3) -> bool:
	if p == null or not is_instance_valid(p):
		return false
	var to: Vector3 = _aim_point(p)
	if from.distance_to(to) > sight_range:
		return false
	return _clear(from, to, p)

## Where a shot at this body is aimed: the player's chest height, which is the
## one already in use, or the middle of a stand-in's own body capsule.
func _aim_point(p) -> Vector3:
	var h := PLAYER_AIM_HEIGHT if p.is_in_group("player") else STANDIN_AIM_HEIGHT
	return p.global_position + Vector3(0.0, h, 0.0)

func _distance_to(p, from: Vector3) -> float:
	if p == null or not is_instance_valid(p):
		return INF
	return from.distance_squared_to(p.global_position)

func _is_dead(p) -> bool:
	return bool(p.is_dead) if "is_dead" in p else false

## A body is out of play while the player reports is_dead, or while a stand-in's
## respawn timer is running, and an out-of-play body is never a target.
func _is_down(p) -> bool:
	if p == null or not is_instance_valid(p):
		return true
	if _is_dead(p):
		return true
	if "_timer" in p and float(p._timer) > 0.0:
		return true
	return false

## True when the body is on this stand-in's own team, which is the one thing it
## never shoots, whatever the shot was aimed at.
func _is_friendly(p) -> bool:
	if p == null or not is_instance_valid(p):
		return true
	if "team" in p:
		return int(p.team) == team
	return false

func _is_enemy(p) -> bool:
	if "team" in p:
		return int(p.team) != team
	return true

## True when the ray reaches the body with nothing in front of it. The mask
## includes the stand-in layer, so a stand-in target is actually hit by the ray
## instead of being passed straight through, and a teammate standing in the line
## blocks the shot instead of being shot through.
func _clear(from: Vector3, to: Vector3, p) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = SHOT_MASK
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return false
	return hit.collider == p

## Hitscan shot. Accuracy below 1.0 walks the shot off the aim point, so the ray
## is re-checked against what it actually hit: a body on this stand-in's own team
## never takes damage, which is what keeps a stray round friendly-fire free.
func _fire(from: Vector3, to: Vector3) -> void:
	if _report and _report.stream:
		_report.play()
	var miss := (1.0 - clampf(accuracy, 0.0, 1.0)) * 1.6
	var end: Vector3 = to + Vector3(
		randf_range(-miss, miss), randf_range(-miss, miss), randf_range(-miss, miss))
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, end)
	q.collision_mask = SHOT_MASK
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		_spawn_impact(end)
		return
	var col = hit.collider
	if col and col.has_method("take_damage") and not _is_friendly(col):
		col.take_damage(shot_damage, self)
	_spawn_impact(hit.position)

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
	tw.tween_property(m, "scale", Vector3(0.05, 0.05, 0.05), 0.3)
	tw.tween_callback(m.queue_free)

## One-shot impact audio where the stand-in's shot landed.
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
	p.max_distance = 300.0
	parent.add_child(p)
	p.global_position = spot
	p.finished.connect(p.queue_free)
	p.play()

# ------------------------------------------------------------------ squad

## The shared squad node, read from the "squad" group once and then reused. A
## missing squad node simply means no shared contacts and no fire discipline
## ceiling, so the stand-in keeps working on its own.
func _squad_node() -> Node:
	if _squad == null or not is_instance_valid(_squad):
		_squad = get_tree().get_first_node_in_group("squad")
	return _squad

## Tells the squad where this stand-in last saw an enemy. Only ever called with a
## live line of sight, so the contact is always first-hand.
func _share_contact(pos: Vector3) -> void:
	var s := _squad_node()
	if s:
		s.report_contact(team, pos, get_instance_id())

## Awareness, not navigation. When this stand-in cannot see an enemy but its team
## has a fresh shared contact, it turns on the spot to watch that direction and
## stays exactly where it is. Walking at a contact is never useful here: the
## solid mid barricade seals the two halves of the arena at every height, so an
## enemy in the other half cannot be reached, only shot across the divide from an
## elevated post.
##
## Gated on being stationary - a sentry holding an empty route, or one paused at
## a waypoint - because while it is walking the walk code already drives its
## facing and the two would fight and make it wobble.
func _watch_contact(step: float) -> void:
	if not _is_standing_still():
		return
	var s := _squad_node()
	if s == null:
		return
	var c: Dictionary = s.get_contact(team, global_position)
	if c.is_empty():
		return
	var spot: Vector3 = c["pos"]
	var d := Vector3(spot.x - global_position.x, 0.0, spot.z - global_position.z)
	if d.length_squared() < 0.001:
		return
	_face(d.normalized(), step)

## True when this stand-in is standing still by design, which is exactly when
## nothing else is driving its facing: it is not dead, not disarmed, not mid
## break-away reposition, and either a sentry with no route or a patroller
## paused at a waypoint.
func _is_standing_still() -> bool:
	if _timer > 0.0 or not armed:
		return false
	if _move_timer > 0.0:
		return false
	if _route.is_empty():
		return true
	return _pausing

## Asks the squad for a firing clearance, held for as long as this stand-in is
## lining up its shot. With no squad node in the scene there is no discipline
## to enforce, so the stand-in is free to fire on its own.
func _ask_permit() -> bool:
	var s := _squad_node()
	if s == null:
		return true
	return bool(s.request_fire(team, get_instance_id()))

## Commits the shot the moment its team's stagger window is open. A refusal
## keeps the clearance and the aim, so the stand-in fires as soon as the gap in
## its team's fire opens rather than crowding it.
func _take_shot() -> bool:
	var s := _squad_node()
	if s == null:
		return true
	return bool(s.confirm_shot(team, get_instance_id()))

## Hands the clearance back the moment this stand-in stops aiming or dies, so
## it frees a firing slot for a teammate.
func _release_permit() -> void:
	var s := _squad_node()
	if s:
		s.release_fire(get_instance_id())

# --------------------------------------------------------------- walking

## Gravity, floor stick and the walk step run in physics so the stand-in uses
## the real arena collision, which only exists once the game is running.
func _physics_process(delta: float) -> void:
	if is_on_floor():
		# Stay pressed against the floor so slabs and ramps keep holding it.
		velocity.y = -2.0
	else:
		velocity.y -= _gravity * delta
	_step(delta)
	move_and_slide()

func _step(delta: float) -> void:
	if _timer > 0.0 or not armed or _engaging:
		# Dead, disarmed, or holding a firing solution: plant and watch.
		velocity.x = 0.0
		velocity.z = 0.0
		return
	if _move_timer > 0.0:
		_move_timer -= delta
		if _step_toward(_goal, reposition_speed, delta):
			_move_timer = 0.0
		return
	if _route.is_empty():
		# Sentry: no route, so it holds its post and only moves when hit.
		velocity.x = 0.0
		velocity.z = 0.0
		return
	if _pausing:
		velocity.x = 0.0
		velocity.z = 0.0
		_wait -= delta
		if _wait <= 0.0:
			_pausing = false
			_wp = (_wp + 1) % _route.size()
		return
	# Reaching a waypoint, or meeting an edge with no floor beyond it, both land
	# here: the stand-in stops, watches and shoots before it moves on.
	if _step_toward(_route[_wp], move_speed, delta):
		_pausing = true
		_wait = patrol_wait

## Walks one step toward a world position. Returns true when the order is done:
## either it arrived, or the step is refused because there is no floor under it.
func _step_toward(goal: Vector3, speed: float, delta: float) -> bool:
	var to := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	if to.length() <= arrive_radius:
		velocity.x = 0.0
		velocity.z = 0.0
		return true
	var dir := _avoid(to.normalized())
	if dir.length_squared() < 0.0001:
		# Wedged with nowhere to slide: give up on this order instead of
		# standing there forever, so the route keeps cycling.
		velocity.x = 0.0
		velocity.z = 0.0
		return true
	if not _floor_ok(global_position + dir * STEP_LOOKAHEAD):
		velocity.x = 0.0
		velocity.z = 0.0
		return true
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	_face(dir, delta)
	return false

## One short ray ahead, then slide along whatever it hit. This walks the stand-in
## around cover, walls and the other stand-ins with no navigation mesh.
func _avoid(desired: Vector3) -> Vector3:
	var from: Vector3 = global_position + Vector3(0.0, 0.9, 0.0)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + desired * 1.6)
	q.collision_mask = AVOID_MASK
	q.collide_with_areas = false
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return _steer(global_position + desired * STEP_LOOKAHEAD)
	var n: Vector3 = hit.normal
	n.y = 0.0
	if n.length_squared() < 0.01:
		return Vector3.ZERO
	# Slide along the surface, then stick to a single side so it never jitters
	# against a corner it cannot decide about.
	var side := desired.cross(Vector3.UP).dot(n.normalized())
	var s := -1.0 if side > 0.0 else 1.0
	var slid := (n.normalized() * s).cross(Vector3.UP)
	if slid.length_squared() < 0.01:
		return Vector3.ZERO
	return _steer(global_position + slid * STEP_LOOKAHEAD)

## Direction toward a world point, after the point has been pulled back inside
## this stand-in's own team half and the arena walls.
func _steer(target: Vector3) -> Vector3:
	return _dir_at(_clamp(target))

func _dir_at(point: Vector3) -> Vector3:
	var d := Vector3(point.x - global_position.x, 0.0, point.z - global_position.z)
	if d.length_squared() < 0.0001:
		return Vector3.ZERO
	return d.normalized()

## Hard rule: team 0 lives at z < 0 and team 1 at z > 0, the mid barricade is
## solid at every height, and no stand-in may cross it.
func _clamp(point: Vector3) -> Vector3:
	var z := point.z
	if team == 0:
		z = minf(z, -HALF_MARGIN)
	else:
		z = maxf(z, HALF_MARGIN)
	z = clampf(z, -ARENA_LIMIT, ARENA_LIMIT)
	var x := clampf(point.x, -ARENA_LIMIT, ARENA_LIMIT)
	return Vector3(x, point.y, z)

## True when the feet can be planted at this spot: solid floor within STEP_DROP
## of the height it is standing at right now. This is what refuses a step off a
## building slab and a step into a stairwell hole.
func _floor_ok(at: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		at + Vector3(0.0, 0.8, 0.0), at - Vector3(0.0, 2.4, 0.0))
	# Floor geometry only: the player standing in a doorway must not read as a
	# floor, or the stand-in would freeze in front of them.
	q.collision_mask = 2
	q.collide_with_areas = false
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return false
	return absf((hit.position as Vector3).y - global_position.y) <= STEP_DROP

## Turns the visual toward a direction, preserving the -Z forward axis.
func _face(dir: Vector3, delta: float) -> void:
	if dir.length_squared() < 0.001:
		return
	var want := atan2(-dir.x, -dir.z)
	rotation.y = rotate_toward(rotation.y, want, 5.0 * delta)

# ------------------------------------------------------------- reactions

## Hit but still standing: sidestep away from whoever shot at it, within its own
## half. With no shooter on record it breaks toward the middle of the arena.
func _reposition_from(source: Node) -> void:
	var away := Vector3.FORWARD
	if source is Node3D:
		var d := global_position - (source as Node3D).global_position
		d.y = 0.0
		if d.length_squared() > 0.01:
			away = d.normalized()
	_goal = _clamp(global_position + away * 5.0)
	_move_timer = reposition_time
	_pausing = false
	_wait = 0.0

## Back to the post after respawning. The body is teleported so a stand-in that
## was killed somewhere awkward does not wake up inside geometry.
func _respawn_reset() -> void:
	velocity = Vector3.ZERO
	_wp = 0
	_pausing = false
	_wait = 0.0
	_move_timer = 0.0
	_engaging = false
	_target = null
	_release_permit()
	global_position = _home
	rotation = Vector3.ZERO

# ---------------------------------------------------------------- routing

## The authored ground route, or an empty route for a sentry. A stand-in posted
## off the ground plane - on a floor slab or a roof - holds its post instead of
## patrolling, which is also what keeps it from ever walking off an edge.
func _build_route() -> PackedVector3Array:
	if patrol_points.size() >= 2 and global_position.y < 1.0:
		return patrol_points
	return PackedVector3Array()
