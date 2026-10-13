"""Behavior regressions for the verification tools themselves."""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_tool(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AlignmentTests(unittest.TestCase):
    def test_no_required_fixtures_cannot_claim_alignment(self):
        import json
        import contextlib
        import io
        tool = load_tool("alignment", ROOT / "tools/verify_preset_live_alignment.py")
        with tempfile.TemporaryDirectory() as tmp:
            tool.REPO_ROOT = Path(tmp)
            tool.RESOURCES = Path(tmp)
            tool.WORK = Path(tmp)
            tool.CATALOG = Path(tmp) / "catalog.json"
            tool.CATALOG.write_text(json.dumps([{"file": "performance_probe", "durationMs": 1000}]))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(tool.main(), 1)
            self.assertNotIn("All transcodes are sample-aligned", output.getvalue())

    def test_short_identical_tracks_have_zero_lag(self):
        tool = load_tool("alignment", ROOT / "tools/verify_preset_live_alignment.py")
        samples = tool.np.random.default_rng(42).normal(size=12000)
        lag, peak = tool.measure_lag(samples, samples, 1000, max_lag=500)
        self.assertEqual(lag, 0)
        self.assertAlmostEqual(peak, 1)

    def test_short_shifted_track_reports_positive_delay(self):
        tool = load_tool("alignment", ROOT / "tools/verify_preset_live_alignment.py")
        samples = tool.np.random.default_rng(42).normal(size=12000)
        delayed = tool.np.concatenate((tool.np.zeros(37), samples[:-37]))
        lag, peak = tool.measure_lag(samples, delayed, 1000, max_lag=500)
        self.assertEqual(lag, 37)
        self.assertAlmostEqual(peak, 1)


class VerificationGateTests(unittest.TestCase):
    def judge(self, summary, status=0):
        # Source the real gate functions without running the expensive lanes.
        source = (ROOT / "tools/verify_ios.sh").read_text().split('for lane in "${lanes[@]}"; do')[0]
        source += "\nROOT=" + str(ROOT) + "\n"
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "tests.log"
            log.write_text(summary)
            script = Path(tmp) / "gate.sh"
            script.write_text(source + '\njudge_tests fixture "$1" "$2"\n'
                              + '[ ${#failed[@]} -eq 0 ]\n')
            return subprocess.run(["bash", str(script), str(log), str(status)],
                                  env={"RINA_VERIFY_DIR": tmp}, capture_output=True).returncode

    def test_all_skips_fail(self):
        self.assertNotEqual(self.judge("Executed 1 test, with 1 test skipped and 0 failures\n"), 0)

    def test_some_executed_bodies_pass(self):
        self.assertEqual(self.judge("Executed 2 tests, with 1 test skipped and 0 failures\n"), 0)

    def test_swift_testing_summary_passes(self):
        self.assertEqual(self.judge("✔ Test run with 69 tests in 13 suites passed after 0.1 seconds.\n"), 0)

    def test_swift_testing_all_disabled_fails(self):
        self.assertNotEqual(self.judge("↷ Test disabledBody() skipped.\n✔ Test run with 1 test in 0 suites passed after 0.1 seconds.\n"), 0)

    def test_mixed_xctest_zero_and_swift_testing_bodies_pass(self):
        self.assertEqual(self.judge("Executed 0 tests, with 0 failures\n✔ Test run with 2 tests passed after 0.1 seconds.\n"), 0)

    def test_swift_testing_failed_summary_fails(self):
        self.assertNotEqual(self.judge("Executed 2 tests, with 0 failures\n✘ Test run with 1 test failed after 0.1 seconds.\n"), 0)

    def test_xctest_skip_lines_are_not_counted_as_swift_skips(self):
        tool = load_tool("ios_counts", ROOT / "tools/ios_test_counts.py")
        text = ("Test Case '-[Case skipped]' skipped (0.0 seconds).\n"
                "Executed 2 tests, with 1 test skipped and 0 failures\n"
                "✔ Test run with 0 tests passed after 0.1 seconds.\n")
        self.assertEqual(tool.counts(text), (2, 1, 0))

    def test_failed_process_fails_even_with_passing_summary(self):
        self.assertNotEqual(self.judge("Executed 2 tests, with 0 failures\n", 1), 0)


class EmulatorTests(unittest.TestCase):
    def test_board_identities_have_independent_mutable_state(self):
        tool = load_tool("emulator", ROOT / "tools/rinalink_board_emulator.py")
        tool.IDENT.id = "127.0.0.1"
        tool.handle_cmd({"cmd": "set_brightness", "raw": 12})
        tool.IDENT.id = "192.0.2.1"
        self.assertEqual(tool.status()["renderer"]["brightness"], 80)
        tool.handle_cmd({"cmd": "set_color", "hex": "#ffffff"})
        tool.IDENT.id = "127.0.0.1"
        self.assertEqual(tool.status()["renderer"]["brightness"], 12)
        self.assertEqual(tool.status()["renderer"]["color"], "#ec3fc7")

    def test_concurrent_frames_are_written_atomically(self):
        import threading
        import time
        tool = load_tool("emulator", ROOT / "tools/rinalink_board_emulator.py")
        class Socket:
            output = bytearray()
            def getsockname(self):
                return ("127.0.0.1", 5370)
            def sendall(self, payload):
                for byte in payload:
                    self.output.append(byte)
                    time.sleep(0.00001)
        socket = Socket()
        client = tool.Client(socket)
        first, second = b"A" * 20, b"B" * 20
        threads = [threading.Thread(target=client.send, args=(payload,)) for payload in (first, second)]
        for thread in threads: thread.start()
        for thread in threads: thread.join()
        self.assertIn(bytes(socket.output), (first + second, second + first))


class SoakParserTests(unittest.TestCase):
    def test_complete_status_is_not_recounted_during_idle_reads(self):
        tool = load_tool("soak", ROOT / "docs/stress-20260912-211559/tools/device/soak_guard.py")
        parser = tool.TelemetryParser()
        block = ("STATUS frameEncoding=bitset frameBytes=47 lit=1 queued=2 accepted=3\n"
                 "STATUS ledBackend=rmt dma=1 ledReady=1 refreshUs=1 refreshMaxUs=2 refreshFail=0\n"
                 "STATUS heapFree=100 largestBlock=90\n")
        self.assertEqual(parser.feed(block), [("status", ("1", "2", "3", "1", "1", "2", "0", "100", "90"))])
        self.assertEqual(parser.feed(""), [])
        self.assertEqual(parser.feed("unrelated line\n"), [])
        self.assertEqual(len(parser.feed(block)), 1)

    def test_split_status_waits_for_complete_last_line(self):
        tool = load_tool("soak", ROOT / "docs/stress-20260912-211559/tools/device/soak_guard.py")
        parser = tool.TelemetryParser()
        self.assertEqual(parser.feed("STATUS frameEncoding=bitset frameBytes=47 lit=1 queued=2 accepted=3\n"), [])
        self.assertEqual(parser.feed("STATUS ledBackend=rmt dma=1 ledReady=1 refreshUs=1 refreshMaxUs=2 refreshFail=0\n"), [])
        self.assertEqual(parser.feed("STATUS heapFree=100 largestBlock=9"), [])
        events = parser.feed("0\n")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0][1][-1], "90")


class RoutingDeliveryTests(unittest.TestCase):
    def test_positive_contract_detects_missing_delivery_and_confirms_state(self):
        import sys
        directory = ROOT / "docs/stress-dual-run1/tools"
        sys.path.insert(0, str(directory))
        try:
            tool = load_tool("oracle", directory / "oracle.py")
        finally:
            sys.path.pop(0)
        step = {"ts_start": 1, "ts_end": 2, "expected_boards_set": {"A"},
                "expected_commands": "set_brightness", "expected_state": '{"brightness":12}'}
        before = {"host_ts": 0, "fields": {"brightness": "80", "accepted": "0"}}
        after = {"host_ts": 3, "fields": {"brightness": "80", "accepted": "0"}}
        boards = {"A": ([before, after], [], set())}
        self.assertEqual(tool.evaluate([step], boards)[0][0]["verdict"], "DELIVERY_FAIL")
        event = {"category": "PROTO", "event": "command", "ts": 1.5, "fields": "name=set_brightness"}
        after["fields"]["brightness"] = "12"
        boards["A"] = ([before, after], [event], set())
        self.assertEqual(tool.evaluate([step], boards)[0][0]["verdict"], "PASS")
        step.pop("expected_commands")
        step.pop("expected_state")
        self.assertEqual(tool.evaluate([step], boards)[0][0]["delivery"], "NOT_CHECKED")
        self.assertEqual(tool.evaluate([step], boards, require_delivery=True)[0][0]["verdict"], "DELIVERY_UNKNOWN")


if __name__ == "__main__":
    unittest.main()
