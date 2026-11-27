#!/usr/bin/env python3
"""Score anonymous speaker labels against reference RTTM, without identity claims.

Usage: diarization.py reference.rttm prediction.json [--events events.jsonl]
Prediction JSON is produced by `check diarize-json`. DER uses 10 ms frame
centres, includes overlapping reference speech, and a one-to-one label mapping.
Results with no collar and a 250 ms reference-boundary collar are both shown.
App sentence scores are separate: mixed-speaker sentences are not forced to a
single reference speaker, and unknown labels stay in the denominator.
"""
import bisect
import collections
import json
import pathlib
import sys


def rttm(path):
    result = []
    for line in pathlib.Path(path).read_text().splitlines():
        parts = line.split()
        if len(parts) >= 8 and parts[0] == "SPEAKER":
            start, duration = float(parts[3]), float(parts[4])
            result.append((start, start + duration, parts[7]))
    if not result:
        raise ValueError("Reference has no speaker turns")
    return result


def mapping(weights, reference_labels, predicted_labels):
    """Maximum overlap assignment; a split label cannot reuse a reference label."""
    refs = sorted(reference_labels)
    if len(refs) > 12:
        raise ValueError("This small evaluation tool supports at most twelve reference speakers")
    states = {0: (0.0, {})}
    for speaker in sorted(predicted_labels):
        next_states = {}
        for mask, (score, assigned) in states.items():
            choices = [(mask, score, {**assigned, speaker: None})]
            choices += [(mask | (1 << i), score + weights.get((speaker, ref), 0), {**assigned, speaker: ref})
                        for i, ref in enumerate(refs) if not mask & (1 << i)]
            for new_mask, new_score, new_assignment in choices:
                if new_mask not in next_states or new_score > next_states[new_mask][0]:
                    next_states[new_mask] = (new_score, new_assignment)
        states = next_states
    return max(states.values(), key=lambda state: state[0])[1]


def der(reference, predicted, duration, collar=0.0, step=0.01):
    boundaries = sorted({time for a, b, _ in reference for time in (a, b)})
    frames, weights = [], collections.Counter()
    for frame in range(int(duration / step)):
        time = (frame + 0.5) * step
        edge = bisect.bisect_left(boundaries, time)
        if collar and any(abs(time - boundaries[i]) < collar for i in (edge - 1, edge) if 0 <= i < len(boundaries)):
            continue
        real = {speaker for a, b, speaker in reference if a <= time < b}
        found = {speaker for a, b, speaker in predicted if a <= time < b}
        frames.append((real, found))
        for one in found - {None}:
            for other in real:
                weights[one, other] += step
    labels = {speaker for _, _, speaker in predicted if speaker is not None}
    assigned = mapping(weights, {speaker for _, _, speaker in reference}, labels)
    total = missed = false_alarm = confused = unknown = overlap = 0.0
    for real, found in frames:
        correct = len(real & {assigned.get(speaker) for speaker in found if speaker is not None})
        total += len(real) * step
        missed += max(0, len(real) - len(found)) * step
        false_alarm += max(0, len(found) - len(real)) * step
        confused += (min(len(real), len(found)) - correct) * step
        unknown += (None in found) * step
        overlap += (len(real) > 1) * step
    return {"collar_seconds": collar, "frame_seconds": step, "overlap_included": True,
            "reference_speaker_seconds": total, "overlap_seconds": overlap,
            "missed_speaker_seconds": missed, "false_alarm_speaker_seconds": false_alarm,
            "confused_speaker_seconds": confused, "unknown_label_seconds": unknown,
            "DER": None if total == 0 else (missed + false_alarm + confused) / total,
            "mapping": assigned, "predicted_speakers": len(labels)}


def sentences(reference, path):
    final = {}
    for line in pathlib.Path(path).read_text().splitlines():
        event = json.loads(line)
        if event["kind"] == "sentence":
            final[event["id"]] = event
    rows, mixed, outside = [], 0, 0
    weights = collections.Counter()
    for event in final.values():
        start, end = event["start_ms"] / 1000, event["end_ms"] / 1000
        overlap = collections.Counter()
        for a, b, speaker in reference:
            overlap[speaker] += max(0, min(end, b) - max(start, a))
        total = sum(overlap.values())
        if not total:
            outside += 1
            continue
        person, most = max(overlap.items(), key=lambda pair: pair[1])
        if most / total < 0.8:
            mixed += 1
            continue
        voice = None if event.get("voice") is None else str(event["voice"])
        rows.append((person, voice, most))
        if voice is not None:
            weights[voice, person] += most
    assigned = mapping(weights, {speaker for _, _, speaker in reference}, {voice for _, voice, _ in rows if voice is not None})
    right = sum(voice is not None and assigned.get(voice) == person for person, voice, _ in rows)
    return {"final_sentences": len(final), "dominant_speaker_threshold": 0.8,
            "eligible_sentences": len(rows), "correct_sentences": right,
            "unknown_sentences": sum(voice is None for _, voice, _ in rows),
            "mixed_speaker_sentences": mixed, "outside_reference_speech": outside,
            "accuracy": None if not rows else right / len(rows), "mapping": assigned}


def main():
    reference = rttm(sys.argv[1])
    prediction = json.loads(pathlib.Path(sys.argv[2]).read_text())
    predicted = [(item["start"], item["end"], item["speaker"]) for item in prediction["segments"]]
    result = {"reference": sys.argv[1], "prediction": sys.argv[2],
              "reference_speakers": len({speaker for _, _, speaker in reference}),
              "mode": prediction["mode"], "scores": [der(reference, predicted, prediction["audio_seconds"], c) for c in (0, 0.25)]}
    if "--events" in sys.argv:
        result["app_sentences"] = sentences(reference, sys.argv[sys.argv.index("--events") + 1])
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
