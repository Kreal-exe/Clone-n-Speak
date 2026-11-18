import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "Sources"))
import cns_net  # noqa: E402


class Net(unittest.TestCase):
    def test_is_offline_reads_env(self):
        self.assertTrue(cns_net.is_offline({"OV_OFFLINE": "1"}))
        self.assertTrue(cns_net.is_offline({"OV_OFFLINE": "true"}))
        self.assertTrue(cns_net.is_offline({"OV_OFFLINE": "TRUE"}))
        self.assertFalse(cns_net.is_offline({"OV_OFFLINE": "0"}))
        self.assertFalse(cns_net.is_offline({"OV_OFFLINE": ""}))
        self.assertFalse(cns_net.is_offline({}))

    def test_require_online_passes_when_online(self):
        cns_net.require_online("edge_tts", {})

    def test_require_online_raises_with_action_text(self):
        with self.assertRaises(cns_net.OfflineError) as cm:
            cns_net.require_online("edge_tts", {"OV_OFFLINE": "1"})
        self.assertIn("Settings", str(cm.exception))
        self.assertIn("Offline mode is on", str(cm.exception))

    def test_model_download_is_blocked_offline(self):
        with self.assertRaises(cns_net.OfflineError):
            cns_net.require_online("model_download", {"OV_OFFLINE": "1"})
        cns_net.require_online("model_download", {})

    def test_unknown_feature_rejected(self):
        with self.assertRaises(ValueError):
            cns_net.require_online("telemetry", {})

    def test_features_match_objc_identifiers(self):
        src = (pathlib.Path(__file__).resolve().parent.parent / "Sources" / "OVNetwork.m").read_text()
        for f in cns_net.FEATURES:
            self.assertIn('@"%s"' % f, src)


if __name__ == "__main__":
    unittest.main()
