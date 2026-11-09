Fixtures for tests/objc/audioio_test.m (made once with ffmpeg, a 1 kHz sine):

  ffmpeg -y -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=1" -ac 1 -b:a 32k tone-1s-44k-mono.mp3
  ffmpeg -y -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=1" -f lavfi -i "color=black:s=64x64:r=10:d=1" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 32k -shortest -movflags +faststart tone-video-1s.mp4
