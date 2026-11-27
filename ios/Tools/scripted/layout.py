#!/usr/bin/env python3
"""Lays a recorded run out as one page: every sentence, every decision of the scheduler,
every request with its route and its result, what the harness held back, and every card
by block, on one time axis. Writes timeline.html into the run's folder.

Usage: layout.py <run folder> [--open]
"""
import collections
import html
import json
import pathlib
import subprocess
import sys

run = pathlib.Path(sys.argv[1])
events = [json.loads(l) for l in (run / "events.jsonl").read_text().splitlines() if l.strip()]
meta = json.loads((run / "run.json").read_text()) if (run / "run.json").exists() else {}

offset, sentences, length = None, {}, 0.0
rounds, requests, gates, started, text, landed, replaces = [], [], [], [], {}, {}, {}
open_requests = []
HELD = ["said this before", "already covers", "nothing new", "later moment", "same as the card", "already on the table", "nothing to add"]
for e in events:
    t = e.get("t", 0.0)
    length = max(length, t)
    k = e["kind"]
    if k == "sentence":
        end = e["end_ms"] / 1000
        if offset is None:
            offset = t - end
        sentences[e["id"]] = dict(start=offset + e["start_ms"] / 1000, end=offset + end, text=e["text"], voice=e.get("voice"))
    elif k == "round":
        rounds.append(dict(at=t, sentence=e["sentence"], text=e["state"]))
        if e["state"].startswith(("starts", "takes")):
            for r in [r for r in open_requests if "draft" in r["agent"]]:
                r["end"], r["result"] = t, "given up: a newer moment took its place"
                open_requests.remove(r)
    elif k == "request":
        r = dict(agent=e["agent"], model=e["model"], route=e.get("route", ""), sentence=e["sentence"], start=t, end=None, result="open")
        requests.append(r)
        open_requests.append(r)
    elif k == "layer" and e["name"][:1] in "345":
        detail = e["detail"]
        if detail.startswith("first lines"):
            continue
        if any(h in detail for h in HELD):
            gates.append(dict(at=t, sentence=e["sentence"], text=detail))
        agent = "web" if e["name"][0] == "5" else "merge" if e["name"][0] == "4" else "draft"
        model = e["name"][4:]
        match = next((r for r in open_requests if r["sentence"] == e["sentence"] and agent in r["agent"] and (agent != "draft" or r["model"] == model)), None)
        if match:
            match["end"], match["result"] = t, detail
            open_requests.remove(match)
        else:
            requests.append(dict(agent=agent, model=model, route="", sentence=e["sentence"], start=t - (e.get("seconds") or 0), end=t, result=detail))
    elif k == "card_started":
        started.append(dict(id=e["card"], at=t, deep=e["layer"] == "deep", sentence=e["sentence"]))
    elif k == "card_text":
        text[e["card"]] = text.get(e["card"], "") + e["text"]
    elif k == "card_replaced":
        replaces[e["by"]] = e["card"]
    elif k == "landed":
        landed[e["card"]] = e
length += 3

def root(card):
    while card in replaces:
        card = replaces[card]
    return card
def tag(card):
    value, out = (card * 2654435761) % 60466176, ""
    for _ in range(5):
        out += "0123456789abcdefghijklmnopqrstuvwxyz"[value % 36]
        value //= 36
    return "@" + out

blocks = []
for c in started:
    c["block"] = landed.get(c["id"], {}).get("block", root(c["id"]))
    if c["block"] not in blocks:
        blocks.append(c["block"])
versions = collections.Counter()
for c in sorted(started, key=lambda c: c["at"]):
    versions[c["block"]] += 1
    c["version"] = landed.get(c["id"], {}).get("version", versions[c["block"]])
    c["how"] = landed.get(c["id"], {}).get("how", "")

SCALE = max(9.0, min(22.0, 2600 / max(length, 1)))   # px per second: the whole run on one wide page
ROW, PAD = 22, 4
def x(t): return round(t * SCALE, 1)
def esc(s): return html.escape(str(s), quote=True)

items = []   # (lane, start, end or None, label, colour, filled, title, body)
for i, s in sorted(sentences.items()):
    items.append(("Heard", s["start"], s["end"], f"#{i} {s['text']}", "#8e8e93", True,
                  f"Heard · sentence #{i}" + (f" · voice {s['voice']}" if s["voice"] is not None else ""), s["text"]))
for r in rounds:
    held = "waits" in r["text"] or "held back" in r["text"]
    items.append(("Scheduler", r["at"], None, f"#{r['sentence']} {r['text']}", "#ff9f0a" if held else "#0a84ff", not held,
                  f"Scheduler · sentence #{r['sentence']} at {r['at']:.1f} s", r["text"]))
for r in requests:
    end = r["end"] if r["end"] is not None else length
    quiet, given = "nothing to show" in r["result"], r["result"].startswith("given up")
    colour = "#ff9f0a" if r["end"] is None else "#ff453a" if given else "#8e8e93" if quiet else "#40c8e0" if r["agent"] == "web" else "#bf5af2"
    route = f"{r['route']} · " if r["route"] else ""
    took = "open" if r["end"] is None else f"{end - r['start']:.1f} s"
    items.append(("Requests", r["start"], end, f"{r['agent']} → {route}{r['model']} · {took}", colour, not (quiet or given),
                  f"Request · {r['agent']} → {route}{r['model']} · for sentence #{r['sentence']}",
                  f"Out at {r['start']:.1f} s, " + ("still open." if r["end"] is None else f"back after {took}.") + f"\nResult: {r['result']}"))
for g in gates:
    items.append(("Harness", g["at"], None, f"#{g['sentence']} held back: {g['text']}", "#ffd60a", False,
                  f"Harness · a reply for sentence #{g['sentence']} was not shown", g["text"]))
for c in started:
    body = text.get(c["id"], "")
    first = body.split("\n")[0].replace("**", "") if body else ""
    verb = "created" if c["version"] == 1 else f"updated to v{c['version']}"
    items.append((f"Block {tag(c['block'])}", c["at"], None, f"{verb}{' ✓' if c['deep'] else ''} · {first}", "#30d158" if c["deep"] else "#5e5ce6", True,
                  f"Card {tag(c['id'])} · block {tag(c['block'])} · version {c['version']} · {'checked' if c['deep'] else 'draft'} · for sentence #{c['sentence']}",
                  f"Landed as: {c['how']}\n\n{body}"))

def width(item):
    label = len(item[3]) * 6.0 + 14
    lasting = x(item[2] - item[1]) - 2 if item[2] is not None else 0
    return max(lasting, min(label, 330))

lane_names = ["Heard", "Scheduler", "Requests", "Harness"] + [f"Block {tag(b)}" for b in blocks]
notes = {"Heard": "what the listening stages wrote", "Scheduler": "when a round starts or waits",
         "Requests": "every call to a model, out and back", "Harness": "replies it held back, and why"}
svg, labels, y = [], [], 46
total_width = x(length) + 360
# load
load = [sum(1 for r in requests if r["start"] < s + 1 and (r["end"] if r["end"] is not None else length) > s) for s in range(int(length) + 1)]
most = max(load + [1])
for s, n in enumerate(load):
    if n:
        heat = n / most
        svg.append(f'<rect x="{x(s)}" y="26" width="{SCALE - 1:.1f}" height="12" fill="hsl({48 - 48 * heat:.0f} 90% 55%)" opacity="{0.35 + 0.65 * heat:.2f}"><title>{n} requests open in second {s}</title></rect>')
labels.append(f'<div class="lane" style="top:22px;height:20px"><b>Load</b></div>')
for name in lane_names:
    lane = sorted([i for i in items if i[0] == name], key=lambda i: i[1])
    ends = []
    placed = []
    for item in lane:
        start = x(item[1])
        row = next((r for r, e in enumerate(ends) if e + 4 <= start), len(ends))
        if row == len(ends):
            ends.append(0)
        ends[row] = start + width(item)
        placed.append((row, item))
    height = max(1, len(ends)) * (ROW + PAD) + 10
    svg.append(f'<line x1="0" x2="{total_width}" y1="{y}" y2="{y}" stroke="#ffffff" stroke-opacity="0.08"/>')
    labels.append(f'<div class="lane" style="top:{y + 4}px;height:{height}px"><b>{esc(name)}</b><span>{esc(notes.get(name, "its versions, as they arrived"))}</span></div>')
    for row, item in placed:
        _, start, end, label, colour, filled, title, body = item
        w = width(item)
        chars = max(3, int((w - 12) / 6.0))
        shown = label if len(label) <= chars else label[: chars - 1] + "…"
        top = y + 6 + row * (ROW + PAD)
        svg.append(f'<g class="ev" data-title="{esc(title)}" data-body="{esc(body)}">'
                   f'<rect x="{x(start)}" y="{top}" width="{w:.1f}" height="{ROW}" rx="5" fill="{colour}" fill-opacity="{0.30 if filled else 0.08}" stroke="{colour}" stroke-opacity="0.85"/>'
                   f'<text x="{x(start) + 6}" y="{top + 15}">{esc(shown)}</text></g>')
    y += height
ticks = "".join(f'<line x1="{x(s)}" x2="{x(s)}" y1="18" y2="{y}" stroke="#fff" stroke-opacity="0.06"/><text class="tick" x="{x(s) + 3}" y="14">{s // 60}:{s % 60:02d}</text>'
                for s in range(0, int(length) + 1, 5 if SCALE > 12 else 10))
said_nothing = sum("nothing to show" in r["result"] for r in requests)
page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>{esc(run.name)} · pipeline</title>
<style>
body{{margin:0;background:#141416;color:#f2f2f7;font:13px -apple-system,system-ui,sans-serif}}
header{{display:flex;gap:26px;align-items:baseline;padding:16px 20px;border-bottom:1px solid #2c2c2e;flex-wrap:wrap}}
header h1{{font-size:16px;margin:0 12px 0 0}} header b{{font-size:20px;display:block}} header span{{color:#98989f;font-size:11px}}
.wrap{{display:flex}} .names{{width:150px;flex:none;position:relative;border-right:1px solid #2c2c2e}}
.lane{{position:absolute;left:14px;right:8px;overflow:hidden}} .lane b{{display:block;font-size:12px}} .lane span{{color:#98989f;font-size:10px}}
.scroll{{overflow-x:auto;flex:1}} svg text{{fill:#f2f2f7;font-size:10.5px;font-weight:500;pointer-events:none}} svg text.tick{{fill:#98989f;font-weight:400}}
.ev{{cursor:pointer}} .ev:hover rect{{stroke:#fff;stroke-opacity:1}} .ev.on rect{{stroke:#fff;stroke-width:2;stroke-opacity:1}}
#detail{{position:sticky;bottom:0;background:#1f1f22;border-top:1px solid #2c2c2e;padding:14px 20px;min-height:120px;max-height:38vh;overflow:auto}}
#detail h2{{font-size:13px;margin:0 0 6px}} #detail pre{{margin:0;white-space:pre-wrap;font:12px ui-monospace,Menlo,monospace;color:#d1d1d6}}
.legend{{display:flex;gap:16px;padding:8px 20px;color:#98989f;font-size:11px;flex-wrap:wrap}} .legend i{{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:5px;vertical-align:-1px}}
</style></head><body>
<header><h1>{esc(run.name)}<span> · topic {esc(meta.get("topic", "–"))} · {meta.get("audio_seconds", 0):.0f} s of sound</span></h1>
<div><b>{len(sentences)}</b><span>sentences</span></div><div><b>{len(requests)}</b><span>requests</span></div>
<div><b>{said_nothing}</b><span>said nothing</span></div><div><b>{len(gates)}</b><span>held back</span></div>
<div><b>{len(started)}</b><span>card events</span></div><div><b>{len(blocks)}</b><span>blocks</span></div></header>
<div class="legend"><span><i style="background:#8e8e93"></i>heard · a request that said nothing</span><span><i style="background:#0a84ff"></i>round starts</span><span><i style="background:#ff9f0a"></i>waits · open</span>
<span><i style="background:#bf5af2"></i>draft request</span><span><i style="background:#40c8e0"></i>web request</span><span><i style="background:#ff453a"></i>given up</span>
<span><i style="background:#ffd60a"></i>held back by the harness</span><span><i style="background:#5e5ce6"></i>draft card</span><span><i style="background:#30d158"></i>checked card ✓</span></div>
<div class="wrap"><div class="names" style="height:{y + 10}px">{''.join(labels)}</div>
<div class="scroll"><svg width="{total_width}" height="{y + 10}" role="img" aria-label="Timeline of the run">{ticks}{''.join(svg)}</svg></div></div>
<div id="detail"><h2>Point at an event to read it; click to keep it open.</h2><pre></pre></div>
<script>
const panel = document.getElementById('detail'); let pinned = null;
function show(g) {{ panel.querySelector('h2').textContent = g.dataset.title; panel.querySelector('pre').textContent = g.dataset.body; }}
document.querySelectorAll('.ev').forEach(g => {{
  g.addEventListener('mouseenter', () => show(g));
  g.addEventListener('mouseleave', () => {{ if (pinned) show(pinned); }});
  g.addEventListener('click', () => {{ if (pinned) pinned.classList.remove('on'); pinned = pinned === g ? null : g; if (pinned) {{ g.classList.add('on'); show(g); }} }});
}});
</script></body></html>"""
out = run / "timeline.html"
out.write_text(page)
print(out)
if "--open" in sys.argv:
    subprocess.run(["open", str(out)])
