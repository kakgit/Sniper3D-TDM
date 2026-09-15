extends AudioStreamPlayer
## Desert ambience bed: one looping, non-positional stream that runs for the
## whole match. Sparse wind and empty space, no music, no rhythmic pulse.
## The stream and its loop flag are set here so the bed carries into export
## regardless of the WAV import options, and play() starts it with the match.

const AMBIENCE_SFX := "res://assets/models/62fabb1a-dcb0-4e13-9538-244e014a17cc_sfx_desert_wind_ambience_with_subt__1783115435859.wav"

func _ready() -> void:
	add_to_group("ambience")
	if stream == null and ResourceLoader.exists(AMBIENCE_SFX):
		stream = load(AMBIENCE_SFX) as AudioStream
	_enable_loop()
	if stream != null and not playing:
		play()

## Turns looping on for whichever stream type the bed was given.
func _enable_loop() -> void:
	var s := stream
	if s is AudioStreamWAV:
		var w := s as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = 0
	elif s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true
	elif s is AudioStreamMP3:
		(s as AudioStreamMP3).loop = true
