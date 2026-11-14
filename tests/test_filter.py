"""Tests for the cache-refresh policy in scripts/filter.py."""
import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_filter(cache_dir: Path, ttl: int = 300):
    os.environ["alfred_workflow_cache"] = str(cache_dir)
    os.environ["PP_CACHE_TTL"] = str(ttl)
    spec = importlib.util.spec_from_file_location("pp_filter", HERE.parent / "scripts" / "filter.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CachePolicy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache_dir = Path(self.tmp.name)
        self.mod = load_filter(self.cache_dir)
        self.calls = []
        self.mod.run_indexer = lambda force=False, background=False: self.calls.append(
            {"force": force, "background": background})

    def tearDown(self):
        self.tmp.cleanup()

    def write_cache(self, data: dict, age: float):
        f = self.cache_dir / "index.json"
        f.write_text(json.dumps(data))
        t = time.time() - age
        os.utime(f, (t, t))

    ERROR_ONLY = {"items": [], "errors": ["not logged in (run: pass-cli login)"]}
    WITH_ITEMS = {"items": [{"id": "i", "share_id": "s", "title": "x"}], "errors": []}

    def test_error_only_cache_is_retried_well_before_ttl(self):
        self.write_cache(self.ERROR_ONLY, age=15)
        self.mod.load_cache()
        self.assertEqual(self.calls, [{"force": True, "background": False}])

    def test_error_only_cache_is_not_retried_on_every_keystroke(self):
        self.write_cache(self.ERROR_ONLY, age=2)
        self.mod.load_cache()
        self.assertEqual(self.calls, [])

    def test_fresh_items_are_not_refreshed(self):
        self.write_cache(self.WITH_ITEMS, age=15)
        self.mod.load_cache()
        self.assertEqual(self.calls, [])

    def test_stale_items_refresh_in_background(self):
        self.write_cache(self.WITH_ITEMS, age=301)
        self.mod.load_cache()
        self.assertEqual(self.calls, [{"force": False, "background": True}])

    def test_missing_cache_is_built_synchronously(self):
        self.mod.load_cache()
        self.assertEqual(self.calls, [{"force": True, "background": False}])


class Output(unittest.TestCase):
    ITEMS = [
        {"id": "a", "share_id": "s", "title": "GitHub", "item_type": "login"},
        {"id": "b", "share_id": "s", "title": "Visa", "item_type": "credit-card"},
        {"id": "c", "share_id": "s", "title": "Diary", "item_type": "note"},
        {"id": "d", "share_id": "s", "title": "Old", "item_type": ""},
    ]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache_dir = Path(self.tmp.name)
        self.mod = load_filter(self.cache_dir)
        (self.cache_dir / "index.json").write_text(json.dumps({"items": self.ITEMS, "errors": []}))

    def tearDown(self):
        self.tmp.cleanup()

    def run_filter(self, query=""):
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        sys.argv = ["filter.py", query]
        with redirect_stdout(buf):
            self.mod.main()
        return {i["uid"]: i for i in json.loads(buf.getvalue())["items"]}, json.loads(buf.getvalue())["items"]

    def test_actions_follow_item_type(self):
        by_id, _ = self.run_filter()
        self.assertTrue(by_id["a"]["arg"].startswith("password|"))
        self.assertTrue(by_id["a"]["mods"]["cmd"]["arg"].startswith("username|"))
        self.assertTrue(by_id["b"]["arg"].startswith("card|"))
        self.assertTrue(by_id["b"]["mods"]["cmd"]["arg"].startswith("cvv|"))
        self.assertFalse(by_id["b"]["mods"]["alt"]["valid"])
        self.assertTrue(by_id["c"]["arg"].startswith("details|"))
        self.assertTrue(by_id["d"]["arg"].startswith("password|"))  # untyped: login set

    def test_empty_query_lists_recent_first(self):
        (self.cache_dir / "recent.txt").write_text("c\nb\n")
        _, items = self.run_filter()
        self.assertEqual([i["uid"] for i in items], ["c", "b", "a", "d"])

    def test_just_copied_item_is_pinned_for_a_query(self):
        (self.cache_dir / "recent.txt").write_text("b\n")
        self.mod.RECENT_FILE = self.cache_dir / "recent.txt"
        _, items = self.run_filter("i")  # matches GitHub, Visa, Diary
        self.assertEqual(items[0]["uid"], "b")

    def test_pin_expires(self):
        f = self.cache_dir / "recent.txt"
        f.write_text("b\n")
        t = time.time() - 31
        os.utime(f, (t, t))
        _, items = self.run_filter("git")
        self.assertEqual(items[0]["uid"], "a")


if __name__ == "__main__":
    unittest.main()
