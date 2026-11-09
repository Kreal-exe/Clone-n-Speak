"""Tests for Sources/cns_batch.py."""
import os
import pathlib
import sys
import tempfile
import unittest

SOURCES = pathlib.Path(__file__).resolve().parent.parent / "Sources"
sys.path.insert(0, str(SOURCES))

import cns_batch as batch  # noqa: E402
import cns_core as core  # noqa: E402


def texts(items):
    return [i["text"] for i in items]


class BatchTests(unittest.TestCase):
    def test_lines(self):
        items = batch.split_items("a\n\n b \nc", "lines")
        self.assertEqual(texts(items), ["a", "b", "c"])
        self.assertEqual([i["index"] for i in items], [1, 2, 3])

    def test_paragraphs(self):
        items = batch.split_items("one\ntwo\n\nthree", "paragraphs")
        self.assertEqual(texts(items), ["one two", "three"])

    def test_whole(self):
        self.assertEqual(texts(batch.split_items("a\nb\n\nc", "whole")), ["a b c"])

    def test_srt(self):
        srt = ("﻿1\n00:00:01,000 --> 00:00:03,500\nHello\nthere\n\n\n2\n00:00:04,000 --> 00:01:05,250\nBye\n")
        items = batch.split_items(srt, "srt")
        self.assertEqual(texts(items), ["Hello there", "Bye"])
        self.assertEqual((items[0]["start"], items[0]["end"]), (1.0, 3.5))
        self.assertEqual((items[1]["start"], items[1]["end"]), (4.0, 65.25))

    def test_markdown_cleaned(self):
        md = "# Title\n\n- item\n\n**bold** and [link](http://x)\n\n```\ncode here\n```\n\nend"
        items = batch.split_items(md, "lines", ".md")
        self.assertEqual(texts(items), ["Title", "item", "bold and link", "end"])

    def test_output_names(self):
        items = batch.split_items("Hello, world!", "whole")
        self.assertEqual(batch.output_names(items, "wav"), ["001-hello-world.wav"])
        items = batch.split_items("same\nsame", "lines")
        self.assertEqual(batch.output_names(items, ".wav"), ["001-same.wav", "002-same-2.wav"])
        long = batch.split_items("Привет, мир " * 20, "whole")
        self.assertLessEqual(len(long[0]["slug"]), 40)
        self.assertTrue(batch.output_names(long, "m4a")[0].startswith("001-привет-мир"))

    def test_limits(self):
        with self.assertRaises(core.AudioInputError) as c:
            batch.split_items("\n".join("x%d" % i for i in range(501)), "lines")
        self.assertEqual(c.exception.code, "bad_param")
        self.assertIn("Split the file: up to 500 items", c.exception.message)
        self.assertEqual(len(batch.split_items("\n".join("x%d" % i for i in range(500)), "lines")), 500)
        with self.assertRaises(core.AudioInputError) as c:
            batch.split_items("ok\n" + "y" * 8001, "lines")
        self.assertIn("Item 2", c.exception.message)

    def test_encodings(self):
        with tempfile.TemporaryDirectory() as d:
            def run(data):
                p = os.path.join(d, "t.txt")
                with open(p, "wb") as f:
                    f.write(data)
                return batch.COMMANDS["batch_plan"]({"path": p, "mode": "lines"})
            self.assertEqual(texts(run("Привет\nмир".encode("utf-8"))["items"]), ["Привет", "мир"])
            self.assertEqual(texts(run("﻿Привет\nмир".encode("utf-16"))["items"]), ["Привет", "мир"])
            with self.assertRaises(core.AudioInputError) as c:
                run("Привет мир, это тест".encode("cp1251"))
            self.assertIn("Save the file as UTF-8", c.exception.message)

    def test_empty_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "e.txt")
            open(p, "wb").close()
            with self.assertRaises(core.AudioInputError) as c:
                batch.COMMANDS["batch_plan"]({"path": p, "mode": "lines"})
            self.assertEqual(c.exception.code, "empty")
            with self.assertRaises(core.AudioInputError) as c:
                batch.COMMANDS["batch_plan"]({"text": " \n \n", "mode": "lines"})
            self.assertEqual(c.exception.code, "empty")

    def test_utf32_and_errors(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "t.txt")
            with open(p, "wb") as f:
                f.write("Привет\nмир".encode("utf-32"))
            r = batch.COMMANDS["batch_plan"]({"path": p, "mode": "lines"})
            self.assertEqual(texts(r["items"]), ["Привет", "мир"])
            with self.assertRaises(core.AudioInputError):
                batch.COMMANDS["batch_plan"]({"path": d, "mode": "lines"})
            os.chmod(p, 0)
            try:
                with self.assertRaises(core.AudioInputError):
                    batch.COMMANDS["batch_plan"]({"path": p, "mode": "lines"})
            finally:
                os.chmod(p, 0o644)

    def test_missing_inputs(self):
        with self.assertRaises(core.AudioInputError) as c:
            batch.COMMANDS["batch_plan"]({})
        self.assertEqual(c.exception.code, "bad_param")
        self.assertEqual(batch.COMMANDS["batch_plan"]({"text": "a"})["names"], ["001-a.wav"])

    def test_srt_reversed(self):
        with self.assertRaises(core.AudioInputError) as c:
            batch.split_items("1\n00:00:05,000 --> 00:00:03,000\nx\n", "srt")
        self.assertEqual(c.exception.code, "bad_param")

    def test_unsafe_names(self):
        items = batch.split_items("hi", "whole")
        for bad in ("wav/../../../evil", "../x", "toolongext", "w av"):
            with self.assertRaises(core.AudioInputError):
                batch.output_names(items, bad)
            with self.assertRaises(core.AudioInputError):
                batch.COMMANDS["batch_plan"]({"text": "hi", "ext": bad})
        self.assertEqual(batch.output_names(items, None), ["001-hi.wav"])
        evil = [{"index": 1, "slug": "../../x", "text": "t"}]
        self.assertEqual(batch.output_names(evil, "wav"), ["001-x.wav"])

    def test_markdown_is_not_quadratic(self):
        import time
        cases = ["```x\n" * 50000, "*a " * 20000, "_a " * 20000, "![" * 20000, "[a](" * 20000, "**a " * 10000]
        for text in cases:
            t = time.time()
            batch.clean_markdown(text)
            self.assertLess(time.time() - t, 2.0, text[:6])

    def test_plan_from_text(self):
        r = batch.COMMANDS["batch_plan"]({"text": "a\nb", "mode": "lines"})
        self.assertEqual(r["names"], ["001-a.wav", "002-b.wav"])


if __name__ == "__main__":
    unittest.main()
