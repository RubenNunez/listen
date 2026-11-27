#!/usr/bin/env python3
"""Finite meeting checks through the real Mac app. Never stops an existing Listen process.

prepare: synthesize the three public scripted conversations, without launching Listen.
run: play them in fresh evaluation topics, with both meeting blocks enabled for this process.
Audio, application logs and evaluation notes belong in ignored runs/, never in Git.
"""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import wave

ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPTS = {
    "market-meeting": ("de", "Anna (German (Germany))", "Reed (German (Germany))"),
    "design-review": ("en", "Samantha (English (US))", "Reed (English (US))"),
    "architecture-review": ("de", "Anna (German (Germany))", "Reed (German (Germany))"),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(work):
    manifest = {}
    for label, (language, first, second) in SCRIPTS.items():
        source = ROOT / "ios/Tools/scripted" / (label + ".txt")
        pcm = bytearray(32000)
        utterances = 0
        with tempfile.TemporaryDirectory(prefix="listen-meeting-voices-") as temporary:
            for line in source.read_text().splitlines():
                if line == "--":
                    pcm.extend(bytes(80000))
                elif line.startswith(("A: ", "B: ")):
                    voice = first if line.startswith("A:") else second
                    aiff = pathlib.Path(temporary) / f"{utterances}.aiff"
                    wav = pathlib.Path(temporary) / f"{utterances}.wav"
                    text = pathlib.Path(temporary) / f"{utterances}.txt"
                    text.write_text(line[3:] + "\n")
                    # Speech input is data in a text file, never a shell or command interpreter.
                    subprocess.run(["say", "-v", voice, "-o", str(aiff), "-f", str(text)], check=True)
                    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
                    with wave.open(str(wav)) as audio:
                        assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, 16000)
                        speech = audio.readframes(audio.getnframes())
                        assert len(speech) > 6400 and any(speech), "Speech synthesis produced no audible PCM"
                        pcm.extend(speech)
                    pcm.extend(bytes(25600))
                    utterances += 1
        raw = work / (label + ".raw")
        raw.write_bytes(pcm)
        manifest[label] = {"language": language, "script_sha256": digest(source), "input_sha256": digest(raw),
                           "input_seconds": len(pcm) / 32000, "utterances": utterances, "voices": [first, second]}
        print(label, round(len(pcm) / 32000, 2), "seconds", flush=True)
    (work / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")


def mac_is_free():
    result = subprocess.run(["pgrep", "-x", "Listen"], capture_output=True)
    if result.returncode != 1:
        raise SystemExit("Listen is running (or process inspection failed). No app was started or stopped.")


def note_for(topic):
    bases = [pathlib.Path.home() / "Library/Application Support",
             pathlib.Path.home() / "Library/Containers/com.meowop.listen/Data/Library/Application Support"]
    for base in bases:
        file = base / "topics.json"
        if not file.is_file():
            continue
        data = json.loads(file.read_text())
        matches = [item for item in data.get("topics", []) if item.get("name") == topic and item.get("evaluation") is True]
        if matches:
            folder = base / "Listen/Topics" / matches[0]["id"] / "conversations"
            notes = sorted(folder.glob("*.md"))
            return notes[-1].read_text() if notes else None
    return None


def run(work, app):
    mac_is_free()
    frozen = work / "Listen.app"
    if not frozen.exists():
        shutil.copytree(app, frozen)
    executable = frozen / "Contents/MacOS/Listen"
    assert digest(executable) == digest(app / "Contents/MacOS/Listen"), "Use a new work directory for a different frozen build"
    assert digest(frozen / "Contents/MacOS/Listen.debug.dylib") == digest(app / "Contents/MacOS/Listen.debug.dylib"), "Frozen debug library differs from the requested build"
    manifest = json.loads((work / "inputs.json").read_text())
    results = {}
    runs = ROOT / "runs"
    for label, spec in manifest.items():
        mac_is_free()
        case = work / label
        case.mkdir(exist_ok=True)
        topic = "Meeting eval " + label + " " + work.name
        assert digest(work / (label + ".raw")) == spec["input_sha256"], "Input changed after preparation"
        environment = os.environ.copy()
        environment.update(LISTEN_EVAL_TOPIC=topic, LISTEN_EVAL_TIMELINE="0", LISTEN_LANGUAGE=spec["language"],
                           LISTEN_JEV_DECISIONS="1", LISTEN_FORECAST="0", LISTEN_MEETING_ITEMS="1", LISTEN_MEETING_MINUTES="1")
        before = {path.name for path in runs.iterdir() if path.is_dir() and (path / "run.json").is_file()}
        print("Starting", label, "in an isolated evaluation topic", flush=True)
        with (case / "app.log").open("w") as log:
            result = subprocess.run([str(executable), "-runsFolder", str(runs), "-recordRuns", "YES", "-audioFile", str(work / (label + ".raw"))],
                                    env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=spec["input_seconds"] + 180)
        assert result.returncode == 0, f"{label}: app failed; see {case / 'app.log'}"
        fresh = [path for path in runs.iterdir() if path.is_dir() and path.name not in before and (path / "run.json").is_file()]
        assert len(fresh) == 1, f"{label}: expected one recording, found {len(fresh)}"
        recording = fresh[0]
        metadata = json.loads((recording / "run.json").read_text())
        assert metadata.get("topic") == topic, "The run was not recorded in the intended evaluation topic"
        assert metadata.get("audio_seconds", 0) >= spec["input_seconds"] - 0.1, "The run ended before the complete script was fed"
        source_pcm = (work / (label + ".raw")).read_bytes()
        with wave.open(str(recording / "audio.wav")) as captured:
            assert captured.readframes(len(source_pcm) // 2) == source_pcm, "Recorded PCM does not contain the complete prepared input prefix"
        events = [json.loads(line) for line in (recording / "events.jsonl").read_text().splitlines()]
        meeting = [event for event in events if event.get("kind") == "meeting"]
        note = note_for(topic)
        minutes = None
        if note is not None:
            (case / "note.md").write_text(note)
            if "## Summary\n\n" in note:
                minutes = note.split("## Summary\n\n", 1)[1].split("\n## Listen showed", 1)[0].strip()
                (case / "minutes.md").write_text(minutes + "\n")
        results[label] = {"run": str(recording.relative_to(ROOT)), "input_seconds": spec["input_seconds"],
                          "recorded_seconds_including_silent_tail": metadata.get("audio_seconds"),
                          "classifications": sum(event.get("state") == "classified" for event in meeting),
                          "accepted_candidates": sum(event.get("accepted", 0) for event in meeting),
                          "unavailable": [event.get("reason", event.get("state")) for event in meeting if "unavailable" in event.get("state", "")],
                          "minutes_ready": any(event.get("state") == "minutes ready" for event in meeting),
                          "minutes_persisted": minutes is not None,
                          "note_found": note is not None}
        (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(label, json.dumps(results[label]), flush=True)
    (work / "build.json").write_text(json.dumps({"executable_sha256": digest(executable),
        "debug_library_sha256": digest(frozen / "Contents/MacOS/Listen.debug.dylib")}, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "run"])
    parser.add_argument("work", type=pathlib.Path)
    parser.add_argument("--app", type=pathlib.Path)
    args = parser.parse_args()
    args.work = args.work.resolve()
    if args.work != ROOT / "runs" and ROOT / "runs" not in args.work.parents:
        parser.error("Evaluation artifacts must stay inside the repository's ignored runs/ folder")
    args.work.mkdir(parents=True, exist_ok=True)
    if args.mode == "prepare":
        prepare(args.work)
    else:
        if args.app is None:
            parser.error("run requires --app pointing to a built Mac app")
        run(args.work, args.app.resolve())
