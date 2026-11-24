import json
import os
import subprocess
import sys
import tempfile
import pathlib
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "write_proposals.py")
GOOD = {"kind": "edit", "target": "orchestrate", "slug": "capped-pytest", "confidence": "high",
        "sources": ["abc123:live"], "title": "Brief the Check as pytest -q", "body": "Line one.\nLine two."}


class WriteProposals(unittest.TestCase):
    def run_w(self, out, proposals):
        data = proposals if isinstance(proposals, str) else json.dumps({"proposals": proposals})
        return subprocess.run([sys.executable, "-I", SCRIPT, "--out", out], input=data,
                              capture_output=True, text=True)

    def test_writes_file_with_frontmatter(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_w(d, [GOOD])
            self.assertEqual(r.returncode, 0, r.stderr)
            text = pathlib.Path(r.stdout.strip()).read_text()
            self.assertTrue(text.startswith("---\nkind: edit\ntarget: \"orchestrate\"\nconfidence: high\nsources:\n  - \"abc123:live\"\ngenerated: "))
            self.assertIn("---\n# Brief the Check as pytest -q\n\nLine one.\nLine two.\n", text)

    def test_new_kind_needs_no_target(self):
        with tempfile.TemporaryDirectory() as d:
            p = {k: v for k, v in GOOD.items() if k != "target"} | {"kind": "new"}
            self.assertEqual(self.run_w(d, [p]).returncode, 0)

    def test_bad_input_exits_90_and_writes_nothing(self):
        bad = [
            {**GOOD, "kind": "delete"},
            {k: v for k, v in GOOD.items() if k != "target"},  # edit without target
            {**GOOD, "sources": []},
            {**GOOD, "slug": "Bad Slug"},
            {**GOOD, "confidence": "certain"},
            {**GOOD, "title": ""},
        ]
        for p in bad:
            with self.subTest(p=p), tempfile.TemporaryDirectory() as d:
                # a valid proposal alongside a bad one must not be written either
                r = self.run_w(d, [{**GOOD, "slug": "ok"}, p])
                self.assertEqual(r.returncode, 90, r.stderr)
                self.assertEqual(os.listdir(d), [])
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.run_w(d, "not json").returncode, 90)
            self.assertEqual(self.run_w(d, "{}").returncode, 90)

    def test_never_overwrites(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.run_w(d, [GOOD]).returncode, 0)
            path = os.path.join(d, os.listdir(d)[0])
            before = pathlib.Path(path).read_text()
            r = self.run_w(d, [{**GOOD, "body": "different"}])
            self.assertEqual(r.returncode, 90)
            self.assertEqual(pathlib.Path(path).read_text(), before)
            self.assertEqual(self.run_w(d, [GOOD, GOOD]).returncode, 90)  # duplicate in one batch


if __name__ == "__main__":
    unittest.main()
