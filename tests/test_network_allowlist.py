"""Every file that talks to the network is listed here on purpose.

Adding a file to ALLOWED means: the feature goes through OVNetwork (ObjC) or cns_net.require_online (Python)
unless it is an explicit user-started model download, AND it is described in OVPrivacyCatalog.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
MARKERS = re.compile(r"NSURLSession|NSURLConnection|urllib\.request|http\.client|requests\.|hf_hub_download|"
                     r"snapshot_download|cloudflared|yt_dlp|edge_tts")

# file -> why it may touch the network.
# Adding a file, add it to OVPrivacyCatalog too.
ALLOWED = {
    "OVDownloader.m": "explicit model downloads (Hugging Face), started by the user",
    "OVModels.m": "model catalog and explicit downloads (Hugging Face)",
    "OVRuntime.m": "Setup: uv installs the runtime",
    "worker.py": "setup, explicit model downloads, Seed-VC download, ECAPA fetch (skipped offline)",
    "OVNetwork.m": "the gate itself",
    "cns_net.py": "the gate for Python processes",
    "OVBridge.m": "Bridge (8.7)",
    # Landing in parallel; those tasks add their own entries at merge:
    # 6.8 deep-filter download, 6.10 onnxruntime/model download, Edge TTS, YouTube, plugins.
}


class Allowlist(unittest.TestCase):
    def test_new_network_code_goes_through_gate(self):
        offenders = {}
        sources = list((ROOT / "Sources").glob("*.m")) + list((ROOT / "Sources").glob("*.py"))
        for path in sorted(sources):
            if path.name in ALLOWED:
                continue
            for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                if MARKERS.search(line):
                    offenders.setdefault(path.name, []).append(n)
        self.assertFalse(offenders, "network code outside the allowlist (route it through OVNetwork / cns_net "
                                    "and add the file to ALLOWED and OVPrivacyCatalog): %r" % offenders)

    def test_offline_env_is_passed_to_worker(self):
        src = (ROOT / "Sources" / "OVWorker.m").read_text()
        self.assertIn("OV_OFFLINE", src)
        self.assertIn("HF_HUB_OFFLINE", src)

    def test_worker_does_not_download_ecapa_offline(self):
        src = (ROOT / "Sources" / "worker.py").read_text()
        self.assertIn("local_files_only", src)


if __name__ == "__main__":
    unittest.main()
