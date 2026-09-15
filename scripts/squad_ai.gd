extends Node
## Squad layer for the enemy stand-ins: one small shared brain per team.
##
## Two things live here. CONTACT SHARING: a stand-in with a clear line of sight
## to the player records that position for its own team, and every teammate on
## that team can ask for the team's freshest contact. FIRE DISCIPLINE: a
## stand-in asks permission before it shoots, and permission is granted only
## while that team is below its ceiling of simultaneous shooters and far enough
## past the team's last shot.
##
## The node never walks the scene tree and owns no geometry, so a team of five
## stand-ins costs five calls per scan and nothing else. It follows the shape of
## the match manager: a plain Node, joined to a group, read by others through
## that group.
##
## Callers: report_contact / get_contact for contacts, request_fire /
## confirm_shot / release_fire / note_shot for fire discipline.

## A stand-in refreshes its permit on every scan (0.1 s), so a permit nobody has
## touched for this long belongs to a stand-in that is dead, disarmed or blind,
## and is dropped so it cannot block its teammates.
const PERMIT_TTL := 0.6

## How long a shared contact stays actionable, in seconds.
@export var contact_lifetime := 8.0
## A teammate only acts on a contact this close to it, in metres.
@export var alert_radius := 70.0
## Ceiling on the stand-ins of one team firing at the player at the same time.
@export var max_shooters := 2
## Minimum spacing between two shots from the same team, in seconds.
@export var shot_stagger := 0.7

var _clock := 0.0
var _contacts := {}    # team -> { "pos": Vector3, "t": float, "by": int }
var _permits := {}     # stand-in instance id -> { "team": int, "age": float }
var _last_shot := {}   # team -> clock time of that team's most recent shot

func _ready() -> void:
	add_to_group("squad")

func _process(delta: float) -> void:
	_clock += delta
	# Permits are leases, not locks: expire the ones nobody is refreshing.
	for id in _permits.keys():
		var lease: Dictionary = _permits[id]
		lease["age"] = float(lease["age"]) + delta
		if float(lease["age"]) > PERMIT_TTL:
			_permits.erase(id)

# ---------------------------------------------------------------- contacts

## A stand-in with a clear line of sight records where it saw the player. This
## is the single entry point for a team's contact, and each refresh overwrites
## the previous position, so the contact tracks the player while it is watched.
func report_contact(team: int, pos: Vector3, by: int = 0) -> void:
	_contacts[team] = {"pos": pos, "t": _clock, "by": by}

## The team's contact as this stand-in could act on it: fresh enough, and close
## enough to the asker to matter. Returns an empty dictionary when there is
## nothing to act on, otherwise { "valid", "pos", "age", "by" }.
func get_contact(team: int, from: Vector3) -> Dictionary:
	var c = _contacts.get(team, null)
	if c == null:
		return {}
	var age := _clock - float(c["t"])
	if age > contact_lifetime:
		return {}
	var pos: Vector3 = c["pos"]
	if from.distance_to(pos) > alert_radius:
		return {}
	return {"valid": true, "pos": pos, "age": age, "by": int(c["by"])}

func has_contact(team: int, from: Vector3) -> bool:
	return not get_contact(team, from).is_empty()

## Age of the team's contact in seconds, or -1.0 when the team has none.
func contact_age(team: int) -> float:
	var c = _contacts.get(team, null)
	if c == null:
		return -1.0
	return _clock - float(c["t"])

# ---------------------------------------------------------- fire discipline

## Permission to line up a shot. A stand-in asks on every scan while it has a
## firing solution and a shot available, and the answer stays true for as long
## as it holds a clearance. A stand-in is handed a fresh clearance only while
## fewer than max_shooters of its team already hold one and its team is past
## the stagger since its last shot, so a denied stand-in holds its aim.
func request_fire(team: int, id: int) -> bool:
	var lease = _permits.get(id, null)
	if lease != null:
		lease["age"] = 0.0
		return true
	if shooter_count(team) >= max_shooters:
		return false
	if since_last_shot(team) < shot_stagger:
		return false
	_permits[id] = {"team": team, "age": 0.0}
	return true

## Fires the shot if this team's stagger window is open. Returns true and
## records the shot; a false leaves the clearance and the aim in place, so the
## stand-in fires the moment the gap in its team's fire opens.
func confirm_shot(team: int, id: int) -> bool:
	if since_last_shot(team) < shot_stagger:
		return false
	_permits.erase(id)
	note_shot(team)
	return true

## Drops a clearance: the stand-in stopped aiming, was killed, or just fired.
func release_fire(id: int) -> void:
	_permits.erase(id)

## Records a shot, which is what spaces the rest of the team's fire.
func note_shot(team: int) -> void:
	_last_shot[team] = _clock

## How many stand-ins of this team hold a firing clearance right now.
func shooter_count(team: int) -> int:
	var n := 0
	for lease in _permits.values():
		if int(lease["team"]) == team:
			n += 1
	return n

## Seconds since this team's last shot, or a huge number when it has not fired.
func since_last_shot(team: int) -> float:
	return _clock - float(_last_shot.get(team, -1000.0))
