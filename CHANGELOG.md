# Changelog

## 1.0.1

**Voices**
- The language of a sample is detected automatically ("Auto-detect" is now the first choice; picking it by hand stays
  possible). When Whisper is unsure between close languages it transcribes both readings and keeps the more convincing one.
- Accent removal: a voice cloned from a sample in one language (say, Russian) learns to speak another (say, Ukrainian)
  without the sample's accent — once per voice and language, about a minute. On by default; the Voices page shows what
  a voice has learned and lets you listen to it or forget it.
- Long recordings are cut to their best ~10 seconds at a pause instead of being used whole (the original is kept).
- Drop an audio file on the Voices page to use it as the sample.
- The text Whisper fills in is saved with the voice right away.

**Speech**
- Voice style panel: mood presets, intonation, energy, pitch, tone, speed, pauses, volume and quality.
- Voice design for the model's own voice: gender, age, pitch, whisper, English accents.
- "Sound" menu: laughter, sigh, surprise, questions as `[tags]` the model voices.
- Sentence splitting no longer depends on capital letters (Arabic, Hindi, Chinese, Japanese…); text without spaces is
  split by length.

**Design**
- New look: brand colours from the app icon, gradient primary buttons, softer cards, rounded titles, per-voice avatars,
  a status card with a memory meter in the sidebar.

**Fixes**
- A request made right after stopping the engine (changing a LoRA, a model or the precision) could fail with "Stopped".
- Output of a stopped engine process could mix into the next one.
- The app could be killed by SIGPIPE when the engine died while a command was being sent.
- Pages refreshed their whole state once a second while the engine was running.
- A renamed voice could get its old name back when cloning finished.
- "Engine 0.0 GB" in the sidebar while the engine was starting.
- `build.sh` failed to sign the app inside iCloud Drive / Dropbox folders.
- mlx-audio is pinned to the 0.5 line the engine was written against.

## 1.0.0

First release.
