"""Edge text-to-speech (Clone'n'Speak 2.0, edge env): the online Microsoft voices through edge-tts (LGPL, own process).

    cns_edge.py synth   {"text", "voice", "rate", "pitch", "volume", "out_name", "work_dir", "outputs_dir"}
    cns_edge.py voices  {"root": <engines folder>}   (cache <root>/edge/voices.json, 7 days)
Both commands call cns_net.require_online("edge_tts") first: nothing leaves the Mac in Offline mode. The text is sent to
Microsoft's service. synth writes an mp3 into work_dir and converts it with afconvert to a 24 kHz mono 16-bit WAV in
outputs_dir. Python 3.9+; edge_tts is imported only inside the functions.
"""
import asyncio
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cns_net  # noqa: E402
import cns_proto  # noqa: E402

MAX_CHARS = 20000
VOICES_TTL = 7 * 24 * 3600
AFCONVERT = "/usr/bin/afconvert"
SYNTH_TIMEOUT = 600
_VOICE = re.compile(r"^[A-Za-z0-9-]{3,80}$")
_RATE = re.compile(r"^[+-]\d{1,3}%$")
_PITCH = re.compile(r"^[+-]\d{1,3}Hz$")
_FIELDS = ("ShortName", "Locale", "Gender", "FriendlyName")


class EdgeError(RuntimeError):
    pass


def _import_edge():
    try:
        import edge_tts
    except ImportError:
        raise EdgeError("Edge text-to-speech is not installed. Install it in Models, then try again.")
    return edge_tts


def _check(value, pattern, default, what):
    value = default if value in (None, "") else str(value)
    if not pattern.match(value):
        raise EdgeError("Bad %s setting: %s" % (what, value))
    return value


def _out_name(name):
    base = re.sub(r"[^A-Za-z0-9._-]+", "-", os.path.basename(str(name or "")).rsplit(".", 1)[0]).strip("-.")[:60]
    return "edge-%s.wav" % (base or "speech")


def synth(req):
    cns_net.require_online("edge_tts")
    text = str(req.get("text") or "").strip()
    if not text:
        raise EdgeError("Type some text first.")
    if len(text) > MAX_CHARS:
        raise EdgeError("Text is too long: %d characters, limit %d." % (len(text), MAX_CHARS))
    voice = str(req.get("voice") or "")
    if not _VOICE.match(voice):
        raise EdgeError("Pick an Edge voice first.")
    rate = _check(req.get("rate"), _RATE, "+0%", "speed")
    volume = _check(req.get("volume"), _RATE, "+0%", "volume")
    pitch = _check(req.get("pitch"), _PITCH, "+0Hz", "pitch")
    outputs_dir = req.get("outputs_dir")
    work_dir = req.get("work_dir")
    if not outputs_dir or not work_dir:
        raise EdgeError("No output folder given.")
    os.makedirs(outputs_dir, exist_ok=True)
    os.makedirs(work_dir, exist_ok=True)
    edge_tts = _import_edge()
    mp3 = os.path.join(work_dir, "edge.mp3")
    cns_proto.status("Asking the Edge voice…")
    try:
        asyncio.run(edge_tts.Communicate(text, voice, rate=rate, pitch=pitch, volume=volume).save(mp3))
    except Exception as e:
        raise EdgeError("Edge text-to-speech failed (%s). Check the network and try again." % (str(e)[:150] or type(e).__name__))
    if not os.path.isfile(mp3) or os.path.getsize(mp3) == 0:
        raise EdgeError("Edge returned no audio for this text and voice.")
    cns_proto.progress(0.7)
    out = os.path.join(outputs_dir, _out_name(req.get("out_name")))
    try:
        r = subprocess.run([AFCONVERT, "-f", "WAVE", "-d", "LEI16@24000", "-c", "1", mp3, out], capture_output=True,
                           text=True, timeout=SYNTH_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise EdgeError("Could not convert the audio to WAV (%s)." % e)
    if r.returncode != 0 or not os.path.isfile(out):
        raise EdgeError("Could not convert the audio to WAV: %s" % ((r.stderr or "").strip()[-150:] or "afconvert failed"))
    try:
        os.remove(mp3)
    except OSError:
        pass
    return {"outputs": [out], "voice": voice}


def _cache_path(req):
    root = req.get("root") or os.environ.get("CNS_ENGINES_ROOT")
    if not root:
        raise EdgeError("No engines folder given.")
    return os.path.join(root, "edge", "voices.json")


def _read_cache(path, now):
    try:
        with open(path) as f:
            data = json.load(f)
        voices = data["voices"]
        if isinstance(voices, list) and now - float(data["fetched"]) < VOICES_TTL and \
                now >= float(data["fetched"]) - 60 and all(isinstance(v, dict) for v in voices):
            return voices
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def voices(req, now=None):
    cns_net.require_online("edge_tts")
    now = time.time() if now is None else now
    path = _cache_path(req)
    cached = _read_cache(path, now)
    if cached is not None:
        return {"voices": cached, "cached": True}
    edge_tts = _import_edge()
    cns_proto.status("Loading the Edge voice list…")
    try:
        raw = asyncio.run(edge_tts.list_voices())
    except Exception as e:
        raise EdgeError("Could not load the Edge voice list (%s). Check the network and try again." % (str(e)[:150] or type(e).__name__))
    items = [{k: v.get(k, "") for k in _FIELDS} for v in raw if isinstance(v, dict) and v.get("ShortName")]
    if not items:
        raise EdgeError("Edge returned an empty voice list.")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"fetched": now, "voices": items}, f)
    os.replace(tmp, path)
    return {"voices": items, "cached": False}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    cns_proto.install_stdout_guard()
    try:
        cns_net.require_online("edge_tts")
        if argv[:1] == ["synth"]:
            cns_proto.result(**synth(cns_proto.read_request()))
        elif argv[:1] == ["voices"]:
            cns_proto.result(**voices(cns_proto.read_request()))
        else:
            raise EdgeError("Usage: cns_edge.py synth|voices")
        return 0
    except (EdgeError, cns_proto.ProtoError, cns_net.OfflineError) as e:
        cns_proto.fail(str(e))
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
