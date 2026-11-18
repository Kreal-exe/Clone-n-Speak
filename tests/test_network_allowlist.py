"""Every place that can touch the network is listed here on purpose.

EXPECTED maps a source file to the number of lines in it that mention a network marker. A file may gain or lose
such lines only together with a change here, which makes the author look at the gate: the feature must go through
OVNetwork (ObjC) or cns_net.require_online (Python) unless it is an explicit, user-started model download.
Adding a file to EXPECTED means describing it in OVPrivacyCatalog too.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
SUFFIXES = {".m", ".mm", ".h", ".py"}
MARKERS = re.compile(
    r"\bsocket\b|urlopen|from urllib|import urllib|urllib\.request|\brequests\b|http\.client|\bssl\b|\b(?:curl|wget)\b|"
    r"yt[-_]dlp|edge[-_]tts|huggingface_hub|hf_hub_download|snapshot_download|from_pretrained|"
    r"NSURLSession|NSURLRequest|NSURLConnection|dataWithContentsOfURL|nw_connection|NSStream|WKWebView|cloudflared")

# file -> (number of marker lines, why it may touch the network)
EXPECTED = {
    "OVDownloader.m": (13, "explicit model downloads (Hugging Face), started by the user"),
    "OVModels.h": (2, "mentions of NSURLSession in the download API"),
    "OVModels.m": (0, "catalog and downloads go through OVDownloader; no direct calls"),
    "OVRuntime.m": (0, "Setup (uv) goes through OVDownloader / uv; no direct calls"),
    "OVNetwork.h": (1, "the gate"),
    "OVNetwork.m": (1, "the gate"),
    "cns_net.py": (3, "the gate for Python processes"),
    "worker.py": (4, "ECAPA fetch (cached only offline), Seed-VC download (explicit_download)"),
    "cns_separate.py": (8, "music-removal model download, started by the user (pinned HTTPS URL + sha256, https-only redirects)"),
    "cns_dfn.py": (4, "DeepFilterNet binary download, started by the user (pinned URL + sha256)"),
    "OVAPIPage.m": (3, "the Quick start text shows shell commands for the local API (127.0.0.1); the page makes no network call"),
    "cns_engines.py": (22, "pro-engine installs, started by the user: pinned HTTPS URLs (GitHub, Hugging Face) + sha256, "
                           "https-only redirects, uv/PyPI through the installer; also names edge-tts and yt-dlp as packages"),
    "cns_rvc.py": (1, "user-started voice-model download (fetch): https links only, cns_engines.download does the transfer; "
                     "urllib.parse is imported only to split and normalise the link"),
    "cns_realtime.py": (9, "realtime voice process: one local Unix-socket client (AF_UNIX, no internet); sandboxed without network"),
    "cns_rt_proto.py": (12, "realtime block protocol over a local Unix socket (AF_UNIX); no internet"),
    "OVRealtimeIO.h": (5, "realtime audio client: talks to the local voice process over its AF_UNIX socket (no internet)"),
    "OVRealtimeIO.m": (2, "the same: send/recv on the AF_UNIX socket of the realtime process, SO_NOSIGPIPE"),
    "OVRealtimePage.m": (1, "a comment: the session's socket lives in the job folder; the page makes no network call"),
    "cns_ytdl.py": (7, "YouTube audio import, started by the user: one https youtube.com / youtu.be video through yt-dlp, "
                       "after cns_net.require_online(\"youtube\") and the rights confirmation; no cookies, no plugins"),
    "cns_edge.py": (12, "Edge TTS: sends the typed text to Microsoft's online voices (edge-tts, own process), "
                        "after cns_net.require_online(\"edge_tts\")"),
    "cns_pins.py": (7, "generated pins: the requirement lines that name requests / edge-tts packages (no network code)"),
    "OVEngines.h": (2, "pro-engine manager API: names yt-dlp, and the local Unix-socket connect helper of the realtime engine"),
    "OVEngines.m": (5, "pro-engine manager: runs cns_engines.py and the pro job processes (the network kinds ask OVNetwork first); "
                       "the AF_UNIX connect to the realtime process; kind names edge_tts / yt_import"),
    "OVProKit.m": (2, "pro-run preflight asks OVNetwork before Edge / YouTube jobs; the yt-dlp update title"),
    "OVPrivacyCatalog.m": (3, "descriptions only: feature ids and the word \"requests\" in the Bridge text"),
    "OVBridge.m": (5, "Bridge: after OVNetwork consent / Offline check and an explicit Start, downloads the tunnel program through "
                      "OVDownloader from the one pinned GitHub release address (sha256 of archive and binary, codesign and TeamIdentifier "
                      "checked before chmod +x), runs it with a clean environment, and stops it on Stop / quit / Offline / key change; "
                      "the markers are the program's name and path"),
    "OVBridge.h": (1, "Bridge's interface: one comment naming the tunnel program; no network code"),
    "OVYouTubeSheet.h": (1, "names yt-dlp in the API comment; the download runs through OVProRun (yt_import kind)"),
    "OVYouTubeSheet.m": (9, "YouTube import sheet: link check and yt-dlp version text; the download itself is the yt_import job (cns_ytdl.py)"),
    "cns_api.py": (6, "local API / Bridge listeners on 127.0.0.1, server side only (no outgoing calls); it also owns the Bridge "
                      "tunnel program (the file name and path markers) so the tunnel ends with the server, only after OVBridge "
                      "verified it and only when the app sends tunnel_start"),
}

# Files other tasks add (6.8 deep-filter download, 6.10 onnxruntime/model download, Edge TTS, YouTube,
# plugins). They are not in this branch yet: if one appears without a line in EXPECTED, the test names it.
FORWARD = set()


def marker_counts():
    counts = {}
    for path in sorted(SOURCES.rglob("*")):
        if path.suffix not in SUFFIXES or path.name.startswith("._"):
            continue
        n = sum(1 for line in path.read_text(errors="replace").splitlines() if MARKERS.search(line))
        if n:
            counts[path.name] = n
    return counts


def code_lines(name):
    return [l for l in (SOURCES / name).read_text().splitlines() if not l.strip().startswith(("//", "#", "/*", "*"))]


class Allowlist(unittest.TestCase):
    def test_new_network_code_goes_through_gate(self):
        found = marker_counts()
        problems = []
        for name, n in found.items():
            if name not in EXPECTED:
                problems.append("%s has %d network marker line(s) and is not in EXPECTED%s" % (
                    name, n, " (forward file: add it with its count)" if name in FORWARD else ""))
            elif EXPECTED[name][0] != n:
                problems.append("%s: expected %d marker line(s), found %d" % (name, EXPECTED[name][0], n))
        for name, (n, _) in EXPECTED.items():
            if n and name not in found:
                problems.append("%s expects %d marker line(s) but has none" % (name, n))
        self.assertFalse(problems, "network code changed; route it through OVNetwork / cns_net, then update EXPECTED "
                                   "and OVPrivacyCatalog:\n" + "\n".join(problems))

    def test_allowlisted_files_exist(self):
        names = {p.name for p in SOURCES.rglob("*") if p.suffix in SUFFIXES}
        self.assertFalse(set(EXPECTED) - names, "listed but missing")

    def test_offline_env_is_passed_to_worker(self):
        code = "\n".join(code_lines("OVWorker.m"))
        self.assertRegex(code, r'env\[@"OV_OFFLINE"\]\s*=')
        self.assertRegex(code, r'env\[@"HF_HUB_OFFLINE"\]\s*=')

    def test_worker_does_not_download_ecapa_offline(self):
        code = "\n".join(code_lines("worker.py"))
        self.assertRegex(code, r"hf_hub_download\([^)]*local_files_only=")

    def test_explicit_download_clears_offline_env(self):
        import os
        import sys
        sys.path.insert(0, str(SOURCES))
        import importlib
        import io
        keep = sys.stdout
        try:
            worker = importlib.import_module("worker")
        finally:
            sys.stdout = keep
        os.environ["OV_OFFLINE"] = os.environ["HF_HUB_OFFLINE"] = "1"
        try:
            with worker.explicit_download({"explicit_download": True}):
                self.assertNotIn("OV_OFFLINE", os.environ)
                self.assertNotIn("HF_HUB_OFFLINE", os.environ)
            self.assertEqual(os.environ["OV_OFFLINE"], "1")
            self.assertEqual(os.environ["HF_HUB_OFFLINE"], "1")
            with worker.explicit_download({}):   # not user-started: stays offline
                self.assertEqual(os.environ["HF_HUB_OFFLINE"], "1")
        finally:
            os.environ.pop("OV_OFFLINE", None)
            os.environ.pop("HF_HUB_OFFLINE", None)

    def test_accent_install_is_explicit(self):
        src = "\n".join(code_lines("OVNativeAccent.m"))
        self.assertIn('@"explicit_download": @YES', src)
        self.assertIn("with explicit_download(req)", "\n".join(code_lines("worker.py")))


if __name__ == "__main__":
    unittest.main()
