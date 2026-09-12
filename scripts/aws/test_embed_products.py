"""Offline contract tests for embed_products.py; no DB, network, or model load."""

import importlib.util
import sys
import types
import unittest
from pathlib import Path


def load_script():
    for name in ("httpx", "open_clip", "torch", "supabase"):
        sys.modules.setdefault(name, types.ModuleType(name))
    sys.modules["supabase"].create_client = lambda *_args, **_kwargs: None
    pil = sys.modules.setdefault("PIL", types.ModuleType("PIL"))
    pil.Image = object
    path = Path(__file__).with_name("embed_products.py")
    spec = importlib.util.spec_from_file_location("embed_products_under_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


class WriteResultTests(unittest.TestCase):
    def test_partial_rpc_response_is_not_counted_as_success(self):
        module = load_script()
        batch = [{"id": "1"}, {"id": "2"}, {"id": "3"}, {"id": "4"}]
        response = [
            {"id": "1", "outcome": "applied"},
            {"id": "2", "outcome": "stale"},
            {"id": "3", "outcome": "missing"},
        ]

        self.assertEqual(
            module.classify_write_results(batch, response),
            {"applied": 1, "stale": 1, "missing": 1, "failed": 1},
        )

    def test_non_list_rpc_response_fails_every_requested_item(self):
        module = load_script()
        self.assertEqual(
            module.classify_write_results([{"id": "9007199254740993"}], None),
            {"applied": 0, "stale": 0, "missing": 0, "failed": 1},
        )


if __name__ == "__main__":
    unittest.main()
