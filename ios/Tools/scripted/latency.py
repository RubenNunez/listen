#!/usr/bin/env python3
"""Measure synthetic scripted runs against speech in their recorded PCM.

Usage: latency.py script.txt run-folder [run-folder ...]
The script and recording must contain the same ordered utterances. Quiet gaps
must exceed 1.2 seconds; ambiguous alignment is rejected rather than guessed.
The clock comes from Apple trace timestamps minus fed-audio time, not from
assuming the first recognised sentence arrived without delay. This measures
emitted card content, not the first painted screen frame.
"""
import array
import json
import math
import pathlib
import statistics
import sys
import wave


def speech_regions(path):
    with wave.open(str(path), "rb") as sound:
        if (sound.getnchannels(), sound.getsampwidth(), sound.getframerate()) != (1, 2, 16000):
            raise ValueError("Expected 16 kHz mono 16-bit PCM")
        pcm = array.array("h", sound.readframes(sound.getnframes()))
    if sys.byteorder != "little":
        pcm.byteswap()
    # 10 ms RMS frames, threshold 120/32768 full scale. An utterance's endpoint
    # is the end of its last active frame; no transcript timing is used for it.
    regions = []
    for start in range(0, len(pcm) - 159, 160):
        rms = math.sqrt(sum(value * value for value in pcm[start:start + 160]) / 160)
        if rms <= 120:
            continue
        a, b = start / 16000, (start + 160) / 16000
        if regions and a - regions[-1][1] < 1.2:
            regions[-1][1] = b
        else:
            regions.append([a, b])
    return regions


def audio_clock(events):
    first = {}
    for event in events:
        if event["kind"] == "sentence":
            first.setdefault(event["id"], event)
    offsets = [event["t"] - event["seconds"] - first[event["sentence"]]["end_ms"] / 1000
               for event in events if event["kind"] == "layer" and event["name"] == "1 · Apple"
               and isinstance(event.get("seconds"), (int, float)) and event["sentence"] in first]
    if not offsets:
        raise ValueError("No Apple trace clock: cannot measure from acoustic speech end")
    return statistics.median(offsets), max(offsets) - min(offsets)


def measure(script, run):
    utterances = [line[3:].strip() for line in script.read_text().splitlines()
                  if line.startswith(("A: ", "B: "))]
    regions = speech_regions(run / "audio.wav")
    if len(utterances) != len(regions):
        raise ValueError(f"{run.name}: {len(utterances)} utterances but {len(regions)} speech regions; alignment is ambiguous")
    events = [json.loads(line) for line in (run / "events.jsonl").read_text().splitlines() if line.strip()]
    offset, spread = audio_clock(events)
    sentences, texts, starts = {}, {}, {}
    first_text, first_answer = {}, {}
    for event in events:
        if event["kind"] == "sentence":
            sentences.setdefault(event["id"], event)
        elif event["kind"] == "card_started":
            starts[event["card"]] = event
        elif event["kind"] == "card_text":
            card = event["card"]
            texts[card] = texts.get(card, "") + event["text"]
            lines = [line for line in texts[card].splitlines() if line.strip()]
            if lines:
                first_text.setdefault(card, event["t"])
            if len(lines) >= 2:
                first_answer.setdefault(card, event["t"])
    rows = []
    for index, (question, region) in enumerate(zip(utterances, regions)):
        if not question.endswith("?"):
            continue
        # Assign recognised segments by their audio endpoint. Missing questions
        # remain in the denominator even if the recogniser or models missed them.
        until = regions[index + 1][0] if index + 1 < len(regions) else math.inf
        heard = {key: value for key, value in sentences.items()
                 if region[0] <= value["end_ms"] / 1000 < until}
        cards = {key: value for key, value in starts.items() if value["sentence"] in heard}
        first = min((first_text[key] for key in cards if key in first_text), default=None)
        answer_card = min((key for key in cards if key in first_answer),
                          key=lambda key: first_answer[key], default=None)
        answer = first_answer.get(answer_card)
        deep = min((first_answer[key] for key in cards if key in first_answer and cards[key]["layer"] == "deep"), default=None)
        row = {"question": question, "audio_start": region[0], "audio_end": region[1],
               "recognised": [value["text"] for value in heard.values()],
               "first_content_seconds": None if first is None else first - offset - region[1],
               "first_answer_seconds": None if answer is None else answer - offset - region[1],
               "deep_answer_seconds": None if deep is None else deep - offset - region[1]}
        if answer_card is not None:
            trigger = cards[answer_card]["sentence"]
            apple = sentences[trigger]["t"]
            requests = [event["t"] for event in events if event["kind"] == "request"
                        and event["sentence"] == trigger and "draft" in event["agent"]]
            sent = min(requests, default=None)
            ready = min((event["t"] for event in events if event["kind"] == "layer"
                         and event["sentence"] == trigger and event["name"] == "2 · total"
                         and (sent is None or event["t"] <= sent)), default=None)
            row["stages"] = {"speech_to_apple": apple - offset - region[1],
                             "apple_to_refined": None if ready is None else ready - apple,
                             "refined_to_request": None if ready is None or sent is None else sent - ready,
                             "request_to_answer": None if sent is None else answer - sent}
        rows.append(row)
    return {"run": run.name, "audio_clock_offset": offset, "audio_clock_spread": spread,
            "models": sorted({event["model"] for event in events if event["kind"] == "request"}),
            "requests": sum(event["kind"] == "request" for event in events), "questions": rows}


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    results = [measure(pathlib.Path(sys.argv[1]), pathlib.Path(run)) for run in sys.argv[2:]]
    rows = [row for result in results for row in result["questions"]]
    summary = {"runs": len(results), "questions": len(rows),
               "with_answer": sum(row["first_answer_seconds"] is not None for row in rows)}
    for key in ("first_content_seconds", "first_answer_seconds", "deep_answer_seconds"):
        values = [row[key] for row in rows if row[key] is not None]
        summary[key] = None if not values else {"n": len(values), "median": statistics.median(values),
                                               "min": min(values), "max": max(values)}
    print(json.dumps({"method": "PCM RMS endpoints; Apple fed-audio clock; emitted content, not painted frames",
                      "summary": summary, "runs": results}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
