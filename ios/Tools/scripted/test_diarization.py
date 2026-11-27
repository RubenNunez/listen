import pathlib
import runpy
import unittest

der = runpy.run_path(str(pathlib.Path(__file__).with_name("diarization.py")))["der"]


class SpeakerScoring(unittest.TestCase):
    def test_renamed_labels_are_equivalent(self):
        ref = [(0, 1, "A"), (1, 2, "B")]
        result = der(ref, [(0, 1, "2"), (1, 2, "1")], 2)
        self.assertAlmostEqual(result["DER"], 0)
        self.assertEqual(result["mapping"], {"1": "B", "2": "A"})

    def test_split_voice_is_penalized_instead_of_mapping_both_labels_to_one_person(self):
        result = der([(0, 4, "A")], [(0, 2, "1"), (2, 4, "2")], 4)
        self.assertAlmostEqual(result["DER"], 0.5)
        self.assertEqual(sum(value == "A" for value in result["mapping"].values()), 1)

    def test_unknown_is_not_dropped_from_scoring(self):
        result = der([(0, 2, "A")], [(0, 2, None)], 2)
        self.assertAlmostEqual(result["DER"], 1)
        self.assertAlmostEqual(result["unknown_label_seconds"], 2)

    def test_overlap_missing_voice_and_false_alarm_are_counted(self):
        result = der([(0, 2, "A"), (1, 2, "B")], [(0, 3, "1")], 3)
        self.assertAlmostEqual(result["reference_speaker_seconds"], 3)
        self.assertAlmostEqual(result["missed_speaker_seconds"], 1)
        self.assertAlmostEqual(result["false_alarm_speaker_seconds"], 1)
        self.assertAlmostEqual(result["DER"], 2 / 3)


if __name__ == "__main__":
    unittest.main()
