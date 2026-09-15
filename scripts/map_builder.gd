extends Node3D
## Builds the desert TDM arena at runtime.
## - sand ground ringed by impassable sand berms
## - one fully solid mid barricade: neither team can cross on foot
## - two identical 3-floor buildings (open-plan), window tiers, ground doors,
##   interior ramps between floors and roof access with loopholes
## Layout is point-mirrored: Team A spawns at z = -50, Team B at z = +50 and
## the two buildings sit diagonally opposite each other.

const MAP_HALF := 60.0
const WALL_H := 3.6
const WALL_T := 0.8

const B_W := 20.0
const B_D := 12.0
const FLOOR_H := 3.0
const FLOORS := 3
const SLAB_T := 0.3
const SHELL_T := 0.3
const PARAPET_H := 1.1
const ROOF_Y := 9.0

const BUILDING_POS := [Vector3(-20.0, 0.0, -30.0), Vector3(20.0, 0.0, 30.0)]
const SPAWN_A := [Vector3(-40.0, 0.0, -50.0), Vector3(-13.0, 0.0, -50.0),
	Vector3(13.0, 0.0, -50.0), Vector3(40.0, 0.0, -50.0)]
const SPAWN_B := [Vector3(-40.0, 0.0, 50.0), Vector3(-13.0, 0.0, 50.0),
	Vector3(13.0, 0.0, 50.0), Vector3(40.0, 0.0, 50.0)]

const HX := 10.0
const HZ := 6.0

var _ground: StandardMaterial3D
var _floor: StandardMaterial3D
var _wall: StandardMaterial3D
var _trim: StandardMaterial3D
var _mid: StandardMaterial3D
var _ramp: StandardMaterial3D
var _blue: StandardMaterial3D
var _red: StandardMaterial3D
var _props: Node3D

# Seamlessly tileable surface textures for the arena architecture: the
# "Dust Frontier" desert-industrial albedo set (1024x1024, edge-to-edge
# repeatable). They let the ground, buildings and barricade read as the same
# dusty, sun-bleached military surfaces as the imported library props.
const TEX_DIR := "res://textures/"
const TEX_SAND := TEX_DIR + "arena_sand_ground.png"
const TEX_CONCRETE := TEX_DIR + "arena_concrete_weathered.png"
const TEX_CONCRETE_FLOOR := TEX_DIR + "arena_concrete_floor.png"
const TEX_STEEL_PANEL := TEX_DIR + "arena_metal_panel.png"
## Building-wall texture picked by the user (Abandoned School Peeling Wall
## Texture). It applies to the buildings only; the Dust Frontier set still
## covers the ground, the floor slabs, the ramps and the mid barricade.
const TEX_PEEL := "res://assets/images/img-1781959550211-0.jpg"

var _tex_ground: Texture2D
var _tex_wall: Texture2D
var _tex_floor: Texture2D
var _tex_mid: Texture2D

# curated library cover props (collection: shooter-military)
const PROP_DIR := "res://assets/library/shooter-military/"
const P_CONT_A := PROP_DIR + "modular-containers-and-barrells-pack-game-ready-container-320.glb"
const P_CONT_B := PROP_DIR + "modular-containers-and-barrells-pack-game-ready-container-001-321.glb"
const P_CRATE_A := PROP_DIR + "modular-containers-and-barrells-pack-game-ready-cube-001-335.glb"
const P_CRATE_B := PROP_DIR + "modular-containers-and-barrells-pack-game-ready-cube-334.glb"
const P_DRUM_A := PROP_DIR + "modular-containers-and-barrells-pack-game-ready-cylinder-328.glb"
const P_DRUM_B := PROP_DIR + "modular-containers-and-barrells-pack-game-ready-cylinder-001-329.glb"
const P_DRUM_C := PROP_DIR + "modular-containers-and-barrells-pack-game-ready-cylinder-003-331.glb"
const D_CONT := Vector3(2.4, 2.2, 6.0)
const D_CRATE := Vector3(1.0, 1.0, 1.0)
const D_DRUM := Vector3(0.83, 1.32, 0.83)

func _ready() -> void:
	_make_materials()
	_build_ground()
	_build_mid_wall()
	for p in BUILDING_POS:
		_build_building(p)
	_build_props()
	_build_spawns()

func _make_materials() -> void:
	_tex_ground = load(TEX_SAND)
	_tex_wall = load(TEX_CONCRETE)
	_tex_floor = load(TEX_CONCRETE_FLOOR)
	_tex_mid = load(TEX_STEEL_PANEL)
	# The albedo colours stay as light warm tints multiplied over the textures,
	# so the original palette relationship (warm sand, paler walls, darker trim)
	# survives while the textures keep their sun-bleached variety.
	_ground = _mat(Color(1.0, 0.96, 0.89))
	_texture(_ground, _tex_ground, 0.16)
	_floor = _mat(Color(0.98, 0.96, 0.93))
	_texture(_floor, _tex_floor, 0.25)
	_wall = _mat(Color(1.0, 0.98, 0.95))
	# The buildings wear the texture the user chose. The columns, cover and
	# barricade keep the concrete, so the swap is limited to the walls.
	_texture(_wall, load(TEX_PEEL), 0.33)
	_trim = _mat(Color(0.72, 0.7, 0.67))
	_texture(_trim, _tex_wall, 0.5)
	_mid = _mat(Color(0.96, 0.94, 0.9))
	_texture(_mid, _tex_mid, 0.33)
	_ramp = _mat(Color(0.9, 0.88, 0.85))
	_texture(_ramp, _tex_floor, 0.33)
	_blue = _mat(Color(0.15, 0.35, 0.85), true)
	_red = _mat(Color(0.8, 0.18, 0.15), true)

func _mat(c: Color, glow := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.95
	if glow:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = 1.6
	return m

## Gives a plain colour material a seamless texture using world-space triplanar
## mapping. Triplanar means a 200 m ground plane and a 20 m wall tile at a
## constant metres-per-tile instead of stretching across their box face UVs, and
## because the projection is world space the pattern also stays continuous across
## the many separate boxes the walls and floors are cut into.
func _texture(m: StandardMaterial3D, tex: Texture2D, tiles_per_meter: float) -> void:
	if tex == null:
		return
	m.albedo_texture = tex
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3(tiles_per_meter, tiles_per_meter, tiles_per_meter)
	m.uv1_offset = Vector3.ZERO

# ------------------------------------------------------------------ primitives

func _box(center: Vector3, size: Vector3, mat: StandardMaterial3D, parent: Node3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	body.position = center
	parent.add_child(body)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	mesh.material_override = mat
	body.add_child(mesh)
	var col := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	col.shape = sh
	body.add_child(col)
	return body

func _plate(center: Vector3, size: Vector3, mat: StandardMaterial3D, parent: Node3D) -> void:
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	mesh.material_override = mat
	mesh.position = center
	parent.add_child(mesh)

## Wall along X: u runs along world/local x, v is height, at a fixed z.
func _wall_x(parent: Node3D, z: float, u0: float, u1: float, y0: float, y1: float,
		thick: float, holes: Array, mat: StandardMaterial3D) -> void:
	_wall_cut(parent, true, z, u0, u1, y0, y1, thick, holes, mat)

## Wall along Z: u runs along world/local z, v is height, at a fixed x.
func _wall_z(parent: Node3D, x: float, u0: float, u1: float, y0: float, y1: float,
		thick: float, holes: Array, mat: StandardMaterial3D) -> void:
	_wall_cut(parent, false, x, u0, u1, y0, y1, thick, holes, mat)

func _wall_cut(parent: Node3D, along_x: bool, fixed: float, u0: float, u1: float,
		y0: float, y1: float, thick: float, holes: Array, mat: StandardMaterial3D) -> void:
	var ys: Array = [y0, y1]
	for o in holes:
		ys.append(o.position.y)
		ys.append(o.end.y)
	ys.sort()
	var prev := y0 - 1.0
	for y in ys:
		if y < y0 - 0.001 or y > y1 + 0.001:
			continue
		if y - prev < 0.01:
			continue
		if prev >= y0 - 0.001 and y > prev + 0.01:
			_band(parent, along_x, fixed, u0, u1, prev, y, thick, holes, mat)
		prev = maxf(prev, y)

func _band(parent: Node3D, along_x: bool, fixed: float, u0: float, u1: float,
		ya: float, yb: float, thick: float, holes: Array, mat: StandardMaterial3D) -> void:
	if yb - ya < 0.01:
		return
	var cuts: Array = []
	for o in holes:
		if o.position.y < yb - 0.001 and o.end.y > ya + 0.001:
			cuts.append(o)
	cuts.sort_custom(func(a, b): return a.position.x < b.position.x)
	var cur := u0
	for o in cuts:
		var a: float = maxf(o.position.x, u0)
		var b: float = minf(o.end.x, u1)
		if a > cur + 0.001:
			_piece(parent, along_x, fixed, cur, a, ya, yb, thick, mat)
		cur = maxf(cur, b)
	if cur < u1 - 0.001:
		_piece(parent, along_x, fixed, cur, u1, ya, yb, thick, mat)

func _piece(parent: Node3D, along_x: bool, fixed: float, ua: float, ub: float,
		ya: float, yb: float, thick: float, mat: StandardMaterial3D) -> void:
	if along_x:
		_box(Vector3((ua + ub) * 0.5, (ya + yb) * 0.5, fixed),
			Vector3(ub - ua, yb - ya, thick), mat, parent)
	else:
		_box(Vector3(fixed, (ya + yb) * 0.5, (ua + ub) * 0.5),
			Vector3(thick, yb - ya, ub - ua), mat, parent)

## Walkable ramp from (z_b, y_b) up to (z_t, y_t), width x0..x1. The bottom end
## is buried below the floor so there is no lip to get stuck on.
func _slope(parent: Node3D, x0: float, x1: float, z_b: float, y_b: float,
		z_t: float, y_t: float, mat: StandardMaterial3D) -> void:
	var run := z_t - z_b
	var rise := y_t - y_b
	var diag := sqrt(run * run + rise * rise)
	if diag < 0.01:
		return
	var ext := 0.8
	var cosa := absf(run) / diag
	var dir := Vector3(0.0, rise / diag, run / diag)
	var mid := Vector3((x0 + x1) * 0.5, (y_b + y_t) * 0.5, (z_b + z_t) * 0.5) - dir * (ext * 0.5)
	mid.y -= 0.15 * cosa
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	body.position = mid
	body.rotation.x = -atan2(rise, run)
	parent.add_child(body)
	var size := Vector3(x1 - x0, 0.3, diag + ext)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	mesh.material_override = mat
	body.add_child(mesh)
	var col := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	col.shape = sh
	body.add_child(col)

# --------------------------------------------------------------------- terrain

func _build_ground() -> void:
	_box(Vector3(0.0, -0.5, 0.0), Vector3(200.0, 1.0, 200.0), _ground, self)
	# perimeter berms, too tall to climb (2.4 m) and sealing the corners
	var b := MAP_HALF - 2.0
	_box(Vector3(-b, 1.2, 0.0), Vector3(4.0, 2.4, MAP_HALF * 2.0), _ground, self)
	_box(Vector3(b, 1.2, 0.0), Vector3(4.0, 2.4, MAP_HALF * 2.0), _ground, self)
	_box(Vector3(0.0, 1.2, -b), Vector3(MAP_HALF * 2.0 + 8.0, 2.4, 4.0), _ground, self)
	_box(Vector3(0.0, 1.2, b), Vector3(MAP_HALF * 2.0 + 8.0, 2.4, 4.0), _ground, self)

func _build_mid_wall() -> void:
	# one solid slab, no openings at any height: zero chance of crossing
	_box(Vector3(0.0, WALL_H * 0.5, 0.0),
		Vector3(MAP_HALF * 2.0, WALL_H, WALL_T), _mid, self)
	_box(Vector3(0.0, 0.25, 0.0),
		Vector3(MAP_HALF * 2.0, 0.5, WALL_T + 0.5), _trim, self)

# -------------------------------------------------------------------- building

func _build_building(pos: Vector3) -> void:
	var g := Node3D.new()
	g.name = "Building"
	g.position = pos
	add_child(g)
	_build_slabs(g)
	_build_shell(g)
	_build_slopes(g)
	_build_columns(g)
	_build_parapet(g)

func _build_slabs(g: Node3D) -> void:
	var y1 := FLOOR_H - SLAB_T * 0.5
	var y2 := FLOOR_H * 2.0 - SLAB_T * 0.5
	var y3 := ROOF_Y - SLAB_T * 0.5
	# level 1 floor: open stairwell over x[-10,-7] z[-6,-2.0]
	_box(Vector3(1.5, y1, 0.0), Vector3(17.0, SLAB_T, 12.0), _floor, g)
	_box(Vector3(-8.5, y1, 2.0), Vector3(3.0, SLAB_T, 8.0), _floor, g)
	# level 2 floor: holes for the 1F-2F ramp and the 2F-roof ramp
	_box(Vector3(3.0, y2, 0.0), Vector3(14.0, SLAB_T, 12.0), _floor, g)
	_box(Vector3(-5.5, y2, -5.0), Vector3(3.0, SLAB_T, 2.0), _floor, g)
	_box(Vector3(-5.5, y2, 3.5), Vector3(3.0, SLAB_T, 5.0), _floor, g)
	_box(Vector3(-8.5, y2, -4.9), Vector3(3.0, SLAB_T, 2.2), _floor, g)
	# roof: hole only over the top of the final ramp
	_box(Vector3(1.5, y3, 0.0), Vector3(17.0, SLAB_T, 12.0), _floor, g)
	_box(Vector3(-8.5, y3, 3.65), Vector3(3.0, SLAB_T, 4.7), _floor, g)

func _build_shell(g: Node3D) -> void:
	for f in range(FLOORS):
		var y := FLOOR_H * float(f)
		_wall_x(g, -HZ, -HX, HX, y, y + FLOOR_H, SHELL_T, _front_holes(f), _wall)
		_wall_x(g, HZ, -HX, HX, y, y + FLOOR_H, SHELL_T, _back_holes(f), _wall)
		_wall_z(g, -HX, -HZ, HZ, y, y + FLOOR_H, SHELL_T, _side_holes(f), _wall)
		_wall_z(g, HX, -HZ, HZ, y, y + FLOOR_H, SHELL_T, _side_holes(f), _wall)

func _build_slopes(g: Node3D) -> void:
	_slope(g, -HX, -7.0, -2.0, 0.0, -5.8, FLOOR_H, _ramp)
	_slope(g, -7.0, -4.0, 1.0, FLOOR_H, -4.0, FLOOR_H * 2.0, _ramp)
	_slope(g, -HX, -7.0, -3.8, FLOOR_H * 2.0, 1.2, ROOF_Y, _ramp)

func _build_columns(g: Node3D) -> void:
	for f in range(FLOORS):
		var y := FLOOR_H * float(f) + FLOOR_H * 0.5
		for x in [-3.0, 3.0]:
			for z in [-3.5, 3.5]:
				_box(Vector3(x, y, z), Vector3(0.6, FLOOR_H, 0.6), _trim, g)

func _build_parapet(g: Node3D) -> void:
	var y0 := ROOF_Y
	var y1 := ROOF_Y + PARAPET_H
	_wall_x(g, -HZ, -HX, HX, y0, y1, SHELL_T, _roof_holes(), _wall)
	_wall_x(g, HZ, -HX, HX, y0, y1, SHELL_T, _roof_holes(), _wall)
	_wall_z(g, -HX, -HZ, HZ, y0, y1, SHELL_T, _roof_holes_side(), _wall)
	_wall_z(g, HX, -HZ, HZ, y0, y1, SHELL_T, _roof_holes_side(), _wall)

# openings: Rect2(u_start, v_start, u_len, v_len)
func _win(u: float, y: float) -> Rect2:
	return Rect2(u, y + 1.0, 1.3, 1.3)

func _door(u: float) -> Rect2:
	return Rect2(u, 0.0, 2.0, 2.4)

func _front_holes(f: int) -> Array:
	var y := FLOOR_H * float(f)
	var o: Array = []
	if f == 0:
		o.append(_door(-1.0))
		for u in [-6.5, 6.5]:
			o.append(_win(u, y))
	else:
		for u in [-6.5, 0.0, 6.5]:
			o.append(_win(u, y))
	return o

func _back_holes(f: int) -> Array:
	return _front_holes(f)

func _side_holes(f: int) -> Array:
	var y := FLOOR_H * float(f)
	var o: Array = []
	for u in [-3.0, 3.0]:
		o.append(_win(u, y))
	if f > 0:
		o.append(_win(0.0, y))
	return o

func _roof_holes() -> Array:
	var o: Array = []
	for u in [-7.5, -2.5, 2.5, 7.5]:
		o.append(Rect2(u - 0.45, ROOF_Y + 0.4, 0.9, 0.55))
	return o

func _roof_holes_side() -> Array:
	var o: Array = []
	for u in [-4.0, 0.0, 4.0]:
		o.append(Rect2(u - 0.45, ROOF_Y + 0.4, 0.9, 0.55))
	return o

# ----------------------------------------------------------------------- props

func _build_props() -> void:
	_props = Node3D.new()
	_props.name = "Cover"
	add_child(_props)
	# shipping containers: long hard cover that carves firing lanes, mirrored
	# each entry: x, z, yaw, prop
	var conts: Array = [
		[-38.0, -14.0, 0.0, P_CONT_A],
		[38.0, 14.0, 0.0, P_CONT_B],
		[-14.0, -38.0, 90.0, P_CONT_B],
		[14.0, 38.0, 90.0, P_CONT_A],
		[-42.0, 20.0, 0.0, P_CONT_B],
		[42.0, -20.0, 0.0, P_CONT_A],
	]
	for c in conts:
		_cover(Vector3(c[0], 0.0, c[1]), D_CONT, c[2], c[3])
	# crate clusters: waist-high cover you can still shoot over
	# x, z pairs
	var crates: Array = [
		Vector2(-28.0, -20.0), Vector2(-26.8, -20.0), Vector2(-27.4, -21.1),
		Vector2(-27.4, -20.5),
		Vector2(28.0, 20.0), Vector2(26.8, 20.0), Vector2(27.4, 21.1),
		Vector2(27.4, 20.5),
		Vector2(-33.0, 6.0), Vector2(33.0, -6.0),
		Vector2(-6.0, -30.0), Vector2(6.0, 30.0),
		Vector2(-46.0, -26.0), Vector2(46.0, 26.0),
	]
	for i in range(crates.size()):
		var p: Vector2 = crates[i]
		var path := P_CRATE_A if i % 2 == 0 else P_CRATE_B
		_cover(Vector3(p.x, 0.0, p.y), D_CRATE, 0.0, path)
		# second layer on the twin clusters
		if i == 3 or i == 7:
			_cover(Vector3(p.x, 1.0, p.y), D_CRATE, 0.0, path)
	# steel drums: small cover and sightline breakers
	# x, z pairs
	var drums: Array = [
		Vector2(-18.0, -8.0), Vector2(-16.9, -8.3),
		Vector2(18.0, 8.0), Vector2(16.9, 8.3),
		Vector2(-44.0, -10.0), Vector2(44.0, 10.0),
		Vector2(-9.0, -14.0), Vector2(9.0, 14.0),
	]
	var dp: Array = [P_DRUM_A, P_DRUM_B, P_DRUM_C]
	for i in range(drums.size()):
		var p: Vector2 = drums[i]
		_cover(Vector3(p.x, 0.0, p.y), D_DRUM, 0.0, dp[i % 3])

## Static cover: a box collider for gameplay plus the library prop for looks.
## The prop is authored to sit on the ground, so it is pulled down by half the
## collider height to match the raised collider body.
func _cover(xz: Vector3, size: Vector3, yaw: float, path: String) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	body.position = xz + Vector3(0.0, size.y * 0.5, 0.0)
	body.rotation.y = deg_to_rad(yaw)
	_props.add_child(body)
	var col := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	col.shape = sh
	body.add_child(col)
	var ps := load(path)
	if ps is PackedScene:
		var vis: Node3D = (ps as PackedScene).instantiate()
		vis.position = Vector3(0.0, -size.y * 0.5, 0.0)
		body.add_child(vis)

func _build_spawns() -> void:
	var i := 1
	for p in SPAWN_A:
		_spawn_marker("SpawnA%d" % i, p, PI, _blue, "spawn_a")
		i += 1
	i = 1
	for p in SPAWN_B:
		_spawn_marker("SpawnB%d" % i, p, 0.0, _red, "spawn_b")
		i += 1

func _spawn_marker(nm: String, p: Vector3, yaw: float, mat: StandardMaterial3D, grp: String) -> void:
	var n := Node3D.new()
	n.name = nm
	n.position = p
	n.rotation.y = yaw
	add_child(n)
	n.add_to_group(grp)
	_plate(Vector3(0.0, 0.06, 0.0), Vector3(2.0, 0.12, 2.0), mat, n)
	# banner sits BEHIND the spawn point: local +z is backwards for both teams,
	# so it never blocks the player's forward view on spawn
	_plate(Vector3(0.0, 1.2, 2.2), Vector3(1.2, 2.4, 0.12), mat, n)
