"""YouTube audio import (Clone'n'Speak 2.0, pro env): one video's audio as a WAV, through yt-dlp.

Runs inside the pro environment (yt-dlp is installed there). The user's request is one JSON line on stdin:
    {"url", "consent": true, "dest_dir", "max_minutes": 20, "work_dir", "outputs_dir"}
Only single-video links on youtube.com / music.youtube.com / youtu.be are accepted; everything else is refused before
any process starts. yt-dlp runs from an argv list (never a shell) with --ignore-config, --no-playlist, --no-exec, no
cookies and no plugin folders, in its own process group. Python 3.9+; nothing heavy is imported.
"""
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cns_net  # noqa: E402
import cns_proto  # noqa: E402

PATH = "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
CONSENT_MESSAGE = "Confirm that you have the rights to this recording and the speaker’s consent"
FFMPEG_MESSAGE = "Install ffmpeg first (brew install ffmpeg)"
URL_MESSAGE = ("Paste the link to one YouTube video (youtube.com/watch?v=…, /shorts/…, or youtu.be/…). "
               "Playlists and channels are not supported.")
INFO_TIMEOUT = 90
DOWNLOAD_TIMEOUT = 1800
MAX_FILESIZE = "1G"
MAX_BYTES = 1 << 30
DEFAULT_MINUTES = 20
MAX_MINUTES = 240
TITLE_LIMIT = 120
_HOSTS = ("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com")
_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")


class YtError(RuntimeError):
    pass


def parse_url(url):
    """Returns (video_id, canonical_url) for one video, or raises YtError. list=/index=/t= and the rest are dropped."""
    if not isinstance(url, str) or not url.strip() or len(url) > 400:
        raise YtError(URL_MESSAGE)
    try:
        u = urllib.parse.urlsplit(url.strip())
        host = u.hostname
        port = u.port
    except ValueError:
        raise YtError(URL_MESSAGE)
    if u.scheme != "https" or u.username is not None or u.password is not None or port not in (None, 443):
        raise YtError(URL_MESSAGE)
    if host in _HOSTS and u.path == "/watch":
        vals = urllib.parse.parse_qs(u.query).get("v", [])
        vid = vals[0] if len(vals) == 1 else ""
        site = "music.youtube.com" if host == "music.youtube.com" else "www.youtube.com"
    elif host in _HOSTS and re.fullmatch(r"/(?:shorts|live|embed)/[^/]+/?", u.path or ""):
        vid = u.path.strip("/").split("/")[1]
        site = "www.youtube.com"
    elif host == "youtu.be" and re.fullmatch(r"/[^/]+/?", u.path or ""):
        vid = u.path.strip("/")
        site = "www.youtube.com"
    else:
        raise YtError(URL_MESSAGE)
    if not _ID.match(vid):
        raise YtError(URL_MESSAGE)
    return vid, "https://%s/watch?v=%s" % (site, vid)


def find_ffmpeg():
    return shutil.which("ffmpeg", path=PATH)


def _env(work_dir):
    env = {"PYTHONSAFEPATH": "1", "PATH": PATH, "HOME": os.environ.get("HOME", os.path.expanduser("~")),
           "LANG": os.environ.get("LANG", "en_US.UTF-8"), "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"}
    if work_dir:
        env["TMPDIR"] = work_dir
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy",
              "no_proxy", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def _run(argv, timeout, env, cwd=None):
    """Runs argv (a list, no shell) in its own process group; on timeout the whole group is killed."""
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
                         cwd=cwd, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except BaseException:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            p.kill()
        try:
            p.communicate(timeout=5)
        except (subprocess.TimeoutExpired, OSError, ValueError):
            pass
        raise
    return subprocess.CompletedProcess(argv, p.returncode, out, err)


def _base(ffmpeg):
    return [sys.executable, "-s", "-P", "-m", "yt_dlp", "--ignore-config", "--no-plugin-dirs", "--no-playlist", "--no-exec",
            "--no-warnings", "--ffmpeg-location", os.path.dirname(ffmpeg)]


def info_argv(url, ffmpeg):
    return _base(ffmpeg) + ["--dump-single-json", "--", url]


def download_argv(url, vid, dest_dir, ffmpeg, max_minutes=DEFAULT_MINUTES):
    return _base(ffmpeg) + ["--match-filter", "duration<=%d & !is_live" % (max_minutes * 60), "-x", "--audio-format", "wav", "--max-filesize", MAX_FILESIZE, "--no-part",
                            "-o", os.path.join(dest_dir.replace("%", "%%"), "yt-%s.%%(ext)s" % vid), "--", url]


def _tail(text):
    lines = [l for l in (text or "").strip().splitlines() if l.strip()]
    return (lines[-1] if lines else "")[:200]


def _clean_title(t):
    return re.sub(r"[\x00-\x1f\x7f]+", " ", str(t or "")).strip()[:TITLE_LIMIT]


def check_info(info, max_minutes):
    if not isinstance(info, dict) or info.get("_type") in ("playlist", "multi_video"):
        raise YtError(URL_MESSAGE)
    if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming", "post_live"):
        raise YtError("Live streams can't be imported. Try again after the stream has ended.")
    dur = info.get("duration")
    if not isinstance(dur, (int, float)) or isinstance(dur, bool) or dur <= 0:
        raise YtError("Couldn't read the length of this video.")
    if dur > max_minutes * 60:
        raise YtError("Too long: %d min, limit %d min" % (int(round(dur / 60.0)), max_minutes))
    return float(dur)


def _cleanup(dest, vid):
    for f in glob.glob(os.path.join(glob.escape(dest), "yt-%s.*" % vid)):
        try:
            os.unlink(f)
        except OSError:
            pass


def fetch(req, run=None):
    run = run or _run
    cns_net.require_online("youtube")
    if req.get("consent") is not True:
        raise YtError(CONSENT_MESSAGE)
    vid, url = parse_url(req.get("url"))
    try:
        max_minutes = int(req.get("max_minutes", DEFAULT_MINUTES))
    except (TypeError, ValueError):
        raise YtError("Bad length limit.")
    max_minutes = max(1, min(MAX_MINUTES, max_minutes))
    roots = [r for r in (req.get("outputs_dir"), req.get("work_dir")) if r]
    dest = cns_proto.safe_output_dir(req.get("dest_dir") or req.get("outputs_dir") or "", roots)
    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        raise YtError(FFMPEG_MESSAGE)
    os.makedirs(dest, exist_ok=True)
    work = req.get("work_dir")
    if not work or not os.path.isdir(work):
        raise YtError("No work folder given.")
    env = _env(work)
    cns_proto.status("Reading video information…")
    try:
        r = run(info_argv(url, ffmpeg), INFO_TIMEOUT, env, work)
    except subprocess.TimeoutExpired:
        raise YtError("YouTube did not answer in time. Check the network and try again.")
    except OSError as e:
        raise YtError("Could not start yt-dlp (%s). Install the pro engines first." % e)
    if r.returncode != 0:
        raise YtError("YouTube refused or the video is unavailable: %s" % (_tail(r.stderr) or "unknown error"))
    try:
        info = json.loads(r.stdout)
    except ValueError:
        raise YtError("yt-dlp returned an unreadable answer. Update yt-dlp in Models and try again.")
    dur = check_info(info, max_minutes)
    out = os.path.join(dest, "yt-%s.wav" % vid)
    _cleanup(dest, vid)
    cns_proto.progress(0.1)
    cns_proto.status("Downloading audio…")
    try:
        r = run(download_argv(url, vid, dest, ffmpeg, max_minutes), DOWNLOAD_TIMEOUT, env, work)
    except subprocess.TimeoutExpired:
        _cleanup(dest, vid)
        raise YtError("The download took too long. Check the network and try again.")
    if r.returncode == 0 and os.path.isfile(out) and not os.path.islink(out) and os.path.getsize(out) > MAX_BYTES:
        _cleanup(dest, vid)
        raise YtError("The audio is too large (over %d GB). Pick a shorter video." % (MAX_BYTES >> 30))
    if r.returncode != 0 or not os.path.isfile(out) or os.path.islink(out):
        _cleanup(dest, vid)
        raise YtError("Download failed: %s" % (_tail(r.stderr) or "no audio was produced"))
    return {"outputs": [out], "title": _clean_title(info.get("title")), "duration": dur, "video_id": vid}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    cns_proto.install_stdout_guard()
    try:
        cns_net.require_online("youtube")
        if argv[:1] != ["fetch"]:
            raise YtError("Usage: cns_ytdl.py fetch")
        cns_proto.result(**fetch(cns_proto.read_request()))
        return 0
    except (YtError, cns_proto.ProtoError, cns_net.OfflineError) as e:
        cns_proto.fail(str(e))
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
