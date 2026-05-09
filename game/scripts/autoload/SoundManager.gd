extends Node

@onready var music_player = $AudioStreamPlayer

const MUSIC_PATHS = {
	"menu": "res://assets/bgm/Loop-Menu.wav",
	"victory": "res://assets/bgm/Victory.wav",
	"battle": "res://assets/bgm/fight_looped.wav",
	"gameplay": "res://assets/bgm/as_fast_as_you_can_2.31_low.ogg"
}

func play_music(music_name_or_stream, loop: bool = true):
	var stream: AudioStream
	
	if music_name_or_stream is String:
		if MUSIC_PATHS.has(music_name_or_stream):
			stream = load(MUSIC_PATHS[music_name_or_stream])
		else:
			push_error("SoundManager: Music name '%s' not found!" % music_name_or_stream)
			return
	else:
		stream = music_name_or_stream

	if stream == null:
		return

	# set loop BEFORE the early return check
	if stream is AudioStreamMP3:
		stream.loop = loop
	elif stream is AudioStreamOggVorbis:
		stream.loop = loop
	elif stream is AudioStreamWAV:
		stream.loop_begin = 0
		stream.loop_end = stream.get_length() * stream.mix_rate
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED

	if music_player.stream == stream:
		return  # already playing
	
	music_player.stream = stream
	music_player.play()

func stop_music():
	music_player.stop()
