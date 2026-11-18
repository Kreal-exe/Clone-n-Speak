# Clone'n'Speak

Voice cloning, speech, voice conversion and audio tools for Apple Silicon Macs. It runs on an 8 GB M1 and uses the
extra memory of a 16 GB Mac for the heavy engines.

Clone'n'Speak is a native macOS app (Objective-C / AppKit) around the open
[OmniVoice](https://github.com/k2-fsa/OmniVoice) model, running on Apple's [MLX](https://github.com/ml-explore/mlx)
through [mlx-audio](https://github.com/Blaizzy/mlx-audio). You record 3 to 10 seconds of a voice, type text and get the
text spoken in that voice in 600+ languages, with Ukrainian and Russian treated with particular care. Version 2.0 adds
what a voice workbench needs around that: RVC voice conversion, realtime voice change, model training, music removal
and stems, an effects chain, batch speech, a local API and a page that says what leaves the Mac.

Everything runs locally. There is no cloud, no account and no subscription. The few features that use the network are
marked Online, ask first and are switched off by Offline mode.

[Русская версия ↓](#русский)

<p align="center">
  <img src="docs/screenshots/voices-dark.png" width="49%" alt="Voices, dark theme">
  <img src="docs/screenshots/voices-light.png" width="49%" alt="Voices, light theme">
</p>

## What is in 2.0

The sidebar groups the pages. A "16 GB" badge marks the pro features that need a Mac with 16 GB of unified memory:
they are visible on every Mac, install on request, and on a smaller Mac the app warns before they start and lets you go
on.

| Group | Pages |
|---|---|
| Voice | Speech, Voices, Convert (16 GB), Realtime (16 GB) |
| Models & Training | Models, Training (16 GB), Voice Blender (16 GB) |
| Tools | Audio Tools, Separation |
| System | Jobs, API & Bridge, Plugins (16 GB), Data & Privacy, Settings, Setup |

### Speech and Voices

Type text, pick a cloned voice, speak. The Speech page keeps the voice style (mood, intonation, energy, pitch, tone,
speed, pauses) in a "Voice style" block, with presets that also remember the file format and the effects chain.
Results export as WAV, M4A, FLAC or ALAC, and as MP3 or OGG when ffmpeg is installed. The player has a scrubber and an
A/B switch between the dry take and the processed one. Batch speech reads a whole .txt, .md or .srt file, or one line per
file. Edge TTS (Microsoft, online) is a second engine, and its result can be passed through an RVC model.

The Voices page checks a sample for loudness, noise, clipping, silence at the edges and long pauses, marks the problem
spots on the waveform, and compares several samples of one voice. *Improve sample* cleans it with DeepFilterNet, removes
music, shortens pauses and normalizes the level.

<p align="center">
  <img src="docs/screenshots/synth-dark.png" width="49%" alt="Speech: mood, quality, voice style and presets">
  <img src="docs/screenshots/synth-light.png" width="49%" alt="Speech, light theme">
</p>

### Audio Tools and Separation

Audio Tools take any recording, or the sound of a video, up to 20 minutes: an analyzer (spectrogram, pitch curve),
an effects chain (reverb, delay, chorus, compressor, limiter, distortion, bitcrush, gain, EQ, pitch, formant shift),
noise cleanup at 6, 18 or 30 dB and format conversion.

Separation removes the music and keeps the voice, or the reverse. That works on any Mac with a small ONNX model. On a
16 GB Mac it also splits a mix into stems and removes reverb.

<p align="center">
  <img src="docs/screenshots/tools-dark.png" width="49%" alt="Audio Tools">
  <img src="docs/screenshots/separator-dark.png" width="49%" alt="Separation">
</p>

### Convert, Realtime and Voice Blender (16 GB)

Convert re-voices a recording with an RVC model (pitch, rmvpe / crepe / fcpe, index rate, protect, volume envelope,
formant, autotune, cleanup) or with your own cloned voice through Seed-VC. Realtime changes your voice live through
the microphone with any audio device. It installs no drivers, so for Zoom or Discord you choose a virtual device such as
BlackHole as the output. Voice Blender mixes two RVC models in a ratio you choose. Training builds an RVC model from
a folder of recordings, with a dataset check, an overtraining warning and resume.

<p align="center">
  <img src="docs/screenshots/convert-dark.png" width="49%" alt="Convert">
  <img src="docs/screenshots/realtime-dark.png" width="49%" alt="Realtime">
</p>
<p align="center">
  <img src="docs/screenshots/training-dark.png" width="49%" alt="Training, dark theme">
  <img src="docs/screenshots/training-light.png" width="49%" alt="Training, light theme">
</p>

### Models, Jobs, API and plugins

The Models page manages OmniVoice, LoRA adapters (also by Hugging Face link) and RVC models, and the model folder can
live on another disk (Settings → Storage). Jobs is the history of everything long the app ran, with progress, log,
stop and run again. The local API (off by default, key in the Keychain) lets scripts on the Mac speak, clone and convert.
Bridge reaches it from a phone through a Cloudflare tunnel, each device approved on the Mac. Plugins run as separate
processes and are off until you switch them on.

<p align="center">
  <img src="docs/screenshots/models-dark.png" width="49%" alt="Models">
  <img src="docs/screenshots/jobs-dark.png" width="49%" alt="Jobs">
</p>
<p align="center">
  <img src="docs/screenshots/api-dark.png" width="49%" alt="Local API and Bridge">
  <img src="docs/screenshots/settings-dark.png" width="49%" alt="Settings">
</p>

### Themes

Eight palettes (Applio, Amethyst, Crimson, Cyberpunk, Emerald, Midnight, Sunset, Halloween), each in light and dark.
Choose one in Settings → Appearance.

<p align="center">
  <img src="docs/screenshots/voices-emerald-dark.png" width="49%" alt="Emerald palette, dark">
  <img src="docs/screenshots/models-emerald-light.png" width="49%" alt="Emerald palette, light">
</p>

## Why it is light

| | Clone'n'Speak | OmniVoice on PyTorch |
|---|---|---|
| Python environment on disk | ~360 MB (MLX, no PyTorch) | ~1.1 GB |
| Voice model | full 16-bit, loaded straight from the download | 3.3 GB fp32 |
| RAM while speaking | ~3 GB peak, Whisper unloaded meanwhile | ~4.2 GB |
| RAM while transcribing | ~1.9 GB (Whisper 16-bit), voice model unloaded meanwhile | +4 GB on top |
| RAM when idle | ~0 — the engine is unloaded after a few idle minutes | stays loaded |
| Speed on M1 | ~real time (10 s of speech ≈ 10 s) | similar |

How: speech recognition and synthesis **take turns** in memory, so an 8 GB Mac with 2–3 GB free runs both at full
quality; text is spoken sentence by sentence, so memory doesn't grow with the text length; MLX's buffer cache is capped.
The app shows the engine's memory and the free memory live, and on Macs with less RAM you can switch to 8-bit.


## Cloning and speech in detail

- **Voice cloning from 3–10 seconds** — pick a file, drop it on the window or record from the microphone.
  - *Sample language*: detected automatically from the recording (or pick it by hand).
  - *Sample check*: loudness, noise, clipping, pauses → a 0–100 score with tips.
  - *Improve sample*: noise reduction, rumble filter, shorter pauses, level normalisation (the original is kept).
  - *Long recordings* are cut to their best ~10 seconds at a pause (the original is kept).
  - *Transcript check*: Whisper listens to the sample and warns when your transcript doesn't match it —
    the most common reason for a bad clone.
  - *Instant preview*: the new voice says a short phrase right after cloning.
- **Accent removal across languages**: record the sample in Russian, speak Ukrainian (or any other pair). A cloned
  voice normally keeps the accent of its sample's language; the app lets the voice say two short phrases in the new
  language three times each, scores the takes by how much they sound like you (a speaker-verification model) and how
  native they sound (Whisper), and uses the two best as the voice's sample for that language from then on.
  [How it was measured ↓](#accent-removal)
- **Pronunciation training** (Speech page, *Train…* next to the voice): teaches a voice clean pronunciation in a
  language — a Russian voice speaking Ukrainian or English, or an English sample read with an accent — round by round,
  showing two numbers for every round: pronunciation (how native Whisper finds it) and likeness to the original sample.
  Every round can be heard and picked by ear. With the optional Seed-VC download (~2.7 GB) the voice learns from a
  native narrator converted to its own timbre, which removes even an accent in the sample's own language.
  [How it works ↓](#pronunciation-training)
- **Voice likeness** after every take: how much the result sounds like the sample, measured by an ECAPA
  speaker-verification model (speechbrain, run on MLX).
- **Voice style** on the Speech page: mood presets (calm, cheerful, energetic, serious, warm, sad, storyteller),
  intonation (flat ↔ lively), energy, pitch, tone (warm ↔ bright), speed, pauses, volume.
  For the model's own voice: gender, age, pitch, whisper and English accents. Sounds between words:
  `[laughter]`, `[sigh]`, surprise, questions.
- **600+ languages**, auto-detected while you type (Apple NaturalLanguage) or picked from the list.
- **✨ Auto-improve**: every phrase is spoken several times and the best take is kept — the one with the fewest
  recognition errors, the most native pronunciation (Whisper's likelihood of the text, which also catches a Russian
  «и» in Ukrainian), the most like the sample and, for Ukrainian, with the most words on their dictionary stress.
- **Stress marks**: select a vowel and press **Stress ´** (⌘') — `виши́вка` — to fix a misplaced stress. The mark
  steers ✨ Auto-improve: of the takes of that phrase, the one that stresses the marked syllable wins. No mark is
  sent to the model: marks in the text make Ukrainian sound Russian ([measured below](#stress)).
- **Sample checks for Ukrainian**: Whisper can't tell accented Ukrainian from Russian, so the app makes both readings;
  Whisper's likelihood of each settles clean speech by itself, and only an accented sample is shown for a choice; an
  accented sample also learns clean pronunciation in its own language (accent removal, once per voice); words of the transcript that aren't in the Ukrainian dictionary (misheard ones) are highlighted;
  Russian letters typed into Ukrainian text (`оксамыт`) are fixed.
- **Ukrainian text preparation**: years (`у 2025 р.` → *у дві тисячі двадцять п'ятому році*), numbers with units in the
  right grammatical form (`21 грн` → *двадцять одна гривня*), abbreviations, apostrophes.
- **LoRA adapters and fine-tunes** from Hugging Face are discovered automatically; the chosen one is downloaded,
  merged and quantized for your Mac. Your own adapter can be added from a folder.
- **Zero setup**: on first launch the app installs its own Python + MLX (~360 MB) and the model (1.6 GB) with
  progress in the window. No Homebrew, no terminal.
- **Shared Hugging Face cache** (`~/.cache/huggingface/hub`, the standard layout used by VoiceStudio and
  `huggingface_hub`): models already downloaded by other apps are reused, including the original `k2-fsa/OmniVoice`.
- Live memory meter: how much the engine uses and how much is still free.
- English and Russian interface, light and dark themes, ~500 KB native binary.

## Tips for a great clone

1. **A sample in the language you will synthesize is still the best start.** For another language *accent removal*
   (on by default, under the sliders button) makes the first phrase take about two minutes longer while the voice
   learns the language. On the Voices page you can listen to what it learned on.
   **Your own accent carries over too**: a clone copies how the sample is spoken, so Ukrainian read with a Russian
   accent stays accented. For the cleanest Ukrainian, record the sample as a native speaker would read it.
2. 5–10 seconds of natural speech from one person, in a quiet room, without music or echo. Aim for a quality score of 80+.
3. **The transcript must match the recording word for word.** Leave it empty to let Whisper fill it in, or let the app
   check it for you.
4. Noisy recording? Press **Improve sample**, then re-clone.
5. For long texts turn on **✨ Auto-improve**; rewrite phrases it reports as unclear (expand abbreviations, add commas).
6. **The mood of a clone comes from its sample**: OmniVoice has no emotion switch. Record the sample the way the result
   should feel, then shape it with the style sliders — they change the melody, pace, pitch and tone, not the acting.
7. Want a different accent or a narrow domain? Train a LoRA adapter on a rented NVIDIA GPU with the
   [official recipe](https://github.com/k2-fsa/OmniVoice/blob/master/docs/lora_finetuning.md) and add the folder in
   *Models → Add your own model or LoRA*. (As of now there are no public Ukrainian OmniVoice adapters; OmniVoice was
   pre-trained on ~1,850 hours of Ukrainian, so a clean Ukrainian sample already gives native pronunciation.)


## Requirements

- Mac with Apple Silicon (M1 or newer), macOS 13 Ventura or later
- 8 GB of memory is enough for the main features: cloning, speech, Audio Tools, music removal
- Pro features (Convert, Realtime, Training, Voice Blender, full stems, plugins) need a Mac with 16 GB of unified memory
- About 3 GB of free disk space for the main engine and model; each pro engine is an extra download of a few GB, with
  the size shown before it starts
- Internet on first launch, for the engine and the model

## Install

Download `CloneNSpeak-vx.y.z.dmg` from [Releases](../../releases), open it and drag the app to *Applications*.

The build is not notarized, so macOS says it “could not verify” the app. Double-click **Allow Clone'n'Speak to open**
in the disk image (it clears the quarantine flag and opens the app), or do the same by hand:

```bash
xattr -dr com.apple.quarantine "/Applications/Clone'n'Speak.app"
open "/Applications/Clone'n'Speak.app"
```

Or: *System Settings → Privacy & Security* → **Open Anyway** (on macOS 15 “right-click → Open” no longer works).
Voices, settings and models from 1.0.x are kept.

## Privacy and offline use

Voices, recordings, models and history stay on this Mac. Nothing is uploaded unless you use a feature marked Online:

| Feature | Goes to | What is sent |
|---|---|---|
| Edge TTS | Microsoft speech servers | the text you want to hear |
| YouTube import | YouTube | the video link you paste |
| Bridge | Cloudflare, through a tunnel | the requests of your devices and the results |
| Model and engine downloads | Hugging Face, GitHub | the names of the files you download |
| Plugin network access | what the plugin asks for | whatever the plugin sends |

The **Data & Privacy** page shows when each of them was last used, where every folder lives, and has a button to reveal
or delete it. **Offline mode** (Settings) refuses all of them, model downloads included, and everything local keeps
working. The local API listens on 127.0.0.1 only and is off by default. Voice conversion, training and separation run
as separate processes; in the 2.0 checks they ran with the network denied. Downloaded engines and weights are pinned to
exact versions and checked by hash.

## Model licenses

The app's own code is MIT. The weights of the models it can download have their own licenses, and the app bundles none
of them. They are fetched on request, and the app marks the ones whose license it could not confirm.

- **Kim_Vocal_2** (vocal separation), **BS-Roformer** (viperx, vocal separation) and the **dereverb** model (anvuew)
  have unverified weight licenses. Their authors state no license for the weights, and the dereverb model was
  fine-tuned from Kim's vocal model, so it carries the same doubt. The app marks all three "license unverified",
  downloads them only when you press the button, and leaves the decision to you. If you plan to use the results
  commercially, check with the rights holders first.
- **htdemucs** (Meta) is under the MIT license of its repository, which gives the weights no separate terms. It is the
  licensed fallback for vocals and stems.
- OmniVoice is Apache-2.0. Other weights keep their authors' licenses.

## Credits

- [OmniVoice](https://github.com/k2-fsa/OmniVoice) by k2-fsa (Apache-2.0): the voice model.
- [MLX](https://github.com/ml-explore/mlx) and [mlx-audio](https://github.com/Blaizzy/mlx-audio): the engine on Apple Silicon.
- [Applio](https://github.com/IAHispano/Applio) by IAHispano (MIT): the RVC engine behind Convert, Realtime and
  Training, fetched from a pinned commit and run as a separate process. The 2.0 interface follows its look.
- [Seed-VC](https://github.com/Plachtaa/seed-vc) by Plachtaa (GPL-3.0): optional download for cloned-voice conversion
  and the native narrator, run as a separate program and not part of the app.
- [audio-separator](https://github.com/nomadkaraoke/python-audio-separator) (MIT),
  [Demucs](https://github.com/facebookresearch/demucs) (MIT), the
  [Ultimate Vocal Remover](https://github.com/Anjok07/ultimatevocalremovergui) model releases and anvuew's dereverb
  model: music removal and stems.
- [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) (MIT or Apache-2.0): noise cleanup.
- [Whisper](https://github.com/openai/whisper) (MIT) on MLX for transcripts and clarity checks, and
  [SpeechBrain](https://github.com/speechbrain/speechbrain) ECAPA (Apache-2.0) for voice likeness.
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense) for YouTube import,
  [edge-tts](https://github.com/rany2/edge-tts) (LGPL-3.0) for Edge TTS and Cloudflare's cloudflared for Bridge, each
  downloaded on request.

## Build from source

Only the Xcode Command Line Tools are needed (`xcode-select --install`). One script compiles with clang in a
temporary folder (nothing is written into the project), signs ad hoc, installs into `/Applications` and opens the app (a running copy is quit first):

```bash
./build.sh          # build, install /Applications/Clone'n'Speak.app and open it (~10 s)
./build.sh --test   # run the Python tests first
./build.sh --zip    # + dist/CloneNSpeak-v<version>.zip for a release
./build.sh --dmg    # + dist/CloneNSpeak-v<version>.dmg (app, Applications link, “Allow Clone'n'Speak to open” script)
INSTALL_DIR=~/Applications ./build.sh   # install somewhere else
```

- Tests: `./build.sh --test`, or `python3 -m unittest discover -s tests` (needs `pip install num2words numpy scipy`;
  `--test` uses the app's own Python runtime when it is installed)
- Translations: `python3 tools/strings.py check`
- Xcode project: `python3 tools/gen_xcodeproj.py`
- Signed & notarized dmg and zip: `SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=notary ./build.sh --dmg --zip`.
- Releasing: bump `CFBundleShortVersionString` in `Sources/Info.plist`, add a `## x.y.z` section to `CHANGELOG.md`
  and push to `main`. GitHub Actions runs the tests, builds the dmg and zip, tags `vx.y.z` and publishes the release with
  that section as its notes (`tools/release_notes.py x.y.z` shows them). Nothing is built or uploaded by hand.

### How it works

```
AppKit UI (Objective-C) ──JSON lines──▶ worker.py (Python, one long-lived process)
  OVRuntime  installs Python + MLX with uv       OmniVoice on MLX (mlx-audio), 4/8/16-bit
  OVModels   Hugging Face cache, catalog, LoRA   Whisper on MLX for transcripts & clarity checks
  OVWorker   requests, progress, idle unload     sample analysis / cleanup, Ukrainian text prep
  OVLocale   UI language, language detection, theme   voice style: melody, pitch, tone, pauses (numpy/scipy)
```

### Voice style

OmniVoice exposes speed, sampling temperature and guidance — and no emotion or intonation control. Measured on the
installed model, guidance and temperature do not move the pitch range at all, so the style sliders work on the
finished take instead:

| Control | What happens |
|---|---|
| Intonation | the pitch melody is narrowed or widened by replaying the take at a gently varying rate (no vocoder) |
| Pitch | the model speaks slower or faster and the take is resampled back: pitch and timbre shift, length stays |
| Tone | tilt EQ: low shelf against high shelf, loudness kept |
| Energy | pace, pauses, melody, presence and a light compressor together |
| Mood | a preset of the above |
| Gender, age, pitch, whisper, accent | OmniVoice voice-design tags; they only affect the model's own voice |

### Accent removal

Cross-lingual cloning keeps the accent of the sample's language: the model continues the way its prompt sounds
(the OmniVoice authors say the same). The app turns the cross-lingual case into a same-language one: the cloned voice
says two phrases in the target language three times each; every take is scored by likeness to the real sample
(ECAPA speaker embeddings) and by Whisper (teacher-forced log-probability of the text, character error rate); the
two best takes together become the prompt for that language (`adapted-<lang>.npz` in the voice's folder, built once).

Measured on a Russian sample speaking five Ukrainian sentences (likeness: ECAPA cosine to the sample, 1 = same
voice, different people ≈ 0.1–0.4):

| Prompt | Whisper errors | Likeness |
|---|---|---|
| original Russian sample | 5.7 % | 0.81 |
| one take, picked by pronunciation only | 5.2 % | 0.78 |
| one take, picked by likeness | 4.1 % | 0.79 |
| **two best takes (current)** | **2.6 %** | 0.78–0.82 |

### Pronunciation training

*Train…* next to the voice on the Speech page re-samples the voice for one language, in up to three rounds. Each round
makes a new sample out of learning phrases and judges it on held-out phrases it never learned on, by two numbers:
**pronunciation** — Whisper's likelihood of the text, scaled so that −0.06 (clean native speech) is 100 % and −0.24
(a strong accent) is 0 %, times one minus twice the error rate — and **likeness**, the ECAPA cosine to the original
sample. The best round becomes `adapted-<lang>.npz`, which speech in that language starts from; every round stays to
be heard and picked by ear.

Where the learning takes come from decides what training can do:

- **its own takes** (ensure_adapted's method, in rounds) work across languages — the 1.0.2 numbers above — but can't
  remove an accent in the sample's own language: an English clone of a Russian-accented sample went from 72 % to
  59 % and 57 % in two rounds;
- **a native narrator** — the model's own voice, or another voice of the user's in that language — read through
  [Seed-VC](https://github.com/Plachtaa/seed-vc), which gives the reading the person's timbre: the voice is re-cloned on
  accent-free speech in its own voice. That is how the accent was taken out of a clone by hand before it became a
  feature. On the same English voice:

| Learns from | Pronunciation | Likeness |
|---|---|---|
| — (original sample) | 72 % | 66 % |
| its own takes, best round | 59 % | 60 % |
| native narrator: the model's own voice → Seed-VC | 87 % | 52 % |
| native narrator: a native speaker's clone → Seed-VC | 89 % | 47 % |

Seed-VC (GPL-3.0) needs PyTorch, so it is not part of the app: the Models page (or the training sheet) downloads it
into `~/Library/Application Support/Clone'n'Speak/accent` — its own Python environment with PyTorch 2.8, the Seed-VC
code at a pinned commit and its models, ~2.7 GB — and the engine runs it as a separate program, only while training.
Chatterbox's converter (MLX, no PyTorch) came out as close by the numbers but garbled a short phrase on every run.

### Stress

OmniVoice was not trained on stress marks. A paired test on a cloned voice (same seed, the combining acute moved
between two syllables of 12 words) shows it follows a mark weakly: the marked syllable comes out stressed 56 % of
the time; upper-case vowels (`вИшивка`) and `+` (`в+ишивка`) do nothing. Worse, a mark in the text pulls the
pronunciation towards Russian — the language whose texts carry stress marks. Measured on four Ukrainian sentences,
two seeds each, with Whisper as the judge (how sure it is the speech is Ukrainian, its error rate, and the
likelihood it gives the text — the closer to 0, the more native the speech sounds):

| Marks in the text | Native Ukrainian clone: P(uk) · errors · likelihood | Russian-accented clone: P(uk) / P(ru) · errors |
|---|---|---|
| none (current) | **0.79 · 1.3 % · −0.17** | 0.61 / 0.21 · 2.1 % |
| only the ten placed by hand | 0.67 · 2.9 % · −0.29 | 0.61 / 0.24 · 1.8 % |
| on every word, from the [lang-uk dictionary](https://github.com/lang-uk/ukrainian-word-stress) | 0.73 · 3.7 % · −0.38 | 0.41 / **0.43** · 4.7 % |

Dictionary marks on every word turned the accented clone's Ukrainian into something Whisper takes for Russian more
often than not — that was release 1.0.1's "stress fight", and it is why no mark reaches the model any more. A
hand-placed mark now works through auto-improve instead: each take of the phrase is judged for stress (vowel length,
loudness and pitch inside Whisper's word timestamps — right 64 % of the time on real speech), a hand-marked word
counting three times a dictionary word, and the judged stress is one of four votes next to recognition errors,
Whisper's likelihood of the text and likeness to the sample.

### Other engines tried

Fish Speech 1.5 Ukrainian (fine-tuned on 240 h of Ukrainian) was compared on the same six sentences and three voices:
likeness to the sample 0.64–0.75 against OmniVoice's 0.80–0.87, Whisper errors about the same, ~4 GB of RAM on
PyTorch and several times slower. Not worth a second engine; OmniVoice stays the only one.

| Where | What |
|---|---|
| `~/.cache/huggingface/hub` | downloaded models (configurable in *Settings → Storage*) |
| `~/Library/Application Support/Clone'n'Speak` | Python engine, optimized models, voices, logs |
| `~/Music/Clone'n'Speak` | generated WAV files |


## License

MIT, see [LICENSE](LICENSE). OmniVoice © k2-fsa (Apache-2.0); model weights keep their authors' licenses (see
[Model licenses](#model-licenses)). Seed-VC © Plachtaa (GPL-3.0) is not included: the optional download fetches it from
its repository. Only clone a voice with the consent of its owner.

---

<a id="русский"></a>

# Clone'n'Speak (по-русски)

Клонирование голоса, озвучка, конвертация голоса и аудио-инструменты для Mac на Apple Silicon. Работает на M1 с 8 ГБ,
а лишнюю память Mac с 16 ГБ отдаёт тяжёлым движкам.

Clone'n'Speak — нативное macOS-приложение (Objective-C / AppKit) для открытой модели
[OmniVoice](https://github.com/k2-fsa/OmniVoice), которая работает на фреймворке Apple [MLX](https://github.com/ml-explore/mlx)
через [mlx-audio](https://github.com/Blaizzy/mlx-audio). Вы записываете 3–10 секунд голоса, вводите текст и получаете
его озвучку этим голосом на 600+ языках; украинскому и русскому уделено особое внимание.

Всё работает локально: без облака, аккаунтов и подписок. Несколько функций выходят в сеть, они помечены «Онлайн»,
спрашивают разрешения и отключаются режимом «Офлайн».

## Что нового в 2.0

- Новое оформление: пронумерованные карточки, 8 палитр в светлой и тёмной теме, боковая панель с группами.
- **Аудио-инструменты**: анализатор, цепочка эффектов, сдвиг формант, очистка DeepFilterNet, конвертация форматов.
- **Разделение**: удаление музыки на любом Mac; полные стемы и удаление реверберации на Mac с 16 ГБ.
- **Озвучка**: форматы WAV, M4A, FLAC, ALAC, MP3, OGG; пресеты; эффекты; плеер с A/B; пакетная озвучка; Edge TTS (онлайн).
- **Голоса**: расширенная проверка образца и улучшение (очистка, удаление музыки).
- **Модели**: LoRA по ссылке Hugging Face, модели RVC, папка моделей на другом диске.
- **Для Mac с 16 ГБ**: Конвертация (RVC, Seed-VC), Реалтайм, Обучение, Смешивание голосов, импорт из YouTube.
- **Задачи** (история долгих операций), локальный **API** и **Bridge** для телефона, **плагины**, страница
  **«Данные и приватность»** и режим **«Офлайн»**.

Подробности — в [CHANGELOG](CHANGELOG.md), скриншоты — в английской части выше.

## Почему лёгкое

| | Clone'n'Speak | OmniVoice на PyTorch |
|---|---|---|
| Python-окружение на диске | ~360 МБ (MLX, без PyTorch) | ~1,1 ГБ |
| Модель голоса | полные 16 бит, грузится прямо из скачанных файлов | 3,3 ГБ fp32 |
| Память при озвучке | пик ~3 ГБ, Whisper в это время выгружен | ~4,2 ГБ |
| Память при распознавании | ~1,9 ГБ (Whisper 16 бит), модель голоса выгружена | ещё +4 ГБ |
| Память в простое | ~0 — движок выгружается через несколько минут | остаётся загруженным |
| Скорость на M1 | ~реальное время (10 с речи ≈ 10 с) | примерно так же |

Распознавание и синтез **загружаются по очереди**, поэтому Mac с 8 ГБ и 2–3 ГБ свободной памяти работает с обеими моделями
в полном качестве; текст озвучивается по фразам, кеш MLX ограничен. Приложение в реальном времени показывает, сколько
занимает движок и сколько памяти свободно; на Mac с меньшим объёмом можно переключиться на 8 бит.

## Возможности

- **Клонирование по 3–10 секундам** — из файла, перетаскиванием или записью с микрофона:
  **язык образца определяется автоматически** (можно выбрать вручную);
  оценка качества образца (шум, громкость, перегруз, паузы) с подсказками; кнопка **«Улучшить образец»**
  (шумоподавление, срез гула, сокращение пауз, выравнивание громкости, оригинал сохраняется);
  длинная запись сама обрезается до лучших ~10 секунд;
  **проверка текста образца** — Whisper слушает запись и предупреждает, если текст не совпадает (главная причина плохого
  клона); **пробная фраза** новым голосом сразу после клонирования.
- **Удаление акцента между языками**: записали образец на русском — озвучиваете украинский (или любую другую пару).
  Обычно клон сохраняет акцент языка образца; приложение один раз даёт голосу произнести две фразы на новом языке
  по три раза, оценивает дубли по похожести на вас (модель верификации диктора) и «родности» произношения (Whisper)
  и дальше использует два лучших как образец для этого языка. Цифры — в разделе [Accent removal](#accent-removal).
- **Обучение произношению** (страница «Озвучка», «Обучить…» рядом с голосом): учит голос чистому произношению на
  языке — русский голос говорит по-украински или по-английски, английский образец записан с акцентом — раунд за раундом,
  с двумя цифрами каждого раунда: произношение (насколько родным его считает Whisper) и похожесть на исходный образец.
  Любой раунд можно послушать и выбрать на слух. С необязательной загрузкой Seed-VC (~2,7 ГБ) голос учится у
  диктора-носителя, переведённого в его тембр, — так уходит даже акцент на языке самого образца. Подробности — в разделе
  [Pronunciation training](#pronunciation-training).
- **Похожесть голоса** после каждой озвучки — насколько результат похож на образец, по модели верификации диктора
  ECAPA (speechbrain, запускается на MLX).
- **Стиль голоса** на странице «Озвучка»: настроение (спокойное, радостное, бодрое, серьёзное, тёплое, грустное,
  рассказчик), интонация (ровная ↔ живая), бодрость, высота, тембр (тёплый ↔ яркий), темп, паузы, громкость.
  Для собственного голоса модели — пол, возраст, высота, шёпот и английские акценты. Звуки между словами:
  `[laughter]`, `[sigh]`, удивление, вопросы.
- **600+ языков** с автоопределением по тексту или выбором из списка.
- **✨ Автоулучшение**: каждая фраза озвучивается несколько раз, и остаётся лучший дубль — с наименьшим числом ошибок
  распознавания, самым «родным» произношением (ловит и русское «и» в украинском), больше всего похожий на образец и,
  для украинского, с ударениями по словарю.
- **Ударения**: выделите гласную и нажмите **«Ударение ´»** (⌘') — `виши́вка`, — чтобы исправить неверное ударение.
  Пометка управляет ✨ автоулучшением: из дублей фразы остаётся тот, где ударение падает на этот слог. В модель
  пометки не передаются — ударения в тексте делают украинскую речь русской по звучанию (замеры — в разделе
  [Stress](#stress)).
- **Проверка образца для украинского**: Whisper не отличает украинский с акцентом от русского — приложение делает
  обе расшифровки, по правдоподобию Whisper само узнаёт чистую русскую или украинскую речь, а в сомнительном случае
  показывает оба варианта и спрашивает; образец с акцентом учится чистому произношению и на своём языке (снятие
  акцента, один раз для голоса); слова расшифровки, которых нет в украинском словаре, подсвечиваются;
  русские буквы в украинском тексте (`оксамыт`) исправляются.
- **Подготовка украинского текста**: годы, числа с единицами в правильной форме, сокращения, апострофы.
- **LoRA-адаптеры и дообученные модели** с Hugging Face находятся сами, выбранные скачиваются, вливаются и
  квантуются под ваш Mac; свой адаптер подключается из папки.
- **Без настройки**: при первом запуске приложение само ставит Python + MLX (~360 МБ) и модель (1,6 ГБ) с прогрессом в окне.
- **Общий кеш Hugging Face** — модели, уже скачанные VoiceStudio и другими программами, используются повторно.
- Английский и русский интерфейс, светлая и тёмная тема.

## Как получить качественный клон

1. **Образец на языке озвучки — по-прежнему лучший старт.** Для другого языка работает «удаление акцента»
   (включено по умолчанию, под кнопкой с ползунками): первая фраза займёт примерно на две минуты больше, пока голос
   учит язык. На странице «Голоса» можно послушать, на чём он учился.
   **Ваш собственный акцент тоже переносится**: клон копирует то, как говорят в образце, поэтому украинский, прочитанный
   с русским акцентом, так и останется с акцентом. Для самого чистого украинского запишите образец так, как его прочитал
   бы носитель языка.
2. 5–10 секунд естественной речи одного человека в тишине, без музыки и эха; оценка качества — от 80.
3. **Текст образца должен совпадать с записью слово в слово** — оставьте поле пустым, и его заполнит Whisper.
4. Шумная запись — нажмите **«Улучшить образец»** и пересоздайте голос.
5. Для длинных текстов включайте **✨ Автоулучшение** и переписывайте фразы, которые оно отметит.
6. **Настроение клона берётся из образца**: у OmniVoice нет переключателя эмоций. Запишите образец так, как должен
   звучать результат, а ползунками стиля подправьте мелодику, темп, высоту и тембр.
7. Нужен особый акцент или тематика — обучите LoRA на арендованной видеокарте NVIDIA по
   [официальному рецепту](https://github.com/k2-fsa/OmniVoice/blob/master/docs/lora_finetuning.md) и подключите папку
   в «Модели». Публичных украинских адаптеров OmniVoice пока нет, но в обучении модели было ~1850 часов украинской речи —
   чистый украинский образец уже даёт естественное произношение.

## Требования и установка

Mac на Apple Silicon (M1 и новее), macOS 13+. Для основных функций хватит 8 ГБ памяти, для функций с бейджем «16 ГБ»
(Конвертация, Реалтайм, Обучение, Смешивание голосов, полные стемы, плагины) нужен Mac с 16 ГБ. ~3 ГБ на диске, интернет
при первом запуске.
Скачайте `CloneNSpeak-vx.y.z.dmg` в [Releases](../../releases) и перетащите приложение в «Программы».

Сборка не нотаризована, поэтому macOS пишет, что «не удалось подтвердить» файл. Дважды щёлкните **Allow Clone'n'Speak to open**
в образе диска (скрипт снимает карантинную пометку и открывает приложение) или сделайте то же вручную:

```bash
xattr -dr com.apple.quarantine "/Applications/Clone'n'Speak.app"
open "/Applications/Clone'n'Speak.app"
```

Или: «Системные настройки» → «Конфиденциальность и безопасность» → **«Всё равно открыть»** (в macOS 15 «правый клик → Открыть» больше не работает).
Сборка из исходников — `./build.sh`: собирает приложение, устанавливает его в `/Applications` и открывает (`--test` — с тестами, `--zip` — ещё и архив в `dist/`, `--dmg` — ещё и образ диска со скриптом снятия карантина).

## Лицензии моделей

Код приложения — MIT. Веса моделей имеют свои лицензии, приложение их не включает: они скачиваются по запросу.
У **Kim_Vocal_2**, **BS-Roformer** и модели удаления реверберации (дообучена из Kim) лицензия весов не подтверждена:
приложение помечает их «license unverified», скачивает только по кнопке, решение за вами; для коммерческого
использования результата уточните права у авторов. **htdemucs** (Meta) — MIT репозитория. Полный список
благодарностей — в английской части выше.

## Лицензия

MIT. OmniVoice © k2-fsa (Apache-2.0). Seed-VC © Plachtaa (GPL-3.0) в приложение не входит: его скачивает
необязательная загрузка. Клонируйте голос только с согласия его владельца.
