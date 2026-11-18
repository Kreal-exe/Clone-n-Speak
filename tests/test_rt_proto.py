"""Tests for Sources/cns_rt_proto.py (pure; no torch)."""
import os
import pathlib
import socket
import stat
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "Sources"))
import cns_rt_proto as p  # noqa: E402


class RtProto(unittest.TestCase):
    def test_frame_roundtrip_with_split_reads(self):
        a, b = socket.socketpair()
        audio = struct.pack("<4f", 0.1, -0.2, 0.3, 0.4)
        wire = p.pack_audio(7, audio) + p.pack_reply(8, 12.5, audio) + p.pack_reply(9, 3.0) + p.pack_ctl(10, {"x": 1})
        dec = p.FrameDecoder()
        got = []
        for i in range(len(wire)):          # one byte at a time
            got += dec.feed(wire[i:i + 1])
        self.assertEqual([(f[0], f[1], f[2]) for f in got], [(1, 7, 4), (2, 8, 4), (2, 9, 0), (3, 10, 7)])
        self.assertEqual(got[0][3], audio)
        ms, samples = p.decode_reply(got[1][3])
        self.assertAlmostEqual(ms, 12.5)
        self.assertEqual(samples, audio)
        self.assertEqual(dec.pending, 0)
        a.sendall(wire[:5])
        d2 = p.FrameDecoder()
        self.assertEqual(p.read_frames(b, d2), [])
        a.sendall(wire[5:])
        frames = []
        while len(frames) < 4:
            frames += p.read_frames(b, d2)
        self.assertEqual(len(frames), 4)
        a.close()
        with self.assertRaises(p.PeerClosed):          # dead peer
            p.read_frames(b, d2)
        b.close()

    def test_oversized_or_bad_magic_closes(self):
        with self.assertRaises(p.FrameError):
            p.FrameDecoder().feed(b"XXXX" + b"\x01" + b"\0" * 8)
        big = p.HEADER.pack(p.MAGIC, p.T_AUDIO, 0, p.MAX_N + 1)
        with self.assertRaises(p.FrameError):
            p.FrameDecoder().feed(big)         # rejected from the header alone, no waiting for 400 KB
        with self.assertRaises(p.FrameError):
            p.FrameDecoder().feed(p.HEADER.pack(p.MAGIC, 9, 0, 1))
        with self.assertRaises(p.FrameError):
            p.FrameDecoder().feed(p.HEADER.pack(p.MAGIC, p.T_CTL, 0, p.MAX_CTL + 1))
        ok = p.FrameDecoder().feed(p.pack_frame(p.T_AUDIO, 0, p.MAX_N, b"\0" * 4 * p.MAX_N))
        self.assertEqual(len(ok), 1)
        a, b = socket.socketpair()
        a.sendall(b"garbage garbage garbage")
        with self.assertRaises(p.FrameError):
            p.read_frames(b, p.FrameDecoder())
        a.close()
        b.close()

    def test_block_frame_rounds_to_480(self):
        self.assertEqual(p.block_frame(0.15), 7200)
        self.assertEqual(p.block_frame(0.25), 12000)
        self.assertEqual(p.block_frame(0.151), 7200)
        self.assertEqual(p.block_frame(0.0), 480)
        self.assertEqual(p.block_frame(10), 96000)
        for s in (0.05, 0.1, 0.173, 0.3, 1.0):
            self.assertEqual(p.block_frame(s) % 480, 0)

    def test_drop_policy_keeps_newest_and_counts(self):
        q = p.DropQueue()
        self.assertEqual(q.push(1, b"a"), [])
        self.assertEqual(q.push(2, b"b"), [])
        self.assertEqual(q.push(3, b"c"), [1])
        self.assertEqual(q.push(4, b"d"), [2])
        self.assertEqual(q.dropped, 2)
        self.assertEqual(q.pop(), (3, b"c"))
        self.assertEqual(q.pop(), (4, b"d"))
        self.assertIsNone(q.pop())

    def test_latency_stats_p50_p95(self):
        s = p.LatencyStats()
        self.assertEqual(s.summary(), {"blocks": 0, "p50_ms": 0.0, "p95_ms": 0.0, "dropped": 0})
        for i in range(1, 101):
            s.add(i)
        s.dropped = 3
        self.assertEqual(s.summary(), {"blocks": 100, "p50_ms": 50.0, "p95_ms": 95.0, "dropped": 3})

    def test_set_command_validates_ranges(self):
        good = {"pitch": 12, "index_rate": 0.5, "protect": 0.33, "silent_threshold": -60}
        self.assertEqual(p.validate_set({"set": good}), good)
        for bad in ({"set": {"pitch": 25}}, {"set": {"index_rate": 1.1}}, {"set": {"protect": 0.6}},
                    {"set": {"silent_threshold": 1}}, {"set": {"volume": 1}}, {"set": {"pitch": "3"}},
                    {"set": {"pitch": True}}, {"set": {"pitch": float("nan")}}, {"set": {}}, {"set": 3}, {}):
            with self.assertRaises(ValueError, msg=str(bad)):
                p.validate_set(bad)
        self.assertEqual(p.parse_control_line('{"set":{"pitch":-3}}'), ("set", {"pitch": -3}))
        for bad in ("nope", "[1]", '{"cmd":"x"}'):
            with self.assertRaises(ValueError):
                p.parse_control_line(bad)

    def test_socket_dir_permissions(self):
        with tempfile.TemporaryDirectory() as t:
            path = os.path.join(t, "rt", "s.sock")
            s = p.listen_unix(path)
            try:
                self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
                c = socket.socket(socket.AF_UNIX)
                c.connect(path)
                c.close()
            finally:
                s.close()
            s = p.listen_unix(path)            # stale file is replaced
            s.close()

    def test_quit_returns_stats_result(self):
        self.assertEqual(p.parse_control_line('{"cmd":"quit"}'), ("quit", None))
        st = p.LatencyStats()
        for v in (50, 60, 70):
            st.add(v)
        st.dropped = 1
        self.assertEqual(p.quit_result(st), {"stats": {"blocks": 3, "p50_ms": 60.0, "p95_ms": 70.0, "dropped": 1}})


try:
    import numpy as np
except ImportError:  # system python may lack numpy
    np = None


class FakeVC:
    def warmup(self, **kw):
        return 1.0

    def on_request(self, block, f0_up_key=0, index_rate=0.3, protect=0.33):
        return block * 0.5, None, (0, 7.0)


def _wait_for(path):
    for _ in range(100):
        if os.path.exists(path):
            return
        time.sleep(0.05)


@unittest.skipIf(np is None, "numpy missing")
class RealtimeProcess(unittest.TestCase):
    def _model(self, t):
        d = os.path.join(t, "m")
        os.makedirs(d)
        open(os.path.join(d, "v.pth"), "wb").close()
        return d

    def _start(self, t, sockp):
        import cns_realtime as rtp
        r, w = os.pipe()
        req = {"model": self._model(t), "socket": sockp, "work_dir": t, "vad": {"on": False}}
        th = threading.Thread(target=rtp.run, args=(req, os.fdopen(r)), kwargs={"loader": lambda s, a, b: FakeVC()})
        th.start()
        _wait_for(sockp)
        return th, w

    def test_serves_one_client_and_returns_stats_on_quit(self):
        import cns_proto
        events = []
        with tempfile.TemporaryDirectory() as t:
            sockp = os.path.join(t, "rt.sock")
            with mock.patch.object(cns_proto, "emit", lambda ev, **kw: events.append((ev, kw))):
                th, w = self._start(t, sockp)
                c = socket.socket(socket.AF_UNIX)
                c.connect(sockp)
                n = p.block_frame(0.15)
                dec = p.FrameDecoder()
                got = []
                for seq in range(3):
                    c.sendall(p.pack_audio(seq, np.ones(n, dtype="<f4")))
                    while len(got) <= seq:
                        got += p.read_frames(c, dec)
                self.assertEqual([g[1] for g in got], [0, 1, 2])
                self.assertEqual(got[0][2], n)
                _, samples = p.decode_reply(got[0][3])
                self.assertAlmostEqual(float(np.frombuffer(samples, "<f4")[0]), 0.5)
                os.write(w, b'{"set":{"pitch":3}}\n{"cmd":"quit"}\n')
                th.join(5)
                c.close()
            os.close(w)
            self.assertFalse(th.is_alive())
            self.assertIn(("status", {"msg": "ready"}), events)
            res = [kw for ev, kw in events if ev == "result"][0]
            self.assertEqual(res["data"]["stats"]["blocks"], 3)
            self.assertFalse(os.path.exists(sockp))

    def test_wrong_block_size_ends_session(self):
        import cns_proto
        with tempfile.TemporaryDirectory() as t:
            sockp = os.path.join(t, "rt.sock")
            with mock.patch.object(cns_proto, "emit", lambda ev, **kw: None):
                th, w = self._start(t, sockp)
                c = socket.socket(socket.AF_UNIX)
                c.connect(sockp)
                c.sendall(p.pack_audio(0, np.zeros(480, dtype="<f4")))
                th.join(5)
                self.assertFalse(th.is_alive())
                c.close()
            os.close(w)

    def test_refuses_without_gpu(self):
        import cns_proto
        import cns_realtime as rtp
        fake = mock.MagicMock()
        fake.backends.mps.is_available.return_value = False
        with mock.patch.dict(sys.modules, {"torch": fake}):
            with self.assertRaises(cns_proto.ProtoError) as cm:
                rtp._load_voice_changer(rtp.settings_from_request({}), "a.pth", None)
        self.assertIn("needs the GPU (MPS)", str(cm.exception))

    def test_settings_defaults_and_missing_model(self):
        import cns_proto
        import cns_realtime as rtp
        s = rtp.settings_from_request({})
        self.assertEqual((s["block_frame"], s["extra_s"], s["crossfade_s"], s["silent_threshold"], s["f0_method"]),
                         (7200, 0.1, 0.03, -60, "rmvpe"))
        with self.assertRaises(cns_proto.ProtoError):
            rtp.find_model_files("/nonexistent")


class RaisingVC(FakeVC):
    def on_request(self, block, **kw):
        raise RuntimeError("boom")


class Pulse:
    """fake VAD: speech where the first sample is >= 0.5"""
    def has_speech(self, block):
        return float(block[0]) >= 0.5


@unittest.skipIf(np is None, "numpy missing")
class RealtimeFixes(unittest.TestCase):
    def _run(self, t, sockp, vc, vad_on=False):
        import cns_realtime as rtp
        d = os.path.join(t, "m")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "v.pth"), "wb").close()
        r, w = os.pipe()
        req = {"model": d, "socket": sockp, "work_dir": t, "vad": {"on": vad_on}}
        out = []

        def go():
            try:
                rtp.run(req, os.fdopen(r), loader=lambda s, a, b: vc)
            except Exception as e:  # noqa: BLE001
                out.append(e)
        th = threading.Thread(target=go)
        th.start()
        _wait_for(sockp)
        return th, w, out

    def _exchange(self, c, dec, seq, val=1.0):
        c.sendall(p.pack_audio(seq, np.full(p.block_frame(0.15), val, dtype="<f4")))
        got = []
        while not got:
            got = p.read_frames(c, dec)
        return got[0]

    def test_idle_gap_keeps_the_session(self):
        import cns_proto
        events = []
        with tempfile.TemporaryDirectory() as t:
            sockp = os.path.join(t, "rt.sock")
            with mock.patch.object(cns_proto, "emit", lambda ev, **kw: events.append((ev, kw))):
                th, w, out = self._run(t, sockp, FakeVC())
                c = p.connect_unix(sockp)
                dec = p.FrameDecoder()
                self._exchange(c, dec, 0)
                time.sleep(2.5)
                self.assertTrue(th.is_alive())
                self.assertEqual(self._exchange(c, dec, 1)[1], 1)
                os.write(w, b'{"cmd":"quit"}\n')
                th.join(5)
                c.close()
            os.close(w)
            self.assertEqual([kw for ev, kw in events if ev == "result"][0]["data"]["stats"]["blocks"], 2)

    def test_model_exception_is_an_error(self):
        import cns_proto
        events = []
        with tempfile.TemporaryDirectory() as t:
            sockp = os.path.join(t, "rt.sock")
            with mock.patch.object(cns_proto, "emit", lambda ev, **kw: events.append((ev, kw))):
                th, w, out = self._run(t, sockp, RaisingVC())
                c = p.connect_unix(sockp)
                c.sendall(p.pack_audio(0, np.ones(p.block_frame(0.15), dtype="<f4")))
                th.join(5)
                c.close()
            os.close(w)
            self.assertFalse(th.is_alive())
            self.assertEqual(len(out), 1)
            self.assertIn("boom", str(out[0]))
            self.assertFalse([1 for ev, _ in events if ev == "result"])

    def test_applio_root_goes_on_path_and_cwd(self):
        import cns_realtime as rtp
        cwd = os.getcwd()
        with tempfile.TemporaryDirectory() as root:
            app = os.path.join(root, "applio")
            os.makedirs(os.path.join(app, "rvc", "realtime"))
            for d in ("rvc", os.path.join("rvc", "realtime")):
                open(os.path.join(app, d, "__init__.py"), "w").close()
            with open(os.path.join(app, "rvc", "realtime", "core.py"), "w") as f:
                f.write("class VoiceChanger:\n    def __init__(self, **kw):\n        self.kw = kw\n")
            fake = mock.MagicMock()
            fake.backends.mps.is_available.return_value = True
            s = rtp.settings_from_request({})
            s["applio_dir"] = app
            try:
                with mock.patch.dict(sys.modules, {"torch": fake}), mock.patch.object(sys, "path", list(sys.path)):
                    vc = rtp._load_voice_changer(s, "a.pth", None)
                    self.assertEqual(vc.kw["device"], "mps")
                    self.assertEqual(os.path.realpath(os.getcwd()), os.path.realpath(app))
            finally:
                os.chdir(cwd)
                for m in [m for m in sys.modules if m == "rvc" or m.startswith("rvc.")]:
                    del sys.modules[m]

    def test_vad_hangover_and_fades(self):
        import cns_realtime as rtp
        g = rtp.Hangover(Pulse(), hang=2)
        loud, quiet = np.ones(10), np.zeros(10)
        self.assertEqual([g.process(b) for b in (loud, quiet, quiet, quiet, quiet, loud, quiet)],
                         [True, True, True, False, False, True, True])
        f = rtp.fade(np.zeros(480), tail=1.0)
        self.assertAlmostEqual(float(f[0]), 1.0)
        self.assertLess(float(f[-1]), 0.01)
        self.assertEqual(float(rtp.fade(np.ones(480), fade_in=True)[0]), 0.0)

    def test_gated_blocks_not_in_latency_stats(self):
        import cns_proto
        import cns_realtime as rtp
        events = []
        with tempfile.TemporaryDirectory() as t:
            sockp = os.path.join(t, "rt.sock")
            with mock.patch.object(cns_proto, "emit", lambda ev, **kw: events.append((ev, kw))), \
                    mock.patch.object(rtp, "VadGate", lambda sens: Pulse()):
                th, w, out = self._run(t, sockp, FakeVC(), vad_on=True)
                c = p.connect_unix(sockp)
                dec = p.FrameDecoder()
                for seq, v in enumerate([1.0] + [0.0] * 5):
                    self._exchange(c, dec, seq, v)
                os.write(w, b'{"cmd":"quit"}\n')
                th.join(5)
                c.close()
            os.close(w)
            st = [kw for ev, kw in events if ev == "result"][0]["data"]["stats"]
            self.assertEqual(st["blocks"], 3)   # loud + 2 hangover; the other 3 were gated

    def test_long_socket_dir(self):
        with tempfile.TemporaryDirectory() as t:
            path = os.path.join(t, "a" * 60, "b" * 60, "s.sock")
            self.assertGreater(len(path.encode()), 104)
            cwd = os.getcwd()
            s = p.listen_unix(path)
            try:
                c = p.connect_unix(path)
                c.close()
            finally:
                s.close()
            self.assertEqual(os.getcwd(), cwd)

    def test_bad_params(self):
        import cns_proto
        import cns_realtime as rtp
        for k, v in (("extra_s", -1), ("crossfade_s", 9), ("block_s", 0)):
            with self.assertRaises(cns_proto.ProtoError):
                rtp.settings_from_request({k: v})


if __name__ == "__main__":
    unittest.main()
