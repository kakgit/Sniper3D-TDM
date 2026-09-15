extends Node
## LAN session manager, registered as the "NetworkManager" autoload.
##
## Owns one ENet peer for the whole process. The host opens a listen server on
## PORT, a joiner opens a client aimed at an address, and every node in the tree
## then shares that peer through the default MultiplayerAPI, so RPC node paths
## line up on both machines. Nothing here touches gameplay - it gets two
## machines connected and reports the connection state.

signal session_started(mode: int)   ## a peer was created (host or client)
signal client_connected()           ## client side: the handshake completed
signal peer_joined(peer_id: int)    ## server side: a client finished joining
signal peer_left(peer_id: int)      ## a peer went away
signal session_ended()              ## the session closed, back to solo play
signal state_changed()              ## the status text changed

const PORT := 8910
const HOST_PEER := 1             ## the host is always ENet peer 1
const ROOM_SLOTS := 20           ## a room is 20 places: 10 a side
const TEAM_SIZE := 10            ## places per team
const DEFAULT_ADDRESS := "127.0.0.1"
const OFFLINE_STATUS := "OFFLINE - playing solo"

enum Mode { OFFLINE, HOST, CLIENT }

var mode: int = Mode.OFFLINE
var status := OFFLINE_STATUS
var port := PORT
var address := DEFAULT_ADDRESS

## Server side only: peer id -> {"team": int, "slot": int}. The slot is the place
## inside that team, 0 .. TEAM_SIZE - 1, so the two teams together are exactly
## ROOM_SLOTS places. This is the single place teams are handed out, so every
## machine in the room ends up agreeing on who is where.
var _roster: Dictionary = {}
var _alpha := 0                  ## room tally, published to every peer
var _bravo := 0


func is_online() -> bool:
	return mode != Mode.OFFLINE


func is_host() -> bool:
	return mode == Mode.HOST


## Opens a listen server on p_port. Returns false, leaving a readable status,
## when the port cannot be taken.
func host_game(p_port: int = PORT) -> bool:
	_end_session(OFFLINE_STATUS)
	port = p_port
	address = DEFAULT_ADDRESS
	var peer := ENetMultiplayerPeer.new()
	# room capacity is the client side of ROOM_SLOTS: the host holds one place
	var err := peer.create_server(port, ROOM_SLOTS - 1)
	if err != OK:
		status = "HOST FAILED - port %d (error %d)" % [port, err]
		state_changed.emit()
		return false
	multiplayer.multiplayer_peer = peer
	_wire_signals()
	mode = Mode.HOST
	assign_slot(HOST_PEER)   # the host is a player too, and holds place one
	status = "HOSTING on port %d - waiting for a player" % port
	state_changed.emit()
	session_started.emit(mode)
	return true


## Joins a host at p_address:p_port. Returns false when the client cannot even
## be created; an unreachable host arrives later as CONNECTION FAILED.
func join_game(p_address: String = DEFAULT_ADDRESS, p_port: int = PORT) -> bool:
	_end_session(OFFLINE_STATUS)
	address = p_address.strip_edges()
	if address.is_empty():
		address = DEFAULT_ADDRESS
	port = p_port
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		status = "JOIN FAILED - %s:%d (error %d)" % [address, port, err]
		state_changed.emit()
		return false
	multiplayer.multiplayer_peer = peer
	_wire_signals()
	mode = Mode.CLIENT
	status = "CONNECTING to %s:%d ..." % [address, port]
	state_changed.emit()
	session_started.emit(mode)
	return true


## Closes the session and hands the game back to single player.
func leave_game() -> void:
	_end_session(OFFLINE_STATUS)


## Wired at host and join time, before any peer can arrive, so a handshake is
## never missed. Guarded against double connects, because a peer can be
## replaced more than once in a session of the same process.
func _wire_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)


## Drops the peer and returns to offline. Emits session_ended so the scene can
## take its session players down, and only changes the status when a session
## was actually running.
func _end_session(message: String) -> void:
	var was_online := is_online()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	mode = Mode.OFFLINE
	_roster.clear()
	_alpha = 0
	_bravo = 0
	if was_online:
		status = message
		state_changed.emit()
		session_ended.emit()


func _on_peer_connected(peer_id: int) -> void:
	if peer_id == HOST_PEER:
		return  # the host is peer 1 and never announces itself
	if is_host():
		# hand the place out before announcing, so whoever spawns this peer
		# already knows which team and slot it has
		assign_slot(peer_id)
	status = _host_status()
	state_changed.emit()
	peer_joined.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if is_host():
		# the place goes back into the room, so the next joiner can take it
		release_slot(peer_id)
	if mode == Mode.HOST:
		status = _host_status()
		state_changed.emit()
	peer_left.emit(peer_id)


func _on_connected_to_server() -> void:
	status = "CONNECTED to %s:%d as peer %d" % [address, port, multiplayer.get_unique_id()]
	state_changed.emit()
	client_connected.emit()


func _on_connection_failed() -> void:
	_end_session("CONNECTION FAILED - %s:%d" % [address, port])


func _on_server_disconnected() -> void:
	_end_session("HOST LEFT - back to solo")


func _host_status() -> String:
	var players := 1
	if multiplayer.multiplayer_peer != null:
		players += multiplayer.get_peers().size()
	return "HOSTING on port %d - %d/%d player(s)" % [port, players, ROOM_SLOTS]


# --- the room: places, sides and the tally every peer sees -----------------


## Puts a peer into the room, or returns {} when both sides are full. The side
## with more free places wins, so the two teams stay level as players arrive.
func assign_slot(peer_id: int) -> Dictionary:
	if _roster.has(peer_id):
		return _roster[peer_id]
	var alpha_free := TEAM_SIZE - _count_team(0)
	var bravo_free := TEAM_SIZE - _count_team(1)
	if alpha_free <= 0 and bravo_free <= 0:
		return {}   ## room full: nobody else gets a place
	var side := 0 if alpha_free >= bravo_free else 1
	var entry := {"team": side, "slot": _count_team(side)}
	_roster[peer_id] = entry
	_publish_room()
	return entry


## Frees a peer's place when it leaves, so the next joiner takes that slot.
func release_slot(peer_id: int) -> void:
	if not _roster.has(peer_id):
		return
	_roster.erase(peer_id)
	_publish_room()


## The place a peer holds, or {} when it has none.
func slot_of(peer_id: int) -> Dictionary:
	return _roster.get(peer_id, {})


## Server: moves a peer to the other side when that side has a free place, and
## publishes the move so every peer applies it to that peer's body.
func try_change_team(peer_id: int) -> bool:
	var entry: Dictionary = _roster.get(peer_id, {})
	if entry.is_empty():
		return false
	var other := 1 - int(entry["team"])
	if _count_team(other) >= TEAM_SIZE:
		return false
	var moved := {"team": other, "slot": _count_team(other)}
	_roster[peer_id] = moved
	_publish_room()
	_apply_team.rpc(peer_id, other, int(moved["slot"]))
	return true


## The team tally as it stands in this machine's copy of the room.
func room_counts() -> Vector2i:
	return Vector2i(_alpha, _bravo)


## One short line for the menu, so a player can see the room and their side.
func room_line() -> String:
	return "ROOM %d/%d  -  ALPHA %d  BRAVO %d" % [
		_alpha + _bravo, ROOM_SLOTS, _alpha, _bravo]


## How many places a side holds, read from the roster. Only the server keeps the
## roster up to date; every other peer receives the same list.
func _count_team(side: int) -> int:
	var n := 0
	for id in _roster.keys():
		if int(_roster[id].get("team", 0)) == side:
			n += 1
	return n


## Recomputes the tally and, on the server, re-sends the whole place list. The
## list travels as peer id -> {team, slot}, so a peer that joined late is put
## right as soon as anything about the room changes.
func _publish_room() -> void:
	_alpha = _count_team(0)
	_bravo = _count_team(1)
	if multiplayer.multiplayer_peer != null and is_host():
		_apply_room.rpc(_roster.duplicate(true))
	state_changed.emit()


## Clients: adopt the server's room, so every machine agrees on who is where.
@rpc("authority", "call_remote", "reliable")
func _apply_room(roster: Dictionary) -> void:
	_roster = roster.duplicate(true)
	_alpha = _count_team(0)
	_bravo = _count_team(1)
	state_changed.emit()


## A team move, applied on every peer at the same moment. call_local because the
## host is a player too: its own move has to land on the host as well.
@rpc("authority", "call_local", "reliable")
func _apply_team(peer_id: int, team: int, slot: int) -> void:
	if _roster.has(peer_id):
		_roster[peer_id] = {"team": team, "slot": slot}
	var session := get_tree().get_first_node_in_group("net_session")
	if session != null and session.has_method("apply_team_change"):
		session.apply_team_change(peer_id, team, slot)
	state_changed.emit()
