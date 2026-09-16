extends RefCounted
class_name TouchConfig
## Where the player's own touch layout and tap gestures live.
##
## One small config file holds two things: where each on-screen control sits, and
## which action each tap gesture fires. The Control Settings page writes it, the
## touch layer reads it, so the editor and the game can never disagree about
## where a control is.
##
## Positions are stored as fractions of the screen (0.0 to 1.0), not pixels. The
## project stretches with canvas_items / expand, so the number of canvas units
## across the screen changes with the phone's aspect ratio: a FIRE button saved
## at x = 1100 would sit a different distance from the right edge on a wider
## phone. A fraction keeps it in the same place on every screen.

const CONFIG_PATH := "user://controls.cfg"
const LAYOUT_SECTION := "layout"
const GESTURE_SECTION := "gestures"

## Every control the player may drag. LookArea is deliberately absent: it is not
## a button but the region that turns a drag into a look, so it stays put.
const DRAGGABLE := [
	"MovePad",
	"FireButton",
	"AimButton",
	"CrouchButton",
	"SprintButton",
	"ReloadButton",
	"JumpButton",
	"MenuButton",
]

## The four gestures the settings page offers.
const GESTURES := ["left_tap", "right_tap", "left_double_tap", "right_double_tap"]

## What each gesture fires when the player has never changed it. This follows the
## example the feature was asked for: a tap on the right fires, two quick taps on
## the left raise the scope. The other two stay off, because an action nobody
## asked for is worse than one that has to be switched on.
const DEFAULT_GESTURES := {
	"left_tap": "",
	"right_tap": "shoot",
	"left_double_tap": "aim",
	"right_double_tap": "",
}

## What a gesture may be bound to, in the order the dropdown lists them. Movement
## is left out on purpose: a tap is a momentary press, and holding a direction
## with one would not move the player anywhere useful.
const GESTURE_ACTIONS := [
	["", "NONE"],
	["shoot", "FIRE"],
	["aim", "AIM"],
	["reload", "RELOAD"],
	["jump", "JUMP"],
	["crouch", "CROUCH"],
	["sprint", "SPRINT"],
]


## The config as it stands on disk. A missing file is not an error: the scene's
## own layout and the default gestures stand in for it.
static func _open() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	return cfg


## True once the player has saved a layout of their own.
static func has_layout() -> bool:
	return _open().has_section(LAYOUT_SECTION)


## Control name -> Vector2 fraction of the screen. Empty when nothing was saved,
## which is the signal to keep the scene's authored layout.
static func load_layout() -> Dictionary:
	var out := {}
	var cfg := _open()
	if not cfg.has_section(LAYOUT_SECTION):
		return out
	for name in DRAGGABLE:
		var v: Variant = cfg.get_value(LAYOUT_SECTION, name, null)
		if v is Vector2:
			out[String(name)] = v
	return out


static func save_layout(fractions: Dictionary) -> void:
	var cfg := _open()
	for name in fractions.keys():
		var v: Variant = fractions[name]
		if v is Vector2:
			cfg.set_value(LAYOUT_SECTION, String(name), v)
	cfg.save(CONFIG_PATH)


## Drops the saved layout rather than overwriting it, so the next launch starts
## from the layout the scene was authored with.
static func clear_layout() -> void:
	var cfg := _open()
	if cfg.has_section(LAYOUT_SECTION):
		cfg.erase_section(LAYOUT_SECTION)
		cfg.save(CONFIG_PATH)


## Gesture key -> action name, with the defaults filling in anything unset.
static func load_gestures() -> Dictionary:
	var out := DEFAULT_GESTURES.duplicate()
	var cfg := _open()
	if not cfg.has_section(GESTURE_SECTION):
		return out
	for key in GESTURES:
		var v: Variant = cfg.get_value(GESTURE_SECTION, key, null)
		if v is String:
			out[String(key)] = String(v)
	return out


static func save_gestures(actions: Dictionary) -> void:
	var cfg := _open()
	for key in GESTURES:
		cfg.set_value(GESTURE_SECTION, String(key), String(actions.get(key, "")))
	cfg.save(CONFIG_PATH)


static func clear_gestures() -> void:
	var cfg := _open()
	if cfg.has_section(GESTURE_SECTION):
		cfg.erase_section(GESTURE_SECTION)
		cfg.save(CONFIG_PATH)
