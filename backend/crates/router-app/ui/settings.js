// The Topics and Settings tabs. Everything shown from outside is set as text, never as HTML.
"use strict";

(function () {
  const call = window.__TAURI__ ? window.__TAURI__.core.invoke : null;
  const $ = (id) => document.getElementById(id);
  const make = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  // Tabs
  const tabs = document.querySelectorAll("[data-tab]");
  function select(name) {
    for (const tab of tabs) tab.setAttribute("aria-selected", String(tab.dataset.tab === name));
    for (const pane of document.querySelectorAll(".pane")) pane.hidden = pane.id !== "pane-" + name;
    if (name === "topics") loadTopics();
    if (name === "settings") loadSettings();
  }
  for (const tab of tabs) tab.addEventListener("click", () => select(tab.dataset.tab));

  // Topics
  function when(seconds) {
    if (!seconds) return "never";
    return new Date(seconds * 1000).toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
  }

  async function loadTopics() {
    const list = $("topics");
    const topics = call ? await call("topics") : [];
    list.replaceChildren();
    if (!topics.length) list.append(make("li", "muted", "No topics yet. They appear when an app opens a session."));
    for (const t of topics) {
      const li = make("li", "topic");
      const head = make("div", "row");
      const actions = make("span", "actions");
      head.append(make("span", "name", t.id), actions);
      if (t.ownFolder) actions.append(make("span", "badge warn", "own folder"));
      const open = make("button", "", "Open");
      open.type = "button";
      open.addEventListener("click", () => call("open_folder", { which: "topic:" + t.id }));
      const own = make("button", "", t.ownFolder ? "Use router folder" : "Own folder…");
      own.type = "button";
      own.title = t.ownFolder
        ? "Sessions of this topic work in the router's topics folder again."
        : "Sessions of this topic work in a folder you choose, for example a project folder.";
      own.addEventListener("click", async () => {
        const settings = await call("settings");
        if (t.ownFolder) {
          delete settings.topicFolders[t.id];
        } else {
          const path = await call("choose_folder");
          if (!path) return;
          settings.topicFolders[t.id] = path;
        }
        loaded = settings;
        await save(settings, false);
        const note = $("settings-note").textContent;
        if (note.startsWith("Not saved")) alert(note);
        loadTopics();
      });
      actions.append(own, open);
      li.append(head, make("div", "path muted", t.folder));
      const sessions = make("ul", "sessions");
      if (!t.sessions.length) sessions.append(make("li", "muted", "no sessions"));
      for (const s of t.sessions) {
        const row = make("li");
        row.append(
          make("span", "who", s.role),
          make("span", "model", s.model),
          make("span", "used muted", "used " + when(s.lastUsed || s.createdAt)),
          make("span", s.running ? "badge ok" : "badge off", s.running ? "running" : "resting"),
        );
        sessions.append(row);
      }
      li.append(sessions);
      list.append(li);
    }
  }

  // Settings
  let loaded = null;
  const levels = [
    ["folder", "Folder only: files in the topic's folder and web search"],
    ["commands", "Folder and commands: may also run commands there"],
    ["computer", "Home folder and commands: files anywhere in your home folder"],
  ];

  function toolForm(box, name, tool) {
    box.replaceChildren();
    const head = make("label", "check");
    const on = make("input");
    on.type = "checkbox";
    on.checked = tool.enabled;
    on.dataset.k = "enabled";
    head.append(on, document.createTextNode(" " + name));
    const path = make("label", "field");
    path.append(make("span", "", "Program"));
    const pathInput = make("input");
    pathInput.value = tool.path || "";
    pathInput.placeholder = name + " on the PATH";
    pathInput.dataset.k = "path";
    path.append(pathInput);
    const model = make("label", "field");
    model.append(make("span", "", "Model when the app names none"));
    const modelInput = make("input");
    modelInput.value = tool.model || "";
    modelInput.placeholder = name === "claude" ? "sonnet" : "the CLI's default";
    modelInput.dataset.k = "model";
    model.append(modelInput);
    const access = make("fieldset", "levels");
    access.append(make("legend", "", "What its sessions may do"));
    for (const [value, text] of levels) {
      const label = make("label", "check");
      const radio = make("input");
      radio.type = "radio";
      radio.name = "access-" + name;
      radio.value = value;
      radio.checked = tool.access === value;
      radio.dataset.k = "access";
      label.append(radio, document.createTextNode(" " + text));
      access.append(label);
    }
    box.append(head, path, model, access);
    box.classList.toggle("off", !tool.enabled);
    on.addEventListener("change", () => box.classList.toggle("off", !on.checked));
    if (name === "codex") {
      box.append(make("small", "muted", "codex runs in its own sandbox modes. On Windows that sandbox can read every file you can read."));
    }
  }

  function readTool(box, before) {
    const tool = { ...before };
    for (const input of box.querySelectorAll("[data-k]")) {
      const k = input.dataset.k;
      if (input.type === "checkbox") tool[k] = input.checked;
      else if (input.type === "radio") { if (input.checked) tool[k] = input.value; }
      else tool[k] = input.value.trim() || (k === "path" ? null : "");
    }
    return tool;
  }

  function fill(s) {
    $("s-folder").value = s.folder;
    $("s-topics-root").value = s.topicsRoot || "";
    $("s-per-topic").value = s.limits.sessions_per_topic;
    $("s-total").value = s.limits.sessions_total;
    $("s-idle").value = s.limits.idle_seconds;
    $("s-silence").value = s.limits.silence_seconds;
    $("s-port").value = s.port;
    $("s-bonjour").checked = s.bonjour;
    $("s-autostart").checked = s.autostart;
    toolForm(document.querySelector('[data-tool="claude"]'), "claude", s.claude);
    toolForm(document.querySelector('[data-tool="codex"]'), "codex", s.codex);
  }

  function read() {
    const number = (id) => Number($(id).value);
    return {
      ...loaded,
      topicsRoot: $("s-topics-root").value.trim() || null,
      limits: {
        sessions_per_topic: number("s-per-topic"),
        sessions_total: number("s-total"),
        idle_seconds: number("s-idle"),
        silence_seconds: number("s-silence"),
      },
      port: number("s-port"),
      bonjour: $("s-bonjour").checked,
      autostart: $("s-autostart").checked,
      claude: readTool(document.querySelector('[data-tool="claude"]'), loaded.claude),
      codex: readTool(document.querySelector('[data-tool="codex"]'), loaded.codex),
    };
  }

  async function loadSettings() {
    if (!call) return;
    try {
      loaded = await call("settings");
      fill(loaded);
      $("settings-note").textContent = "";
    } catch (e) {
      $("settings-note").textContent = String(e);
    }
  }

  function ask(warnings) {
    return new Promise((resolve) => {
      const dialog = $("confirm");
      const list = $("confirm-list");
      list.replaceChildren(...warnings.map((w) => make("li", "", w)));
      const done = (answer) => { dialog.close(); resolve(answer); };
      $("confirm-yes").onclick = () => done(true);
      $("confirm-no").onclick = () => done(false);
      dialog.showModal();
    });
  }

  async function save(settings, confirmed) {
    try {
      const saved = await call("save_settings", { settings, confirmed });
      $("settings-note").classList.remove("failed");
      $("settings-note").textContent = saved.restartNeeded
        ? "Saved. Port and Bonjour change when the router starts again."
        : "Saved. New sessions follow it; running ones keep what they had.";
      if (saved.autostartError) $("settings-note").textContent += " Starting with the system: " + saved.autostartError;
      loaded = await call("settings");
      fill(loaded);
    } catch (error) {
      $("settings-note").classList.toggle("failed", !(error && error.kind === "needsConfirmation"));
      if (error && error.kind === "needsConfirmation") {
        if (await ask(error.detail)) return save(settings, true);
        $("settings-note").textContent = "Not saved.";
      } else {
        $("settings-note").textContent = "Not saved: " + (error && error.detail ? error.detail : String(error));
      }
    }
  }

  $("settings-form").addEventListener("submit", (event) => {
    event.preventDefault();
    if (loaded) save(read(), false);
  });
  $("settings-reset").addEventListener("click", () => loaded && fill(loaded));
  for (const button of document.querySelectorAll("[data-choose]")) {
    button.addEventListener("click", async () => {
      const path = await call("choose_folder");
      if (path) $(button.dataset.choose).value = path;
    });
  }
  for (const button of document.querySelectorAll("[data-open]")) {
    button.addEventListener("click", () => call("open_folder", { which: button.dataset.open }));
  }
})();
