"""Network gate for Python processes (plugins, Edge TTS, yt-dlp). OVNetwork (ObjC) sets OV_OFFLINE in the environment."""
import os

# Same identifiers as OVNetwork identifierFor:.
FEATURES = ("edge_tts", "youtube", "bridge", "model_download", "plugin_network")


class OfflineError(RuntimeError):
    pass


def is_offline(env=None):
    env = os.environ if env is None else env
    return str(env.get("OV_OFFLINE", "")).strip().lower() in ("1", "true")


_NAMES = {"edge_tts": "Edge TTS", "youtube": "YouTube import", "bridge": "Bridge",
          "model_download": "model downloads", "plugin_network": "plugin network access"}


def require_online(feature, env=None):
    """Raises OfflineError (with what to do) when Offline mode is on. Every feature is blocked, model downloads included."""
    if feature not in FEATURES:
        raise ValueError("unknown network feature: %r" % (feature,))
    if is_offline(env):
        raise OfflineError("Offline mode is on. Turn it off in Settings to use %s." % _NAMES[feature])
