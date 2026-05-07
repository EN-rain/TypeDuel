extends Node

@onready var music_player = $AudioStreamPlayer

func play_music(stream: AudioStream, loop: bool = true):
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
