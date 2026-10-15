"""Offline unit checks for the preflight adapter and bounded polling program."""
import importlib.util
from pathlib import Path
import types
import unittest


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / "tools" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check = load("check_oracle")
watch = load("watch_price")


class ToolTests(unittest.TestCase):
    def test_preflight_sends_only_schema_supported_draft_fields(self):
        body = {"question": "price?", "chainId": 1, "answerType": "uint256", "evidence": "panel",
                "panelSize": 30, "toleranceBps": 500, "definitions": {"unit": "USD"},
                "guards": {"minSources": 1}, "v": 1, "quorum": 21, "window": {"hours": 24},
                "consumer": {"chainId": 11155111, "verifyingContract": "from-deployed-contract"}}
        result = check.draft(body)
        self.assertEqual(result["action"], "oracle.request")
        self.assertEqual(set(result["input"]), set(check.DRAFT_KEYS))
        self.assertEqual(result["input"]["consumer"], body["consumer"])
        self.assertIn("definitions", body)  # Exact on-chain body isn't modified.

    def test_poller_retries_then_finishes(self):
        clock = [0.0]
        calls = []
        def run(command, **kwargs):
            calls.append(command)
            return types.SimpleNamespace(returncode=0 if len(calls) == 3 else 1, stdout="(1000000,1,2)")
        result = watch.wait_for_price("rpc", "oracle", "class", .01, 1, run=run,
                                      monotonic=lambda: clock[0], sleep=lambda s: clock.__setitem__(0, clock[0]+s))
        self.assertEqual(result, "(1000000,1,2)")
        self.assertEqual(len(calls), 3)
        self.assertAlmostEqual(clock[0], .02)
        self.assertTrue(all(c[1] == "call" for c in calls))

    def test_poller_has_a_finite_timeout(self):
        clock = [0.0]
        def run(*args, **kwargs):
            return types.SimpleNamespace(returncode=1, stdout="")
        with self.assertRaises(TimeoutError):
            watch.wait_for_price("rpc", "oracle", "class", .01, .025, run=run,
                                 monotonic=lambda: clock[0], sleep=lambda s: clock.__setitem__(0, clock[0]+s))
        self.assertEqual(clock[0], .025)

    def test_poller_rejects_nonpositive_intervals(self):
        with self.assertRaises(ValueError):
            watch.wait_for_price("rpc", "oracle", "class", 0, 1)


if __name__ == "__main__":
    unittest.main()
