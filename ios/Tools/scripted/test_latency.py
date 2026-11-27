"""Regression checks for measured latency and missing-response denominators."""
import array
import json
import pathlib
import runpy
import tempfile
import unittest
import wave

latency = runpy.run_path(str(pathlib.Path(__file__).with_name("latency.py")))


class LatencyMeasurement(unittest.TestCase):
    def test_clock_does_not_assume_zero_recognition_delay(self):
        events = [
            {"kind": "sentence", "id": 1, "end_ms": 1000, "t": 3.0},
            {"kind": "layer", "name": "1 · Apple", "sentence": 1, "seconds": 1.8, "t": 3.0},
            {"kind": "sentence", "id": 1, "end_ms": 1000, "t": 9.0},
        ]
        offset, _ = latency["audio_clock"](events)
        self.assertAlmostEqual(offset, 0.2)

    def test_clock_is_not_invented_without_trace(self):
        with self.assertRaises(ValueError):
            latency["audio_clock"]([{"kind": "sentence", "id": 1, "end_ms": 1000, "t": 3.0}])

    def test_empty_card_and_title_do_not_count_as_answer_and_miss_is_kept(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder)
            script = path / "probe.txt"
            script.write_text("A: First question?\n--\nB: Second question?\n")
            samples = array.array("h", [0] * 80000)
            for start, end in [(16000, 22400), (48000, 54400)]:
                samples[start:end] = array.array("h", [1000] * (end - start))
            with wave.open(str(path / "audio.wav"), "wb") as sound:
                sound.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                sound.writeframes(samples.tobytes())
            events = [
                {"kind": "sentence", "id": 1, "text": "First question?", "end_ms": 1400, "t": 2.0},
                {"kind": "layer", "name": "1 · Apple", "sentence": 1, "seconds": 0.5, "t": 2.0},
                {"kind": "card_started", "card": 1, "sentence": 1, "layer": "fast", "t": 3.0},
                {"kind": "card_text", "card": 1, "text": "Title\n", "t": 3.2},
                {"kind": "card_text", "card": 1, "text": "First answer", "t": 3.7},
            ]
            (path / "events.jsonl").write_text("\n".join(json.dumps(event) for event in events))
            rows = latency["measure"](script, path)["questions"]
            self.assertEqual(len(rows), 2)
            self.assertAlmostEqual(rows[0]["first_content_seconds"], 1.7)
            self.assertAlmostEqual(rows[0]["first_answer_seconds"], 2.2)
            self.assertIsNone(rows[1]["first_answer_seconds"])
            self.assertEqual(rows[1]["recognised"], [])
            script.write_text("A: Only one question?\n")
            with self.assertRaisesRegex(ValueError, "alignment is ambiguous"):
                latency["measure"](script, path)


if __name__ == "__main__":
    unittest.main()
