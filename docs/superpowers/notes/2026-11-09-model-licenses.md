# Model weight licenses for music removal / stems (Task 6.9)

Checked 2026-11-09, web only via hermes-browser. Nothing was posted or sent to anyone.
Scope: `Kim_Vocal_2.onnx` (MDX-Net, KimberleyJensen / UVR), BS-Roformer ep317 (viperx), fallback Demucs-ONNX.

## Verdicts

| Model | Verdict | Catalog 6.10 |
|---|---|---|
| `Kim_Vocal_2.onnx` | **not verified** | do not include |
| BS-Roformer `model_bs_roformer_ep_317_sdr_12.9755.ckpt` (viperx) | **not verified** | do not include (sub-plan C: same answer) |
| `nsosu/demucs-onnx` | **rejected**: it is not Demucs, it is Open-Unmix UMX-L, weights non-commercial | do not include |
| htdemucs (facebookresearch/demucs) | MIT stated for the repository, weights not separately declared: **partially verified** | candidate, needs an ONNX export and a user decision (see below) |

## Kim_Vocal_2: evidence

1. Original host `TRvlvr/model_repo` (https://github.com/TRvlvr/model_repo): no LICENSE file, README is empty ("model_repo"), only `README.rd` and `update_patches.txt`. Models are release assets. No license statement.
2. Open issue #2 "Query regarding commercial use" (https://github.com/TRvlvr/model_repo/issues/2): asks whether the models may be used commercially. Zero replies from maintainers.
3. Open issue #3 (https://github.com/TRvlvr/model_repo/issues/3): a developer wrote "I could not find a weight-specific redistribution license." Zero replies.
4. UVR project (https://github.com/Anjok07/ultimatevocalremovergui), README License section: "The Ultimate Vocal Remover GUI code is MIT-licensed." That is a code license. The next line asks third-party developers to "honor the MIT license by providing credit to UVR" for "our models", which is ambiguous, and the README credits KimberleyJSN only as having "Advised and aided" the training scripts. The README also says "UVR's core developers trained all of the models provided", which does not match Kim_Vocal_2 being KimberleyJensen's work. No LICENSE file at `master/LICENSE` (404). Not a clear grant from the weight author.
5. Author's own pages: GitHub https://github.com/KimberleyJensen has `kmdx-net_music-source-separation` (no LICENSE file in the file list, one commit) and `Mel-Band-Roformer-Vocal-Model` (a different model). Her Hugging Face https://huggingface.co/KimberleyJSN lists one model, `melbandroformer`, tagged `license:mit`. Kim_Vocal_2 is not published there and carries no statement from her. I did not find a Discord or other announcement through the browser.
6. Third-party re-uploads, which conflict with each other and are not statements by the author:
   - https://huggingface.co/diarizeapp/uvr-kim-vocal-2: tag `license:apache-2.0`; card says only "maintained by the diarizeapp ecosystem", no provenance of the license.
   - https://huggingface.co/Acapellas/Kim_Vocal_2.onnx: tag `license:mit`, but the README is a pasted card of an unrelated model (StableAvatar), so the tag is meaningless.
   - https://huggingface.co/thepatch/mdx-net-kim-vocal-2-GGUF: `license:other`.
   - https://huggingface.co/mlx-community/mel-roformer-kim-vocal-2-mlx: `license:mit` (a Mel-Roformer, not this file); Intel's OpenVINO port of her Mel-Roformer is tagged `license:gpl-3.0`.
   Four different tags for the same lineage show that the tags are guesses.

Verdict by the task criteria: the license is not confirmed by the author and the author has not explicitly permitted redistribution or commercial use. Only re-uploaders tagged it. **Not verified, `KIM_VOCAL_2` does not go into the 6.10 catalog.**

## BS-Roformer viperx: evidence (for sub-plan C)

- Same host, same absence of license (point 1 above).
- Issue #3 above is exactly this checkpoint (sha256 `5b84f37e...efae115aa`), asking for written permission and "If MIT or Apache-2.0 already applies to these exact weights, please point us to the original declaration." Open, no answer. Issue #2 also asks about the commercial use of this checkpoint.
- ZFTurbo MSST pretrained list (https://github.com/ZFTurbo/Music-Source-Separation-Training/blob/main/docs/pretrained_models.md) lists "BS Roformer (viperx edition)" with a download link and SDR, with no license statement for it. The MSST code is MIT; that does not cover the weights.
- I found no viperx repo or Hugging Face page with a license.

Verdict: **not verified**, same as Kim_Vocal_2. Sub-plan C must not ship these weights as a bundled or default catalog entry without a permission from the author or a user decision.

## Fallback: `nsosu/demucs-onnx` is not usable

- https://huggingface.co/nsosu/demucs-onnx has the tag `license:mit`, but its README title is "Open-Unmix UMX-L" and the files are `umxl_vocals/drums/bass/other.onnx`. It is not Demucs.
- Upstream Open-Unmix (https://github.com/sigsep/open-unmix-pytorch) README: "the weights are only licensed for non-commercial use (CC BY-NC-SA 4.0)." The code is MIT, the umxl weights are not. The MIT tag on the ONNX re-upload is wrong. **Rejected**; I did not download or benchmark it.
- Other HF "demucs-onnx" repos carry inconsistent tags (mit, apache-2.0, cc-by-nc-4.0, creativeml-openrail-m), so a tag on a re-upload cannot be trusted either.

## Real Demucs (htdemucs)

- https://github.com/facebookresearch/demucs (archived 2025-01-01): "Demucs is released under the MIT license as found in the LICENSE file." That covers the repository by its owner (Meta); the pretrained weights are not given a separate license text. Best available basis, but weaker than an explicit weight statement.
- No ONNX export was chosen or downloaded, so the 30 s measurements (time, peak memory, speech SI-SDR >= 15 dB) and the ONNX input/output names were **not done**. An export from the official weights is something we would produce ourselves, and a ready-made third-party export would need its own provenance check.

## Decision needed from the user

Neither music-removal weights file can be shipped on a verified license. Options:
1. Use htdemucs under the repository's MIT (need to export or find an ONNX we can trust, then measure). Recommended; the license basis is the owner's own repository.
2. Allow Kim_Vocal_2 / BS-Roformer with the unconfirmed license (re-upload tags only, risk stated above). Only the user can decide this.
3. Ask the rights holders (KimberleyJensen via KimberleyJensenOx1@gmail.com listed in her README; viperx / @playdasegunda via issue #3). Not done, as instructed.
