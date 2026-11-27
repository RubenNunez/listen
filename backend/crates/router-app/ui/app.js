// The router's window: asks the Rust side for its state once a second and shows it.
// Everything that comes from outside (device names, activity) is set as text, never as HTML.
"use strict";

const invoke = window.__TAURI__ ? window.__TAURI__.core.invoke : null;
const $ = (id) => document.getElementById(id);

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function clock(millis) {
  return new Date(millis).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
}

function day(seconds) {
  return new Date(seconds * 1000).toLocaleDateString([], { day: "numeric", month: "short" });
}

function sentence(text) {
  if (!text) return "";
  return text.charAt(0).toUpperCase() + text.slice(1) + (/[.?!]$/.test(text) ? "" : ".");
}

let shownLink = null;
let shownPhase = null;
let lastActivity = 0;

// The pairing code renews itself (pairing.rs). A new code fades in over the old one; the box
// never changes size, and the line under it runs out as the next renewal comes closer.
function showCode(svg) {
  const box = $("qr");
  const layer = el("div", "qr-layer");
  // The SVG is made by the router itself from its own link.
  layer.innerHTML = svg;
  for (const old of box.children) {
    old.classList.remove("on");
    setTimeout(() => old.remove(), 500);
  }
  box.append(layer);
  // The first code of a run is simply there; later ones fade in.
  if (box.children.length === 1) layer.classList.add("on");
  else requestAnimationFrame(() => requestAnimationFrame(() => layer.classList.add("on")));
}

function renderPairing(pairing) {
  const phase = pairing.phase;
  $("qr-box").dataset.phase = phase;
  if (phase === "code") {
    if (pairing.link !== shownLink) {
      showCode(pairing.qrSvg);
      const bar = $("timer").firstElementChild;
      // Back to full at once, then it runs down smoothly from poll to poll.
      bar.classList.add("jump");
      bar.style.width = "100%";
      requestAnimationFrame(() => requestAnimationFrame(() => bar.classList.remove("jump")));
      shownLink = pairing.link;
    } else {
      $("timer").firstElementChild.style.width = `${Math.max(0, (pairing.secondsLeft - 1) / pairing.period) * 100}%`;
    }
  } else if (shownLink !== null) {
    $("qr").replaceChildren();
    shownLink = null;
  }
  $("qr").setAttribute("aria-hidden", String(phase !== "code"));
  $("show-code").textContent = phase === "paired" ? "Pair another" : "Show a new code";
  $("copy").disabled = phase !== "code";
  const left = $("left");
  left.classList.toggle("warn-text", phase === "locked");
  const text = {
    code: `The code renews itself every ${pairing.period} seconds.`,
    idle: "No device paired for a few minutes, so the code was taken down.",
    paired: `Paired with “${pairing.device || "device"}”.`,
    locked: "Taken down after five wrong codes. If that was not you, something in your network tried to pair.",
    none: "",
  }[phase] || "";
  if (left.textContent !== text) left.textContent = text;
  // A pairing is worth the orb's attention; a renewal every half minute is not.
  if (phase === "paired" && shownPhase !== null && shownPhase !== "paired") window.Orb.wake();
  shownPhase = phase;
}

function toolBadge(t) {
  if (!t.found) return t.enabled ? el("span", "badge bad", "not found") : el("span", "badge off", "not installed");
  if (!t.enabled) return el("span", "badge off", "off");
  if (t.signedIn === "yes") return el("span", "badge ok", "signed in");
  if (t.signedIn === "no") return el("span", "badge warn", "signed out");
  return el("span", "badge ok", "on");
}

function render(s) {
  window.Orb.set({ ready: !!s.ready, answering: !!s.answering });

  const status = $("status");
  status.className = "status " + (s.ready ? "ready" : "not-ready");
  $("status-text").textContent = s.startFailed ? "Not running"
    : s.ready ? (s.answering ? "Ready · answering" : "Ready") : "Not ready";
  $("problem").hidden = !s.problem;
  $("problem").textContent = sentence(s.problem || "")
    + (s.startFailed ? " Quit Listen Router from its tray icon, fix this, and start it again." : "");

  // A router that did not start has nothing to pair with and knows no tools.
  const pairing = s.pairing;
  $("pair-section").hidden = !pairing;
  for (const id of ["devices-section", "tools-section", "activity-section"]) $(id).hidden = !!s.startFailed;
  if (pairing) renderPairing(pairing);
  $("fingerprint-row").hidden = !s.fingerprint;
  // In groups of four, easier to compare with what the app shows.
  $("fingerprint").textContent = (s.fingerprint || "").replace(/(.{4})(?=.)/g, "$1 ");

  // Devices
  const devices = $("devices");
  devices.replaceChildren();
  if (!s.devices.length) devices.append(el("li", "muted", "No device is paired yet."));
  for (const d of s.devices) {
    const li = el("li");
    const name = el("span", "name", d.name || "device");
    name.title = d.name || "";
    li.append(name, el("span", "what", "since " + day(d.pairedAt)));
    const remove = el("button", "", "Remove");
    remove.type = "button";
    remove.addEventListener("click", async () => {
      if (!confirm(`Remove "${d.name}"? It can no longer use this router until it pairs again.`)) return;
      render(await invoke("remove_device", { id: d.id }));
    });
    li.append(remove);
    devices.append(li);
  }

  // Tools
  const tools = $("tools");
  tools.replaceChildren();
  for (const t of s.tools) {
    const li = el("li", "tool-row");
    const head = el("div", "tool-head");
    head.append(el("span", "name", t.name), el("span", "what", t.found ? (t.version || "found") : ""), toolBadge(t));
    li.append(head);
    if (t.hint) li.append(el("span", "hint", t.hint));
    tools.append(li);
  }

  // Activity
  const sessions = s.sessions || [];
  const running = sessions.filter((x) => x.running).length;
  $("sessions-count").textContent = sessions.length
    ? `${sessions.length} session${sessions.length === 1 ? "" : "s"}, ${running} running`
    : "no sessions";
  const newest = s.activity.length ? s.activity[s.activity.length - 1].atMillis : 0;
  if (newest !== lastActivity || !$("activity").children.length) {
    lastActivity = newest;
    const list = $("activity");
    list.replaceChildren();
    for (const e of s.activity.slice(-80).reverse()) {
      const li = el("li");
      const who = e.topic ? `${e.topic} · ${e.role}` : "router";
      const kind = e.kind.replaceAll("_", " ");
      const extra = [e.detail, e.millis != null ? (e.millis / 1000).toFixed(1) + " s" : ""].filter(Boolean).join("  ");
      li.title = [who, kind, extra].filter(Boolean).join("  ");
      li.append(el("span", "time", clock(e.atMillis)), el("span", "who", who), el("span", "kind", kind), el("span", "extra muted", extra));
      list.append(li);
    }
    if (!s.activity.length) list.append(el("li", "muted", "Nothing has happened since the router started."));
  }

  // Facts about this router, one per line.
  const footer = $("footer");
  const facts = [`Version ${s.version}`];
  if (s.port) facts[0] += ` · port ${s.port}`;
  if (s.bonjour && s.bonjour.announced) facts[0] += ` · announced by Bonjour as “${s.bonjour.name}”`;
  facts.push(`Folder ${s.folder}`);
  const lines = facts.map((fact) => el("div", "", fact));
  if (s.bonjour && s.bonjour.error) lines.push(el("div", "warn-text", `Not announced by Bonjour: ${s.bonjour.error}. A Mac will not find this router by itself.`));
  footer.replaceChildren(...lines);
}

async function refresh() {
  if (!invoke) return;
  try {
    render(await invoke("state"));
  } catch (error) {
    $("status").className = "status not-ready";
    $("status-text").textContent = "No answer from the router";
    console.error(error);
  }
}

$("show-code").addEventListener("click", async () => {
  render(await invoke("show_code"));
  window.Orb.wake();
});
$("copy").addEventListener("click", async () => {
  if (!shownLink) return;
  try {
    await navigator.clipboard.writeText(shownLink);
    $("copy").textContent = "Copied";
    setTimeout(() => ($("copy").textContent = "Copy link"), 1500);
    // The copied code stays a full period longer: time to paste it into Listen.
    render(await invoke("keep_code"));
  } catch (e) {
    console.error(e);
  }
});

window.Orb.start($("orb"));
refresh();
setInterval(refresh, 1000);
