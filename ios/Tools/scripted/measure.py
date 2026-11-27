#!/usr/bin/env python3
"""Measures a recorded run: how fast cards came, how the blocks were formed, what was asked
of the models, and whether what the script expects is on the table.

Usage: measure.py <run folder> [script.txt]
  A script may state what it expects, in lines that start with "!":
    ! blocks 4                  that many blocks at the end
    ! expect PostgreSQL | 57    one block holds all of these words (case does not matter)
    ! silent Verkehr            the word was heard and no card is about it
Exit code 1 when an expectation is not met.
"""
import collections
import json
import pathlib
import statistics
import sys

run = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in (run / "events.jsonl").read_text().splitlines() if line.strip()]

sentences, original_ends, offset = {}, {}, None
for e in events:
    if e["kind"] == "sentence":
        sentences[e["id"]] = e
        original_ends.setdefault(e["id"], e["end_ms"] / 1000)
        if offset is None:
            offset = e["t"] - e["end_ms"] / 1000  # when the recording began, on the clock of the events
clocks = [e["t"] - e["seconds"] - original_ends[e["sentence"]]
          for e in events if e["kind"] == "layer" and e["name"] == "1 · Apple"
          and isinstance(e.get("seconds"), (int, float)) and e["sentence"] in original_ends]
if clocks:
    offset = statistics.median(clocks)
else:
    print("  WARNING: no audio clock trace; latency uses a legacy estimate that includes first-sentence recognition delay")
said_at = {i: offset + s["end_ms"] / 1000 for i, s in sentences.items()}

text, began, trigger, layer, replaced_by = {}, {}, {}, {}, {}
for e in events:
    if e["kind"] == "card_started":
        began[e["card"]], trigger[e["card"]], layer[e["card"]] = e["t"], e["sentence"], e["layer"]
    elif e["kind"] == "card_text":
        text[e["card"]] = text.get(e["card"], "") + e["text"]
    elif e["kind"] == "card_replaced":
        replaced_by[e["card"]] = e["by"]

# Blocks: chains of cards that replaced each other.
replaces = {new: old for old, new in replaced_by.items()}
def root(card):
    while card in replaces:
        card = replaces[card]
    return card
blocks = collections.OrderedDict()
for card in sorted(text):
    blocks.setdefault(root(card), []).append(card)

steps = [e for e in events if e["kind"] == "layer" and e["name"][:1] in "345"]
drafts = [e for e in steps if e["name"].startswith("3")]
web = [e for e in steps if e["name"].startswith("5")]
def seconds(values):
    return "–" if not values else f"{statistics.median(values):.1f} s (median of {len(values)}, longest {max(values):.1f} s)"

# How long after a question was spoken its first card and its checked card were there.
first, checked = {}, {}
for card in sorted(began):
    s = trigger[card]
    if s not in said_at:
        continue
    wait = began[card] - said_at[s]
    first.setdefault(s, wait)
    if layer[card] == "deep":
        checked.setdefault(s, wait)

print(f"Run {run.name}: {len(sentences)} sentences, {len(text)} cards in {len(blocks)} blocks")
print(f"  first card after estimated sentence end:   {seconds(list(first.values()))}")
print(f"  checked card after estimated sentence end: {seconds(list(checked.values()))}")
print("  These counts include only answered triggers. Use latency.py for PCM endpoints and missing questions.")
print(f"  model, first lines of a draft:   {seconds([e['seconds'] for e in drafts if 'first lines' in e['detail'] or 'first new lines' in e['detail']])}")
print(f"  model, whole draft:              {seconds([e['seconds'] for e in drafts if 'first draft' in e['detail']])}")
print(f"  model, checked card from the web: {seconds([e['seconds'] for e in web if 'checked card' in e['detail']])}")
asked = sum(e['kind'] == 'request' for e in events)
nothing = sum('nothing to show' in e['detail'] for e in steps)
print(f"  logged model requests: {asked}, of which {nothing} came back with nothing to show")
for number, (first_card, cards) in enumerate(blocks.items(), 1):
    final = text[cards[-1]]
    lines = [l for l in final.split("\n") if l.strip()]
    kinds = [k for k in ("chart", "svg", "formula") if f"```{k}" in final] + (["code"] if final.count("```") >= 2 and "```chart" not in final and "```svg" not in final and "```formula" not in final else [])
    sources = final.count("](http")
    print(f"  block {number}: {lines[0].strip('*')[:60]} · {len(cards)} versions · {sources} sources" + (f" · {', '.join(kinds)}" if kinds else ""))

# Who spoke: with the true speakers of a recording (an RTTM file) the voices the app found are
# checked. `--rttm <file> --offset <seconds>`: the offset is where the excerpt begins in the recording.
if "--rttm" in sys.argv:
    rttm = pathlib.Path(sys.argv[sys.argv.index("--rttm") + 1])
    shift = float(sys.argv[sys.argv.index("--offset") + 1]) if "--offset" in sys.argv else 0.0
    turns = []
    for line in rttm.read_text().splitlines():
        parts = line.split()
        if len(parts) > 7 and parts[0] == "SPEAKER":
            turns.append((float(parts[3]) - shift, float(parts[3]) + float(parts[4]) - shift, parts[7]))
    pairs = collections.Counter()
    for s in sentences.values():
        if s.get("voice") is None:
            continue
        a, b = s["start_ms"] / 1000, s["end_ms"] / 1000
        share = collections.Counter()
        for start, end, who in turns:
            overlap = min(b, end) - max(a, start)
            if overlap > 0:
                share[who] += overlap
        if share:
            pairs[(share.most_common(1)[0][0], s["voice"])] += 1
    people = sorted({p for p, _ in pairs})
    voices = sorted({v for _, v in pairs})
    total = sum(pairs.values())
    # Each voice stands for the person it was heard for most often.
    right = sum(max(pairs[(p, v)] for p in people) for v in voices)
    print(f"  speakers: {len(people)} people in the recording, {len(voices)} voices found; {right} of {total} sentences are in a voice that stands for their speaker")
    for p in people:
        print(f"    {p}: " + ", ".join(f"voice {v} × {pairs[(p, v)]}" for v in voices if pairs[(p, v)]))

failed = 0
if len(sys.argv) > 2 and not sys.argv[2].startswith("--"):
    finals = [text[cards[-1]].lower() for cards in blocks.values()]
    for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
        if not line.startswith("!"):
            continue
        kind, _, rest = line[1:].strip().partition(" ")
        if kind == "blocks":
            ok = len(blocks) == int(rest)
            detail = f"{len(blocks)} blocks"
        elif kind == "expect":
            words = [w.strip().lower() for w in rest.split("|")]
            ok = any(all(w in final for w in words) for final in finals)
            detail = "on the table" if ok else "not on the table"
        elif kind == "silent":
            # A round may start on that sentence and still answer the question before it,
            # so what counts is whether any card is about the word.
            hit = [i for i, s in sentences.items() if rest.lower() in s["text"].lower()]
            about = [c for c, t in text.items() if rest.lower() in t.lower()]
            ok = bool(hit) and not about
            detail = "no card" if ok else ("the sentence was not heard" if not hit else "a card is about it")
        else:
            continue
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} · {line[1:].strip()} · {detail}")
sys.exit(1 if failed else 0)
