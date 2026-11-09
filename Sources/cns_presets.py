"""Preset validation for Clone'n'Speak 2.0: a preset is a small JSON document (style, export format, effect chain,
formant shift). Parameters are checked against the effect registry (cns_core.EFFECTS) at call time, so a preset
made by another version of the app is clamped, never trusted. Standard library only; Python 3.9 compatible."""
import json
import math

import cns_core as core

PRESET_VERSION = 1
MAX_BYTES = 65536
NAME_MAX = 60
CHAIN_MAX = 32
FORMAT_IDS = ("wav", "m4a", "flac", "alac", "mp3", "ogg")
FORMANT_MIN, FORMANT_MAX = 0.5, 2.0

_NOT_A_PRESET = "This is not a preset file. Choose a preset exported from Clone'n'Speak."
_TOO_LARGE = "This preset is too large (the limit is 64 KB). Choose a preset exported from Clone'n'Speak."


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _clean_param(effect, key, spec, value, warnings):
    label = "%s.%s" % (effect, key)
    if "choices" in spec:
        if value in spec["choices"]:
            return value
        warnings.append("Parameter %s has an unknown value; the default was used." % label)
        return spec["default"]
    if not _is_number(value):
        warnings.append("Parameter %s is not a number; the default was used." % label)
        return spec["default"]
    clamped = min(max(value, spec["min"]), spec["max"])
    if clamped != value:
        warnings.append("Parameter %s was out of range (%s) and was set to %s." % (label, value, clamped))
    return clamped


def _clean_chain(raw, warnings):
    if not isinstance(raw, list):
        warnings.append("The effect chain was not a list and was dropped.")
        return []
    chain = []
    for i, entry in enumerate(raw):
        if len(chain) >= CHAIN_MAX:
            warnings.append("Only the first %d effects are kept." % CHAIN_MAX)
            break
        if not isinstance(entry, dict):
            warnings.append("Effect %d is not an object and was dropped." % (i + 1))
            continue
        kind = entry.get("type")
        info = core.EFFECTS.get(kind) if isinstance(kind, str) else None
        if info is None:
            warnings.append("Effect \"%s\" is not available in this version and was dropped." % (kind,))
            continue
        specs = info["params"]
        params_in = entry.get("params", {})
        if not isinstance(params_in, dict):
            warnings.append("The parameters of effect %s were not an object and were dropped." % kind)
            params_in = {}
        params = {}
        for key in sorted(params_in, key=str):
            if key not in specs:
                warnings.append("Parameter %s.%s is unknown and was dropped." % (kind, key))
                continue
            params[key] = _clean_param(kind, key, specs[key], params_in[key], warnings)
        on = entry.get("on", True)
        if not isinstance(on, bool):
            warnings.append("Effect %s: \"on\" must be true or false; it was set to true." % kind)
            on = True
        chain.append({"type": kind, "on": on, "params": params})
    return chain


def _clean_format(raw, warnings):
    fmt = {"id": "wav", "quality": None}
    if raw is None:
        return fmt
    if not isinstance(raw, dict):
        warnings.append("The export format was not an object; WAV was used.")
        return fmt
    fid = raw.get("id", "wav")
    if isinstance(fid, str) and fid in FORMAT_IDS:
        fmt["id"] = fid
    else:
        warnings.append("Export format \"%s\" is not supported; WAV was used." % (fid,))
    q = raw.get("quality")
    if q is not None:
        if isinstance(q, bool) or not isinstance(q, int) or q < 0 or q > 1000000:
            warnings.append("The export quality was not a valid whole number and was dropped.")
        else:
            fmt["quality"] = q
    return fmt


def validate_preset(data):
    """Returns (normalized preset, warnings). Raises ValueError (message names the action) for a preset that cannot
    be used at all."""
    if not isinstance(data, dict):
        raise ValueError(_NOT_A_PRESET)
    try:
        size = len(json.dumps(data, ensure_ascii=False).encode("utf-8"))
    except (TypeError, ValueError, RecursionError):
        raise ValueError("This preset is damaged. Export it again from Clone'n'Speak.")
    if size > MAX_BYTES:
        raise ValueError(_TOO_LARGE)
    version = data.get("version", PRESET_VERSION)
    if not _is_number(version) or version != int(version) or version < 1:
        raise ValueError("This preset has no valid version. Export it again from Clone'n'Speak.")
    if version > PRESET_VERSION:
        raise ValueError("This preset was made by a newer version of the app.")
    name = data.get("name")
    if not isinstance(name, str) or not name.strip():
        raise ValueError("The preset needs a name. Give it a name of 1 to %d characters." % NAME_MAX)
    name = name.strip()
    if len(name) > NAME_MAX:
        raise ValueError("The preset name is too long. Shorten it to %d characters or fewer." % NAME_MAX)

    warnings = []
    style = {}
    raw_style = data.get("style", {})
    if not isinstance(raw_style, dict):
        warnings.append("The style was not an object and was dropped.")
        raw_style = {}
    for key in sorted(raw_style, key=str):
        v = raw_style[key]
        if isinstance(key, str) and (isinstance(v, str) or _is_number(v)):
            style[key] = v
        else:
            warnings.append("Style value \"%s\" is not a number or text and was dropped." % (key,))
    preset = {"version": PRESET_VERSION, "name": name, "style": style,
              "format": _clean_format(data.get("format"), warnings),
              "chain": _clean_chain(data.get("chain", []), warnings)}
    if "formant" in data:
        f = data["formant"]
        if _is_number(f):
            c = min(max(f, FORMANT_MIN), FORMANT_MAX)
            if c != f:
                warnings.append("The formant shift %s was out of range and was set to %s." % (f, c))
            preset["formant"] = c
        else:
            warnings.append("The formant shift was not a number and was dropped.")
    known = {"version", "name", "style", "format", "chain", "formant"}
    for key in sorted((k for k in data if k not in known), key=str):
        warnings.append("Unknown field \"%s\" was dropped." % (key,))
    return preset, warnings


def export_preset(preset):
    return json.dumps(preset, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def _parse(text):
    if isinstance(text, (bytes, bytearray)):
        if len(text) > MAX_BYTES:
            raise ValueError(_TOO_LARGE)
        try:
            text = bytes(text).decode("utf-8-sig")
        except UnicodeDecodeError:
            raise ValueError(_NOT_A_PRESET)
    if not isinstance(text, str):
        raise ValueError(_NOT_A_PRESET)
    if len(text.encode("utf-8", "surrogatepass")) > MAX_BYTES:
        raise ValueError(_TOO_LARGE)
    try:
        return json.loads(text.lstrip("﻿"))
    except (ValueError, RecursionError):
        raise ValueError(_NOT_A_PRESET)


def cmd_preset_validate(req):
    preset, warnings = validate_preset(_parse(req.get("json")))
    return {"preset": preset, "warnings": warnings}


COMMANDS = {"preset_validate": cmd_preset_validate}
