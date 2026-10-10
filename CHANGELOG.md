# Changelog

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
