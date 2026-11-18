# Blending two cloned OmniVoice voices (task 7.12 experiment)

Date: 2026-11-18. Script: `tools/spikes/omni_blend.py`. Verdict: **no card for now (not proven; end-to-end not measured here)**.

## Method

OmniVoice clones from a prompt, and two prompts cannot be averaged. The idea: speak the phrase with OmniVoice in voice A,
then pass it through Seed-VC with a *reference mix* as `target`: a sample made of alternating 2 s chunks of A's and B's
samples in the proportion `ratio` (share of A; up to 25 s, 20 ms fades, chunks wrap around each sample). Seed-VC takes the
timbre from the reference as a whole, so the result should slide from B (ratio 0) to A (ratio 1).

Plan criteria for go: (1) ECAPA likeness (`worker.likeness`) to A rises and to B falls as the share of A grows (tolerance
0.02), and at 0.5 both are at least 0.35 x the likeness of the voice to itself; (2) Whisper CER not worse than the
baseline by more than 3 points; (3) a human listens: middle points sound like one person, without "two voices" or artefacts.
Pairs m/m, f/f, m/f; ratios 0, .25, .5, .75, 1; phrases in en and uk.

## What was measured here

Stage 1 only (`omni_blend.py reference`, main runtime python): the ECAPA likeness of the **reference mix itself** to A and
B, which is the necessary condition (Seed-VC cannot be closer to B than its reference is). Voice samples were three pairs
from this Mac's own voice library (two m/m pairs, one m/f; no second female voice was available, so f/f was not run).

| pair | ratio (share of A) 0 / .25 / .5 / .75 / 1: likeness to A | likeness to B | voice to itself | A to B |
|---|---|---|---|---|
| m/m | .15 .45 .73 .94 .99 | .99 .90 .69 .34 .16 | .67 | .16 |
| m/m (2) | .19 .44 .72 .93 1.0 | .99 .93 .73 .41 .19 | .78 | .19 |
| m/f | .17 .27 .64 .91 .99 | .99 .95 .45 .30 .18 | .67 | .18 |

Criterion (1) holds on the reference: monotone within 0.02 and 0.45 to 0.73 at 0.5, far above 0.35 x 0.67.
**This is weak evidence.** The mix is made of the very recordings it is compared to, so a high ECAPA score is expected, and
ECAPA averages over the sample: the middle point is a *two-voice alternation* that the embedding places half way, not a
single person. Whether Seed-VC turns that reference into one intermediate voice, or into a wobbling one, is exactly
criterion (3) and cannot be seen from the reference.

## Not measured here

- OmniVoice weights are not installed on this Mac (no `k2-fsa/OmniVoice` or `mlx-community/OmniVoice-bf16` in the Hugging
  Face cache), so the phrases spoken in voice A do not exist. `omni_blend.py full --sources <dir>` expects
  `<pair>-en.wav` and `<pair>-uk.wav` made by the app and then runs Seed-VC for each ratio and measures the likeness.
- Seed-VC end to end (stage 2 and 3), Whisper CER (criterion 2, the `full` report leaves `cer_ok` true by default: it is not
  evidence), and listening (criterion 3): **not measured**. No numbers are given for them.

## Verdict for the main session

Not go: the card "Blend two cloned voices (experimental)" is not built, as the spec allows ("only if it sounds right"). The
reference-level check passes, which makes the idea worth the remaining hour: install OmniVoice, speak the two test phrases
in voice A for each pair, run `full`, add Whisper CER, and listen to the 0.5 point of each pair. If it sounds like one
person, the card goes on the Voice Blender page as `OVBadge("Experimental")` running the `pro_convert` kind with
`engine: seedvc` and the reference mix as `target`; the mixing function in `omni_blend.py` (`mix_reference`) is small
enough to port to the app. If it sounds like two people trading lines, the voice-A-only path stays.
