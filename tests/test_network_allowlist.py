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
    "OVPrivacyCatalog.m": (3, "descriptions only: feature ids and the word \"requests\" in the Bridge text"),
    "cns_api.py": (4, "local API / Bridge listeners on 127.0.0.1, server side only (no outgoing calls)"),
}

# Files other tasks add (6.8 deep-filter download, 6.10 onnxruntime/model download, Bridge 8.7, Edge TTS, YouTube,
# plugins). They are not in this branch yet: if one appears without a line in EXPECTED, the test names it.
FORWARD = {"OVBridge.m", "OVBridge.h"}


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
