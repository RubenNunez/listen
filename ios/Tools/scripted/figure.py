#!/usr/bin/env python3
"""Draws one stretch of a recorded run for the documents, from the run alone.

  timeline.svg  the stretch as the app's timeline shows it: one lane per kind of
                event, one line per block, the recorded signal under "Heard", and
                numbered notes on the moments worth seeing
  cards.svg     the cards as they lay on the table at the end of the stretch

Usage:
  figure.py <run folder> <from s> <to s> <out folder> [--note card:<id>=<title>] [--note quiet:<sentence>=<title>]
            [--title <what the run is>] [--cards <id>,<id>,<id>]

A note's title is written by hand; everything else (boxes, times, texts, sources)
comes from events.jsonl and audio.wav. Use only runs whose speech may be published:
scripted conversations spoken by system voices, never a recording of real people.
"""
import html
import json
import pathlib
import re
import sys
import wave

HELD = ["said this before", "already covers", "nothing new", "later moment", "same as the card", "already on the table", "nothing to add"]
# The tints of the app's timeline (RunTimelineView), as dark-mode system colours.
GRAY, BLUE, ORANGE, PURPLE, TEAL, RED, YELLOW, INDIGO, GREEN = (
    "#8e8e93", "#0a84ff", "#ff9f0a", "#bf5af2", "#40c8e0", "#ff453a", "#ffd60a", "#5e5ce6", "#30d158")
FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Inter, Helvetica, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', Menlo, Consolas, monospace"


def esc(text):
    return html.escape(str(text), quote=True)


def clip(text, chars):
    return text if len(text) <= chars else text[: max(1, chars - 1)].rstrip() + "…"


def wrap(text, chars):
    lines, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > chars:
            lines.append(line)
            line = word
        else:
            line = f"{line} {word}".strip()
    return lines + ([line] if line else [])


def plain(text):
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    return text.replace("**", "").replace("`", "").strip()


# ---------------------------------------------------------------- reading the run

def read(run):
    events = [json.loads(l) for l in (run / "events.jsonl").read_text().splitlines() if l.strip()]
    offset, sentences, rounds, requests, gates, cards, text, landed, replaces = None, {}, [], [], [], {}, {}, {}, {}
    pending = []
    for e in events:
        t, kind = e.get("t", 0.0), e["kind"]
        if kind == "sentence":
            end = e["end_ms"] / 1000
            if offset is None:
                offset = t - end
            sentences[e["id"]] = dict(start=offset + e["start_ms"] / 1000, end=offset + end, text=e["text"])
        elif kind == "round":
            rounds.append(dict(at=t, sentence=e["sentence"], text=e["state"]))
            if e["state"].startswith(("starts", "takes")):
                # A new round gives up the drafts still open, as in layout.py and the app.
                for r in [r for r in pending if "draft" in r["agent"]]:
                    r["end"], r["result"] = t, "given up: a newer moment took its place"
                    pending.remove(r)
        elif kind == "request":
            r = dict(agent=e["agent"], model=e["model"], sentence=e["sentence"], start=t, end=None, result="open")
            requests.append(r)
            pending.append(r)
        elif kind == "layer" and e["name"][:1] in "345":
            detail = e["detail"]
            if detail.startswith("first lines"):
                continue
            if any(h in detail for h in HELD):
                gates.append(dict(at=t, sentence=e["sentence"], text=detail))
            agent = "web" if e["name"][0] == "5" else "merge" if e["name"][0] == "4" else "draft"
            model = e["name"][4:]
            match = next((r for r in pending if r["sentence"] == e["sentence"] and agent in r["agent"]
                          and (agent != "draft" or r["model"] == model)), None)
            if match:
                match["end"], match["result"] = t, detail
                pending.remove(match)
        elif kind == "card_started":
            cards[e["card"]] = dict(id=e["card"], at=t, deep=e["layer"] == "deep", sentence=e["sentence"])
        elif kind == "card_text":
            text[e["card"]] = text.get(e["card"], "") + e["text"]
        elif kind == "card_replaced":
            replaces[e["by"]] = e["card"]
        elif kind == "landed":
            landed[e["card"]] = e
    for card in cards.values():
        root = card["id"]
        while root in replaces:
            root = replaces[root]
        info = landed.get(card["id"], {})
        card.update(block=info.get("block", root), version=info.get("version", 1), how=info.get("how", ""),
                    text=text.get(card["id"], ""))
    return dict(sentences=sentences, rounds=rounds, requests=requests, gates=gates, cards=cards)


def peaks(run, every=0.05):
    path = run / "audio.wav"
    if not path.exists():
        return []
    with wave.open(str(path), "rb") as sound:
        rate, data = sound.getframerate(), sound.readframes(sound.getnframes())
    step = int(rate * every)
    samples = memoryview(data).cast("h")
    return [max(abs(v) for v in samples[i:i + step]) / 32768 for i in range(0, len(samples) - step, step)]


# ---------------------------------------------------------------- the timeline

def timeline(run, data, start, stop, notes):
    W, LEFT, RIGHT, ROW = 1000, 132, 16, 22
    scale = (W - LEFT - RIGHT) / (stop - start)
    x = lambda t: round(LEFT + (t - start) * scale, 1)
    inside = lambda a, b: b >= start and a <= stop

    def width(label, a, b):
        text = len(label) * 5.9 + 14
        lasting = (b - a) * scale - 2 if b is not None else 0
        return max(lasting, min(text, 300))

    def rows(items):
        out, ends = [], []
        for item in sorted(items, key=lambda i: i["start"]):
            left = x(item["start"])
            row = next((n for n, end in enumerate(ends) if end + 4 <= left), len(ends))
            if row == len(ends):
                ends.append(0)
                out.append([])
            ends[row] = left + width(item["label"], item["start"], item["end"])
            out[row].append(item)
        return out or [[]]

    item = lambda **kw: dict(dict(end=None, filled=True, mark=None), **kw)
    heard = [item(start=s["start"], end=s["end"], label=f"#{i} {s['text']}", tint=GRAY)
             for i, s in data["sentences"].items() if inside(s["start"], s["end"])]
    scheduler = [item(start=r["at"], label=f"#{r['sentence']} " + ("waits" if "wait" in r["text"] else r["text"].split()[0]),
                      tint=ORANGE if "wait" in r["text"] else BLUE, filled="wait" not in r["text"])
                 for r in data["rounds"] if inside(r["at"], r["at"])]
    requests = []
    for r in data["requests"]:
        end = r["end"] if r["end"] is not None else stop
        if not inside(r["start"], end):
            continue
        quiet, given = "nothing to show" in r["result"], r["result"].startswith("given up")
        tint = ORANGE if r["end"] is None else RED if given else GRAY if quiet else TEAL if r["agent"] == "web" else PURPLE
        outcome = " · nothing" if quiet else " · given up" if given else " · open" if r["end"] is None else ""
        requests.append(item(start=r["start"], end=end, tint=tint, filled=not (quiet or given), request=r,
                             label=f"{r['agent']} · {end - r['start']:.1f} s{outcome}"))
    gates = [item(start=g["at"], label=f"#{g['sentence']} held back", tint=YELLOW, filled=False)
             for g in data["gates"] if inside(g["at"], g["at"])]
    blocks = {}
    for c in sorted(data["cards"].values(), key=lambda c: c["at"]):
        if inside(c["at"], c["at"]):
            title = plain(c["text"].split("\n")[0]) if c["text"] else ""
            blocks.setdefault(c["block"], []).append(item(
                start=c["at"], card=c, tint=GREEN if c["deep"] else INDIGO,
                label=f"v{c['version']}{' ✓' if c['deep'] else ''} · {title}"))

    # Notes: a number on the moment, a box below with the hand-written title and the facts of the run.
    boxes = []
    for number, (kind, key, title) in enumerate(notes, 1):
        if kind == "card":
            card = data["cards"][key]
            spoken = data["sentences"].get(card["sentence"], {})
            sources = len(re.findall(r"\]\(https?://", card["text"]))  # links, not an SVG's namespace
            facts = f"{card['at'] - spoken.get('end', card['at']):.1f} s after the sentence ended"
            facts += " · checked" + (f", {sources} source{'s' if sources != 1 else ''}" if sources else ", no source") if card["deep"] else " · draft"
            for lane in blocks.values():
                for it in lane:
                    if it.get("card") is card:
                        it["mark"] = number
            boxes.append((number, title, facts, f"“{clip(plain(spoken.get('text', '')), 70)}”"))
        else:
            asked = [it for it in requests if it["request"]["sentence"] == key]
            spoken = data["sentences"].get(key, {})
            quiet = sum("nothing to show" in it["request"]["result"] for it in asked)
            if asked:
                asked[-1]["mark"] = number
            boxes.append((number, title, f"{len(asked)} model{'s' if len(asked) != 1 else ''} asked · {quiet} found nothing to show",
                          f"“{clip(plain(spoken.get('text', '')), 70)}”"))

    lanes = [("Heard", "the listening stages", rows(heard)),
             ("Scheduler", "rounds start or wait", rows(scheduler)),
             ("Requests", "every call to a model", rows(requests)),
             ("Harness", "replies held back", rows(gates))]
    for n, (block, items) in enumerate(blocks.items()):
        lanes.append((f"Block {n + 1}", clip(plain(items[-1]["label"].split(" · ", 1)[-1]), 22), rows(items)))

    out, y = [], 84
    out.append(f'<rect width="{W}" height="__H__" rx="14" fill="#171717"/>')
    out.append(f'<text x="20" y="28" class="h">Timeline</text>')
    out.append(f'<text x="20" y="46" class="n">{esc(run.name)} · {start:.0f}–{stop:.0f} s of {esc(TITLE)}</text>')
    out.append(f'<clipPath id="strip"><rect x="{LEFT}" y="0" width="{W - LEFT - RIGHT}" height="4000"/></clipPath>')
    for t in range(int(start // 5 * 5 + 5), int(stop) + 1, 5):
        out.append(f'<line x1="{x(t)}" y1="{y - 8}" x2="{x(t)}" y2="__B__" class="tick"/>')
        out.append(f'<text x="{x(t)}" y="{y - 12}" class="n" text-anchor="middle">{t} s</text>')
    signal = peaks(run)
    for name, note, lane_rows in lanes:
        height = len(lane_rows) * ROW + 10
        out.append(f'<line x1="12" y1="{y}" x2="{W - 12}" y2="{y}" class="sep"/>')
        out.append(f'<text x="20" y="{y + 17}" class="l">{esc(name)}</text>')
        out.append(f'<text x="20" y="{y + 30}" class="n">{esc(note)}</text>')
        out.append('<g clip-path="url(#strip)">')
        if name == "Heard" and signal:
            mid, reach = y + height / 2, height / 2 - 3
            path = " ".join(f"M{x(i * 0.05)} {mid - reach * p:.1f}V{mid + reach * p:.1f}"
                            for i, p in enumerate(signal) if start <= i * 0.05 <= stop and p > 0.004)
            out.append(f'<path d="{path}" class="sig"/>')
        for r, row in enumerate(lane_rows):
            top = y + 5 + r * ROW
            for it in row:
                left, w = x(it["start"]), width(it["label"], it["start"], it["end"])
                fill = f'fill="{it["tint"]}" fill-opacity="{0.85 if it["filled"] else 0.14}"'
                stroke = "" if it["filled"] else f' stroke="{it["tint"]}" stroke-width="1"'
                out.append(f'<rect x="{left}" y="{top}" width="{w:.1f}" height="18" rx="5" {fill}{stroke}/>')
                indent = 6
                if it["mark"]:
                    out.append(f'<circle cx="{left + 9}" cy="{top + 9}" r="7.5" fill="#fff"/>'
                               f'<text x="{left + 9}" y="{top + 12.5}" class="k" text-anchor="middle">{it["mark"]}</text>')
                    indent = 20
                chars = int((w - indent - 4) / 5.9)
                colour = "#fff" if it["filled"] else it["tint"]
                out.append(f'<text x="{left + indent}" y="{top + 13}" class="i" fill="{colour}">{esc(clip(it["label"], chars))}</text>')
        out.append('</g>')
        y += height
    bottom = y
    out.append(f'<line x1="12" y1="{y}" x2="{W - 12}" y2="{y}" class="sep"/>')

    # The note boxes.
    y += 16
    gap, count = 10, max(1, len(boxes))
    bw = (W - 40 - gap * (count - 1)) / count
    tallest = 0
    for i, (number, title, facts, said) in enumerate(boxes):
        bx = 20 + i * (bw + gap)
        chars = int((bw - 24) / 6.1)
        lines = [(t, "bt") for t in wrap(title, int((bw - 40) / 7.0))] + [(t, "bf") for t in wrap(facts, chars)] + [(t, "bq") for t in wrap(said, chars)]
        h = 22 + len(lines) * 16 + 6
        tallest = max(tallest, h)
        out.append(f'<rect x="{bx:.1f}" y="{y}" width="{bw:.1f}" height="__BH__" rx="10" fill="#242424" stroke="#3a3a3c"/>')
        out.append(f'<circle cx="{bx + 18:.1f}" cy="{y + 20}" r="8.5" fill="#fff"/><text x="{bx + 18:.1f}" y="{y + 24}" class="k" text-anchor="middle">{number}</text>')
        ly = y + 25
        for n, (t, cls) in enumerate(lines):
            lx = bx + 34 if n == 0 or cls == "bt" else bx + 12
            out.append(f'<text x="{lx:.1f}" y="{ly}" class="{cls}">{esc(t)}</text>')
            ly += 16
    height = y + tallest + 18
    body = "\n".join(out).replace("__H__", str(height)).replace("__B__", str(bottom)).replace("__BH__", str(tallest))
    style = f"""
  .h {{ fill: #fff; font: 600 15px {FONT}; }}
  .l {{ fill: #f2f2f7; font: 600 12px {FONT}; }}
  .n {{ fill: #8e8e93; font: 10.5px {FONT}; }}
  .i {{ font: 500 10.5px {FONT}; }}
  .k {{ fill: #171717; font: 700 10.5px {FONT}; }}
  .bt {{ fill: #fff; font: 600 12.5px {FONT}; }}
  .bf {{ fill: #c7c7cc; font: 11.5px {FONT}; }}
  .bq {{ fill: #8e8e93; font: italic 11.5px {FONT}; }}
  .tick {{ stroke: #ffffff; stroke-opacity: .07; }}
  .sep {{ stroke: #ffffff; stroke-opacity: .10; }}
  .sig {{ stroke: #ffffff; stroke-opacity: .16; stroke-width: 1.6; }}"""
    label = "The timeline of a recorded conversation: what was heard, when rounds started, every model request and every card, with numbered notes."
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {height}" width="{W}" height="{height}" role="img" aria-label="{esc(label)}">\n'
            f'<style>{style}\n</style>\n{body}\n</svg>\n')


# ---------------------------------------------------------------- the table

def drawing(svg, x, y, w, h, prefix):
    """A model's SVG drawing, inside a white panel as in the app. Anything active is refused."""
    if re.search(r"<script|foreignObject|\son\w+\s*=|href\s*=\s*[\"'](?!#)", svg, re.I):
        return ""
    svg = svg.replace('id="', f'id="{prefix}').replace("url(#", f"url(#{prefix}")
    svg = re.sub(r"<svg\b[^>]*?(viewBox=\"[^\"]+\")[^>]*>", rf'<svg x="{x + 8}" y="{y + 8}" width="{w - 16}" height="{h - 16}" \1>', svg, count=1)
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="#fff" stroke="#000" stroke-opacity=".08"/>\n{svg}'


def table(data, start, stop, chosen=None):
    W, PAD, GAP = 1000, 20, 14
    if chosen:
        cards = [data["cards"][c] for c in chosen]
    else:
        last = {}
        for c in sorted(data["cards"].values(), key=lambda c: c["at"]):
            if start <= c["at"] <= stop:
                last[c["block"]] = c
        cards = list(last.values())[-3:]
    cw = (W - 2 * PAD - GAP * (len(cards) - 1)) / max(1, len(cards))
    out, tallest = [], 0
    for i, card in enumerate(cards):
        cx, y = PAD + i * (cw + GAP), PAD + 14
        parts, inner = [], cx + 18
        lines = card["text"].split("\n")
        title, rest = plain(lines[0]), lines[1:]
        for t in wrap(title, int((cw - 36) / 8.2)):
            parts.append(f'<text x="{inner}" y="{y + 22}" class="ct">{esc(t)}</text>')
            y += 20
        y += 10
        fence, code, sources = None, [], []
        for line in rest:
            if line.startswith("```"):
                if fence is None:
                    fence, code = line[3:].strip() or "code", []
                    continue
                if fence == "svg":
                    parts.append(drawing("\n".join(code), inner, y + 6, cw - 36, (cw - 36) * 0.22 + 16, f"d{card['id']}-"))
                    y += (cw - 36) * 0.22 + 26
                else:
                    shown = code[:9]
                    box = len(shown) * 14 + 16
                    parts.append(f'<rect x="{inner}" y="{y + 6}" width="{cw - 36}" height="{box}" rx="8" class="code"/>')
                    for n, c in enumerate(shown):
                        parts.append(f'<text x="{inner + 10}" y="{y + 24 + n * 14}" class="cc" xml:space="preserve">{esc(clip(c, int((cw - 56) / 6.3)))}</text>')
                    y += box + 14
                fence = None
                continue
            if fence is not None:
                code.append(line)
                continue
            if not line.strip():
                continue
            if line.startswith(("Quellen:", "Sources:")):
                sources = re.findall(r"\[([^\]]+)\]", line)
                continue
            strong = line.startswith("**")
            for t in wrap(plain(line), int((cw - 36) / (7.2 if strong else 6.4))):
                parts.append(f'<text x="{inner}" y="{y + 16}" class="{"ca" if strong else "cd"}">{esc(t)}</text>')
                y += 19 if strong else 17
        if card["deep"]:
            y += 8
            chip = "✓ checked" + (f" · {sources[0]}" + (f" +{len(sources) - 1}" if len(sources) > 1 else "") if sources else " · no source")
            parts.append(f'<rect x="{inner}" y="{y + 2}" width="{len(chip) * 6.4 + 18:.0f}" height="20" rx="10" class="chip"/>'
                         f'<text x="{inner + 9}" y="{y + 16}" class="cs">{esc(chip)}</text>')
            y += 26
        height = y - PAD - 14 + 20
        tallest = max(tallest, height)
        out.append((cx, cw, parts))
    svg = []
    for cx, cw, parts in out:
        svg.append(f'<rect x="{cx}" y="{PAD + 14}" width="{cw:.1f}" height="{tallest}" rx="22" class="card"/>')
        svg.extend(parts)
    H = PAD + 14 + tallest + PAD
    style = f"""
  .bg {{ fill: #f2f1ee; }}
  .card {{ fill: #ffffff; stroke: #000; stroke-opacity: .08; }}
  .ct {{ fill: #15191f; font: 700 15px {FONT}; }}
  .ca {{ fill: #15191f; font: 600 12.5px {FONT}; }}
  .cd {{ fill: #4a515c; font: 12px {FONT}; }}
  .code {{ fill: #f3f4f6; }}
  .cc {{ fill: #23272f; font: 10.5px {MONO}; }}
  .chip {{ fill: #e3f5e8; }}
  .cs {{ fill: #1d7a3a; font: 600 11px {FONT}; }}
  @media (prefers-color-scheme: dark) {{
    .bg {{ fill: #0d1117; }}
    .card {{ fill: #1c1c1e; stroke: #fff; stroke-opacity: .12; }}
    .ct, .ca {{ fill: #f2f2f7; }}
    .cd {{ fill: #aeb4bd; }}
    .code {{ fill: #2a2a2d; }}
    .cc {{ fill: #e5e5ea; }}
    .chip {{ fill: #173d24; }}
    .cs {{ fill: #6fdc8c; }}
  }}"""
    label = "The cards Listen put on the table during that stretch: " + "; ".join(plain(c["text"].split("\n")[0]) for c in cards)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="{esc(label)}">\n'
            f'<style>{style}\n</style>\n<rect class="bg" width="{W}" height="{H}" rx="14"/>\n' + "\n".join(svg) + "\n</svg>\n")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run", type=pathlib.Path)
    parser.add_argument("start", type=float)
    parser.add_argument("stop", type=float)
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument("--note", action="append", default=[], help="card:<id>=<title> or quiet:<sentence>=<title>")
    parser.add_argument("--title", default="a recorded run", help="what the run is, for the timeline's header")
    parser.add_argument("--cards", default="", help="card ids for cards.svg, comma-separated; default: the newest card of the last three blocks")
    options = parser.parse_args()
    TITLE = options.title
    notes = []
    for note in options.note:
        what, title = note.split("=", 1)
        kind, key = what.split(":")
        notes.append((kind, int(key), title))
    data = read(options.run)
    options.out.mkdir(parents=True, exist_ok=True)
    (options.out / "timeline.svg").write_text(timeline(options.run, data, options.start, options.stop, notes))
    chosen = [int(c) for c in options.cards.split(",") if c.strip()]
    (options.out / "cards.svg").write_text(table(data, options.start, options.stop, chosen))
    print(f"wrote {options.out / 'timeline.svg'} and {options.out / 'cards.svg'}")
