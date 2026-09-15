extends Node
## LAN session node (World/NetSession).
##
## Spawns exactly one player per connected peer under World/Players, named after
## the peer id so the node path is identical on every machine, and hands each
## copy to the peer that plays it. Every peer pushes its own body's movement to
## the others, and remote bodies are driven by those updates.
##
## The arena is generated locally by map_builder.gd on every peer from the same
## constants, so no geometry, prop or stand-in state is networked here. Only the
## spawn of a player per peer and that player's movement cross the wire. While a
## session runs the scene's solo player steps aside and the AI stand-ins are
## switched off: the match is human versus human.

const PLAYER_SCENE: PackedScene = preload("res://player.tscn")
const SYNC_INTERVAL := 0.05    ## 20 movement pushes per second
const SNAP_DISTANCE := 6.0     ## a jump bigger than this is a respawn

@export var players_path: NodePath = ^"../Players"
@export var targets_path: NodePath = ^"../Targets"
@export var solo_player_path: NodePath = ^"../Player"

var _players: Dictionary = {}     ## peer id (int) -> player body
var _states: Dictionary = {}      ## peer id (int) -> last state from its owner
var _sync_accum := 0.0
var _session_active := false
var _targets_saved: Dictionary = {}
var _lan: Node


func _ready() -> void:
	# the local player asks this node for a team change through the group, so a
	# body does not need a hardcoded path to it
	add_to_group("net_session")
	_lan = get_node_or_null("/root/NetworkManager")
	if _lan == null:
		return
	if _lan.has_signal("session_started"):
		_lan.session_started.connect(_on_session_started)
	if _lan.has_signal("peer_joined"):
		_lan.peer_joined.connect(_on_peer_joined)
	if _lan.has_signal("peer_left"):
		_lan.peer_left.connect(_on_peer_left)
	if _lan.has_signal("session_ended"):
		_lan.session_ended.connect(_on_session_ended)


## True while this process owns a live listen server.
func _is_server() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


func _players_container() -> Node3D:
	return get_node_or_null(players_path) as Node3D


## The host owns peer 1 and spawns it immediately. Clients wait for the
## server's spawn call, which lands as soon as the handshake completes.
func _on_session_started(_mode: int) -> void:
	if _is_server():
		_spawn_for(1)   # the host is peer 1


## A client finished joining: spawn it, and spawn everyone already here for it,
## because a late joiner missed the earlier spawn calls. The room has already
## given the joiner its team and slot by now, so every machine spawns it the
## same way.
func _on_peer_joined(peer_id: int) -> void:
	if not _is_server():
		return
	var ids: Array = _players.keys()
	ids.append(peer_id)
	for id in ids:
		_spawn_for(int(id))


func _on_peer_left(peer_id: int) -> void:
	if _is_server():
		_despawn_player.rpc(peer_id)
	else:
		_despawn_player(peer_id)


func _on_session_ended() -> void:
	_clear_players()
	_set_session_active(false)


## Creates one player body for a peer on every machine. The body is named after
## the peer id and owned by that peer, so the same node path exists everywhere
## and only its owner drives it. The team and the slot come from the room, so
## every machine puts the same peer on the same side and the same marker.
@rpc("authority", "call_local", "reliable")
func _spawn_player(peer_id: int, team: int, slot: int) -> void:
	if _players.has(peer_id) and is_instance_valid(_players[peer_id]):
		return
	var container := _players_container()
	if container == null:
		return
	var body = PLAYER_SCENE.instantiate()
	body.name = str(peer_id)
	body.set("team", team)
	body.set("spawn_slot", slot)                ## set before _ready: it spawns there
	body.set_multiplayer_authority(peer_id)     ## before _ready: it gates input
	container.add_child(body)
	_players[peer_id] = body
	if peer_id == multiplayer.get_unique_id():
		_set_session_active(true)
		if body.has_method("claim_local_view"):
			body.claim_local_view()


@rpc("authority", "call_local", "reliable")
func _despawn_player(peer_id: int) -> void:
	var body = _players.get(peer_id)
	_players.erase(peer_id)
	_states.erase(peer_id)
	if body != null and is_instance_valid(body):
		body.queue_free()


func _clear_players() -> void:
	for peer_id in _players.keys():
		var body = _players[peer_id]
		if body != null and is_instance_valid(body):
			body.queue_free()
	_players.clear()
	_states.clear()


## Movement replication: the owner of each body pushes where it is, everyone
## else copies that onto their copy of the same body.
func _process(delta: float) -> void:
	if _players.is_empty():
		return
	if not multiplayer.get_peers().is_empty():
		_push_own_state(delta)
	_present_remote_players(delta)


func _push_own_state(delta: float) -> void:
	var mine = _players.get(multiplayer.get_unique_id())
	if mine == null or not is_instance_valid(mine):
		return
	_sync_accum += delta
	if _sync_accum < SYNC_INTERVAL:
		return
	_sync_accum = 0.0
	_push_state.rpc(
		mine.global_position,
		float(mine.get("yaw")),
		float(mine.get("pitch")),
		bool(mine.get("crouching")),
		bool(mine.get("is_dead")))


## Received on every peer that does not own that body. The remote sender id is
## the only trustworthy "who sent this", and a peer may only move its own body.
@rpc("any_peer", "call_remote", "unreliable_ordered")
func _push_state(pos: Vector3, body_yaw: float, body_pitch: float, crouch: bool, dead: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0 or not _players.has(sender):
		return
	_states[sender] = {
		"pos": pos,
		"yaw": body_yaw,
		"pitch": body_pitch,
		"crouch": crouch,
		"dead": dead,
	}


func _present_remote_players(delta: float) -> void:
	for peer_id in _states.keys():
		var body = _players.get(peer_id)
		if body == null or not is_instance_valid(body):
			continue
		if body.is_multiplayer_authority():
			continue
		var s: Dictionary = _states[peer_id]
		if body.has_method("apply_remote_state"):
			body.apply_remote_state(s["pos"], s["yaw"], s["pitch"], s["crouch"], s["dead"], delta)


## While a session runs the scene's solo player steps aside and the AI stand-ins
## are switched off, so the only players on the field are the connected peers.
func _set_session_active(active: bool) -> void:
	if active == _session_active:
		return
	_session_active = active
	var solo := get_node_or_null(solo_player_path)
	if solo != null and solo.has_method("park_offline"):
		solo.park_offline(active)
	_set_targets_active(not active)


## Switches the ten stand-ins off for the duration of a session, remembering
## what they looked like so leaving the session puts the solo match back.
func _set_targets_active(active: bool) -> void:
	var targets := get_node_or_null(targets_path)
	if targets == null:
		return
	if active:
		for child in targets.get_children():
			var saved: Dictionary = _targets_saved.get(String(child.name), {})
			child.visible = true
			child.process_mode = Node.PROCESS_MODE_INHERIT
			_restore_collision(child, saved)
		_targets_saved.clear()
		return
	for child in targets.get_children():
		if child is CollisionObject3D:
			var co := child as CollisionObject3D
			_targets_saved[String(child.name)] = {
				"layer": co.collision_layer,
				"mask": co.collision_mask,
			}
			co.collision_layer = 0
			co.collision_mask = 0
		child.process_mode = Node.PROCESS_MODE_DISABLED
		child.visible = false


func _restore_collision(child: Node, saved: Dictionary) -> void:
	if not (child is CollisionObject3D) or saved.is_empty():
		return
	var co := child as CollisionObject3D
	co.collision_layer = int(saved.get("layer", co.collision_layer))
	co.collision_mask = int(saved.get("mask", co.collision_mask))


# --- room placement: side and slot come from the server, never from here ----


## Server: looks up a peer's place in the room and tells every machine to spawn
## it there. A peer with no place (both sides full) is not spawned at all.
@rpc("authority", "call_local", "reliable")
func _spawn_for(peer_id: int) -> void:
	var entry := _slot_entry(peer_id)
	if entry.is_empty():
		push_warning("NetSession: no room place for peer %d" % peer_id)
		return
	_spawn_player.rpc(peer_id, int(entry["team"]), int(entry["slot"]))


## This peer's place, read from the room the NetworkManager mirrors on every
## machine, so a late joiner lands on the side the server chose for it.
func _slot_entry(peer_id: int) -> Dictionary:
	var lan: Node = get_node_or_null("/root/NetworkManager")
	if lan == null or not lan.has_method("slot_of"):
		return {}
	return lan.slot_of(peer_id)


## The local player pressed the team key. The room owns the team list, so the
## request goes to the server, which answers with a move or with nothing when
## the other side is full.
@rpc("any_peer", "call_remote", "reliable")
func request_team_switch() -> void:
	if not _is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()   ## the host asked on its own behalf
	var lan: Node = get_node_or_null("/root/NetworkManager")
	if lan == null or not lan.has_method("try_change_team"):
		return
	lan.try_change_team(sender)


## The room moved a peer to the other side: its body takes the new side and
## respawns on that side's line. Runs on every peer, so no copy disagrees.
func apply_team_change(peer_id: int, team: int, slot: int) -> void:
	var body = _players.get(peer_id)
	if body == null or not is_instance_valid(body):
		return
	body.set("team", team)
	body.set("spawn_slot", slot)
	if body.has_method("teleport_to_spawn"):
		body.teleport_to_spawn()
