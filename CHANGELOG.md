# Changelog

## 2.0.0

Clone'n'Speak 2.0 has a new look and gets the tools of a full voice workbench. The main scenario, cloning a voice and
speaking text with it, is as light as before: the main engine still has no PyTorch and uses no memory when idle. The
heavy engines are separate downloads for Macs with 16 GB of unified memory, and each one says so with a "16 GB" badge.

**New look**
- Every page is redrawn on numbered cards with thin borders, in light and dark. There are eight palettes (Applio,
  Amethyst, Crimson, Cyberpunk, Emerald, Midnight, Sunset, Halloween), each with a light and a dark version; pick one
  in Settings → Appearance.
- The sidebar is grouped: Voice, Models & Training, Tools, System. It shows the version, the memory and the state of
  the engine.
- Emoji in the interface are SF Symbols now, with labels for VoiceOver. Sliders, switches and the player work from the
  keyboard, and Reduce Motion and Increase Contrast are respected.

**Audio Tools**
- Drop any recording, or take the sound from a video (MP4, MOV, M4V), up to 20 minutes.
- Analyzer with a spectrogram, a pitch curve and the spectral centroid, drawn natively.
- Effects chain: reverb, delay, chorus, compressor, limiter, distortion, bitcrush, gain, EQ, pitch shift and formant
  shift (timbre without a change of pitch).
- DeepFilterNet noise cleanup at 6, 18 or 30 dB (a ~35 MB download, checked by hash); the old light cleanup stays as
  "Light cleanup".
- Format conversion: WAV, M4A, FLAC and ALAC natively; MP3 and OGG when ffmpeg is installed.

**Separation**
- Remove music: keeps the voice, or only the music, with a small ONNX model that runs on any Mac. Also in
  *Improve sample* on the Voices page.
- Full stems on 16 GB Macs: a split into stems with htdemucs, higher-quality vocals with Kim_Vocal_2 and
  BS-Roformer, and dereverb. Models are downloaded on request, never bundled, and are
  checked against pinned hashes before every run. Three of them are marked "license unverified" (see Model licenses
  in the README).

**Speech**
- Export formats and a choice of format on the Speech page and in Settings.
- Presets save the voice style, the format and the effects chain; rename, delete, import and export as a file.
- Effects chain on the result, with the dry take kept next to it.
- Player with a scrubber and an A/B switch between the original and the result.
- Batch: a whole .txt, .md or .srt file, or one line per file, with one voice and style, progress and an output folder.
- Edge TTS (online, Microsoft) as a second engine. It sends the text to Microsoft, asks once and is refused in Offline
  mode. Its result can be passed through an RVC model or your cloned voice.

**Voices**
- Extended sample check: silence at the edges, the longest pause, problem spots marked on the waveform, and a
  comparison of several samples of one voice (levels, duplicates).
- *Improve sample*: DeepFilterNet cleanup and music removal next to the light cleanup.
- *Trim edges*: cut anything unwanted at the start or the end of a sample, not only silence. Drag the two handles on
  the waveform (or press `[` and `]` at the playhead), listen with *Play selection*, then *Apply*; the original is kept
  and *Restore original* brings it back.

**Models**
- LoRA adapters by Hugging Face link: paste the address of an adapter and the app downloads and checks it.
- RVC voice models: search, download by Hugging Face or direct link, import `.pth` and `.index` files, model details.
- Model folder (Settings → Storage): keep models on another disk. If the disk is not connected the app says so and
  refuses downloads instead of filling the startup disk.

**Pro features (Macs with 16 GB)**
- Convert: re-voice a recording with an RVC model (pitch, rmvpe / crepe / fcpe, index rate, protect, volume envelope,
  formant, autotune, cleanup) or with your own cloned voice through Seed-VC. Single file or batch, with an A/B switch
  against the original.
- Realtime: change your voice live through the microphone. Any input and output device; no drivers are installed (for
  Zoom or Discord, install a virtual device such as BlackHole yourself). The measured delay is shown while it runs.
- Training: train an RVC model from a folder of recordings or from a link, with a dataset check, preprocessing,
  feature extraction, training on the GPU (MPS), index building, an overtraining warning, resume and export.
- Voice Blender: mix two RVC models in a ratio you choose.
- YouTube import: take the sound of a video link (asks for your confirmation that you have the rights and the
  speaker's consent). Only the link is sent to YouTube.
- Each engine installs on request with its size shown and can be removed. Before a pro job the main engine unloads its
  models, so the two are never in memory together. On a Mac with less than 16 GB the app warns and lets you go on.

**Jobs**
- A history of everything long that the app did: speech, conversion, training, separation, downloads. Progress, log,
  stop and run again. Jobs that were running when the app quit show as interrupted.

**Local API and Bridge**
- A local REST API on 127.0.0.1 with a key kept in the Keychain: speech, voice cloning, conversion, jobs, lists of
  voices and models. Off by default.
- Bridge reaches the API from your phone through a Cloudflare quick tunnel. Off by default; the tunnel program is
  downloaded once and checked, every device has to be approved on the Mac and can be revoked, and the tunnel is closed
  when the app quits.

**Plugins**
- A plugins folder with a manifest per plugin. A plugin runs as a separate process, is off until you switch it on, and
  the page warns that it is third-party code.

**Data & Privacy, Offline mode**
- A page that lists what stays on the Mac, what can go online (Edge TTS, YouTube import, Bridge, model downloads,
  plugin network access) and when, with a "never used / asked" state for each, where every folder lives and a button
  to reveal or delete it.
- Offline mode (Settings): every online feature, including model downloads, is refused with a message; local work is
  not affected.

Voices, settings and downloaded models from 1.0.x are kept.

## 1.0.3

**Pronunciation training**
- *Train…* next to the voice on the Speech page: teaches the voice clean pronunciation in a language, in up to three
  rounds, judging every round on phrases it never learned on by two numbers — pronunciation (Whisper) and likeness to
  the original sample. Every round can be heard and picked by ear; *Back to the original sample* undoes it. The numbers
  of the voice in the language of the text stay next to it.
- With the optional Seed-VC download (~2.7 GB, Models page or the training sheet) the voice learns from a native
  narrator — the model's own voice or another voice of yours — converted to its own timbre. That removes even an accent
  in the sample's own language: an English voice cloned from a Russian-accented sample went from 72 % to 87 %
  pronunciation at 52 % likeness (66 % before); learning from its own takes only got it worse (59 %).
  Seed-VC (GPL-3.0) is fetched from its repository into its own PyTorch environment and runs as a separate program.

**Typing**
- Voice name: a space at the end of the name was swallowed on every key press, so "My voice" couldn't be typed.
  The sample text lost its cursor position and undo the same way: every key press saved the voice, which reloaded
  the list and refilled the editor. The field being typed in is left alone now.
- The sample text no longer autocorrects, replaces text or turns `--` into dashes: it has to stay word for word.
- The seed (Settings), the Hugging Face token and the mirror (Models) are saved when you leave the field, not only on
  Return.

## 1.0.2

**Ukrainian speech sounds Ukrainian again**
- Stress marks no longer reach the model. Every mark in the text pulls OmniVoice towards Russian pronunciation:
  with dictionary marks on every word (the 1.0.1 development builds) Whisper took a Russian-accented clone's Ukrainian
  for Russian more often than not (P(ru) 0.21 → 0.43, errors 2.1 % → 4.7 %), and even ten hand-placed marks cost a
  native Ukrainian clone its clarity (errors 1.3 % → 2.9 %, P(uk) 0.79 → 0.67). Measurements in README → Stress.
- A hand-placed mark (**Stress ´**, ⌘') now works through ✨ Auto-improve: of the takes of that phrase, the one that
  stresses the marked syllable wins (a hand-marked word weighs three dictionary words in the stress judge). The
  status line says so when a mark is placed, and reminds you to switch auto-improve on.

**Voices**
- Ukrainian or Russian sample: both readings are still made, but Whisper's likelihood of each now decides on its own
  for clean speech (a clean Russian recording reads as Russian at −0.02…−0.05 and as Ukrainian at −0.3; clean
  Ukrainian the other way round) — no question asked. Only Ukrainian with a heavy Russian accent, where both readings
  are poor, is cloned as Ukrainian and shown for a choice, with the misheard words highlighted.
- Accented samples: when Whisper finds a sample's own transcript unlikely (Ukrainian read with a Russian accent),
  the voice goes through accent removal in its *own* language too before it first speaks it. Measured on such a
  sample: Whisper took 60 % of its direct Ukrainian for Russian (P(uk) 0.33, errors 5.3 %); after accent removal
  P(uk) 0.72, errors 2.8 %, likeness to the sample 0.81. The Speech page says so under the voice.

## 1.0.1

**Ukrainian**
- Whisper can't tell accented Ukrainian from Russian (it said "Russian, 100 %" on Ukrainian speech and wrote a
  gibberish transcript that ruined the clone): for such samples the app shows both readings and asks.
- Words of a Ukrainian transcript that aren't in the dictionary (misheard ones) are highlighted after transcribing and
  cloning; Whisper's text is not suggested when it is worse Ukrainian than the typed one.
- Russian letters in Ukrainian text and transcripts are fixed: оксамыт → оксамит (ы → и, э → е, ъ → ').
- Stress: only marks you place by hand (**Stress ´**, ⌘') reach the model. Marking every word from a dictionary was
  measured and made Ukrainian worse (Whisper errors 4.3 % → 7.9 % and 1.0 % → 8.3 % on two clones), so it is not
  done; the lang-uk dictionary (installed with the engine, 13 MB) only judges takes in auto-improve and spots
  misheard words. Generation defaults re-checked (steps, guidance, t_shift): the upstream ones are the best.

**Voice likeness**
- Every take shows how much it sounds like the sample (ECAPA speaker verification from speechbrain, ported to MLX —
  no PyTorch; the weights, 83 MB, come into the Hugging Face cache on first use).

**✨ Auto-improve: the best of several takes**
- Every phrase is spoken N times (Settings → Takes per phrase, 3 by default) and the take with the best combined score
  is kept: recognition errors, native pronunciation (Whisper's likelihood — catches a Russian «и» in Ukrainian),
  likeness to the sample and, for Ukrainian, words on their dictionary stress.

**Voices**
- The language of a sample is detected automatically ("Auto-detect" is now the first choice; picking it by hand stays
  possible). When Whisper is unsure between close languages it transcribes both readings and keeps the more convincing one.
- Accent removal: a voice cloned from a sample in one language (say, Russian) learns to speak another (say, Ukrainian)
  without the sample's accent — once per voice and language, about two minutes. Six takes (two phrases × three) are
  scored by likeness to the real sample and by Whisper; the two best together become the voice's sample for the
  language. Russian sample → Ukrainian: Whisper errors 5.7 % → 2.6 % at the same likeness. The Voices page shows what
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
