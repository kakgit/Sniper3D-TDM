extends Node
## Team Deathmatch state: team scores, the session clock, a short kill feed and
## the match-over result.
##
## The player is read from the "player" group and the enemy stand-ins from the
## "target" group. A killed stand-in scores for the team opposing it, and a dead
## player scores for the team opposing the player. Both are derived from the
## node's own team value, so switching sides with T keeps scoring correct.

const ALPHA_COLOR := Color(0.55, 0.78, 1.0)
const BRAVO_COLOR := Color(0.98, 0.52, 0.42)

@export var match_seconds := 3600.0   ## one-hour session (lower it to test)
@export var feed_lifetime := 6.0
@export var feed_max := 5

var alpha := 0
var bravo := 0
var time_left := 3600.0
var running := true
var winner := -1
var feed: Array = []

var _player: Node
var _wired := false
var _rescan := 0.0
var _wired_targets: Dictionary = {}

func _ready() -> void:
	add_to_group("match")
	time_left = match_seconds
	# the groups fill up as siblings run their own _ready, so wire one frame late
	call_deferred("_wire")

func _process(delta: float) -> void:
	_age_feed(delta)
	if not _wired:
		_rescan -= delta
		if _rescan <= 0.0:
			_rescan = 1.0
			_wire()
	if not running:
		return
	time_left = maxf(0.0, time_left - delta)
	if time_left <= 0.0:
		_end_match()

## Connects the player and every enemy stand-in exactly once.
func _wire() -> void:
	if _player == null or not is_instance_valid(_player):
		var p := get_tree().get_first_node_in_group("player")
		if p != null and p.has_signal("died"):
			_player = p
			p.died.connect(_on_player_died)
	for t in get_tree().get_nodes_in_group("target"):
		var id := t.get_instance_id()
		if _wired_targets.has(id) or not t.has_signal("killed"):
			continue
		_wired_targets[id] = true
		t.killed.connect(_on_target_killed.bind(t))
	_wired = _player != null and not _wired_targets.is_empty()

func _age_feed(delta: float) -> void:
	var i := feed.size() - 1
	while i >= 0:
		feed[i]["t"] = float(feed[i]["t"]) - delta
		if float(feed[i]["t"]) <= 0.0:
			feed.remove_at(i)
		i -= 1

func _add_feed(text: String, color: Color) -> void:
	feed.append({"text": text, "color": color, "t": feed_lifetime})
	while feed.size() > feed_max:
		feed.pop_front()

## A stand-in going down scores for the team that is not its own. Both teams'
## stand-ins fight each other, so the feed names the casualty's own team rather
## than calling it an enemy: a stand-in dying is correct wording whichever side
## the player is currently fighting for. Scoring itself is unchanged.
func _on_target_killed(t: Node) -> void:
	if not running:
		return
	var t_team := int(t.team) if "team" in t else 1
	if t_team == 0:
		bravo += 1
		_add_feed("ALPHA stand-in down    BRAVO +1", BRAVO_COLOR)
	else:
		alpha += 1
		_add_feed("BRAVO stand-in down    ALPHA +1", ALPHA_COLOR)

## The player going down scores for the team that is not the player's.
func _on_player_died(_delay: float) -> void:
	if not running:
		return
	var p_team := int(_player.team) if _player != null and "team" in _player else 0
	if p_team == 0:
		bravo += 1
		_add_feed("You were eliminated    BRAVO +1", BRAVO_COLOR)
	else:
		alpha += 1
		_add_feed("You were eliminated    ALPHA +1", ALPHA_COLOR)

func _end_match() -> void:
	running = false
	time_left = 0.0
	winner = 0 if alpha > bravo else (1 if bravo > alpha else -1)

## Resets scores, clock and feed, and puts the player back on its spawn line.
func restart() -> void:
	alpha = 0
	bravo = 0
	time_left = match_seconds
	winner = -1
	feed.clear()
	running = true
	if _player != null and is_instance_valid(_player) and _player.has_method("teleport_to_spawn"):
		_player.teleport_to_spawn()

func _unhandled_input(event: InputEvent) -> void:
	if running:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ENTER or event.physical_keycode == KEY_KP_ENTER:
			restart()
