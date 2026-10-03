// AgentMaster web UI. Talks to agentmaster-server's /api (see WebServer.swift). No build step.
"use strict";

const THEME = {
  background: "#1e1e22", foreground: "#ccd3db", cursor: "#ccd3db", selectionBackground: "#263854",
  black: "#2a2a30", red: "#f38ba8", green: "#a6e3a1", yellow: "#ffe14a", blue: "#5aa0ff", magenta: "#c5a3ff",
  cyan: "#8abeb7", white: "#ccd3db", brightBlack: "#676c74", brightRed: "#ff9eb8", brightGreen: "#b5e8b0",
  brightYellow: "#fff08a", brightBlue: "#8cbcff", brightMagenta: "#d7bfff", brightCyan: "#a8d8d2", brightWhite: "#ffffff",
};
const STATUS = {
  starting: ["◈", "#676c74"], running: ["◈", "#8abeb7"], needsAttention: ["◆", "#5aa0ff"],
  idle: ["◇", "#8a9098"], ended: ["✓", "#a6e3a1"],
};
const TODO = { completed: ["✓", "#a6e3a1"], in_progress: ["◆", "#8abeb7"], pending: ["◇", "#8a9098"] };
const CUSTOM = "\u0000custom";

const $ = (id) => document.getElementById(id);
const el = (tag, props = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === "class") node.className = value;
    else if (key === "style") node.style.cssText = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else if (value !== undefined && value !== null && value !== false) node.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children.flat()) if (child !== null && child !== undefined) node.append(child);
  return node;
};

const state = {
  token: null,
  sessions: new Map(),        // id -> SessionJSON
  selectedId: localStorage.getItem("am.selected"),
  collapsedGroups: new Set(),
  agents: [],                 // AgentJSON[]
  restoreSessionsOnLaunch: true,
  home: "/",
  terminals: new Map(),       // id -> { term, fit, socket, node, alive }
  renaming: null,
  events: null,
};

// MARK: token and API

function readToken() {
  const match = location.hash.match(/token=([^&]+)/);
  if (match) {
    localStorage.setItem("am.token", decodeURIComponent(match[1]));
    history.replaceState(null, "", location.pathname + location.search);
  }
  return localStorage.getItem("am.token");
}

async function api(method, path, body) {
  const response = await fetch(path, {
    method,
    headers: { Authorization: "Bearer " + state.token, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (response.status === 401) {
    showLogin("The token was not accepted.");
    throw new Error("unauthorized");
  }
  if (!response.ok) {
    let message = await response.text();
    try { message = JSON.parse(message).error?.message ?? message; } catch {}
    throw new Error(message || response.statusText);
  }
  return response.status === 204 ? null : response.json();
}

function wsURL(path) {
  const url = new URL(path, location.href);
  url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
  url.searchParams.set("token", state.token);
  return url.toString();
}

function showLogin(message) {
  $("app").hidden = true;
  $("login").hidden = false;
  $("login-error").hidden = !message;
  $("login-error").textContent = message ?? "";
  state.events?.close();
}

$("login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const token = $("login-token").value.trim();
  if (!token) return;
  localStorage.setItem("am.token", token);
  await start();
});

async function start() {
  state.token = readToken();
  if (!state.token) return showLogin();
  try {
    await loadAgents();
  } catch (error) {
    if (error.message !== "unauthorized") showLogin("Could not reach the server: " + error.message);
    return;
  }
  $("login").hidden = true;
  $("app").hidden = false;
  if (localStorage.getItem("am.inspectorCollapsed") === "true") $("inspector").classList.add("collapsed");
  connectEvents();
}

async function loadAgents() {
  const response = await api("GET", "/api/agents");
  state.agents = response.agents;
  state.restoreSessionsOnLaunch = response.restoreSessionsOnLaunch;
  state.home = response.home;
}

// MARK: live session list

function connectEvents(delay = 500) {
  const socket = new WebSocket(wsURL("/api/events"));
  state.events = socket;
  socket.onopen = () => { $("connection").hidden = true; delay = 500; };
  socket.onmessage = (message) => {
    const event = JSON.parse(message.data);
    if (event.type === "snapshot") {
      state.sessions = new Map(event.sessions.map((s) => [s.id, s]));
      for (const id of [...state.terminals.keys()]) if (!state.sessions.has(id)) disposeTerminal(id);
    } else if (event.type === "session") {
      state.sessions.set(event.session.id, event.session);
    } else if (event.type === "removed") {
      state.sessions.delete(event.id);
      disposeTerminal(event.id);
      if (state.selectedId === event.id) state.selectedId = null;
    }
    render();
  };
  socket.onclose = () => {
    if (state.events !== socket || $("app").hidden) return;
    $("connection").hidden = false;
    setTimeout(() => connectEvents(Math.min(delay * 2, 8000)), delay);
  };
}

/// A session the POST just created. The event stream is the source of truth and may already carry a newer
/// state (a fast agent reports its first hook before the POST response arrives), so never overwrite it.
function adopt(session) {
  if (!state.sessions.has(session.id)) state.sessions.set(session.id, session);
}

function sortedSessions() {
  return [...state.sessions.values()].sort((a, b) => b.createdAt - a.createdAt);
}

function groups() {
  const byPath = new Map();
  for (const session of sortedSessions()) {
    if (!byPath.has(session.projectPath)) byPath.set(session.projectPath, []);
    byPath.get(session.projectPath).push(session);
  }
  return [...byPath.entries()].map(([path, rows]) => ({ path, name: rows[0].projectName, rows }));
}

function selected() {
  return state.sessions.get(state.selectedId) ?? null;
}

function select(id) {
  state.selectedId = id;
  if (id) localStorage.setItem("am.selected", id);
  render();
}

// MARK: render

function render() {
  if (!selected() && state.sessions.size > 0) state.selectedId = sortedSessions()[0].id;
  renderSidebar();
  renderMain();
  renderInspector();
}

function renderSidebar() {
  const container = $("groups");
  container.replaceChildren(...groups().map((group) => {
    const collapsed = state.collapsedGroups.has(group.path);
    const header = el("div", { class: "group-header", title: group.path,
                               onclick: () => { collapsed ? state.collapsedGroups.delete(group.path) : state.collapsedGroups.add(group.path); render(); } },
      el("span", { class: "caret" }, collapsed ? "▸" : "▾"),
      el("span", { class: "name" }, group.name),
      el("span", { class: "count" }, String(group.rows.length)),
      el("button", { class: "add", title: `New session in ${group.name}`,
                     onclick: (event) => { event.stopPropagation(); openNewSession(group.path); } }, "＋"));
    const rows = collapsed ? null : el("div", { class: "rows" }, group.rows.map(sessionRow));
    return el("div", { class: "group" }, header, rows);
  }));
}

function sessionRow(session) {
  const [glyph, color] = STATUS[session.status] ?? STATUS.idle;
  const editing = state.renaming === session.id;
  let title;
  if (editing) {
    title = el("input", { value: session.title, onclick: (e) => e.stopPropagation(),
      onkeydown: (e) => {
        if (e.key === "Enter") commitRename(session, e.target.value);
        if (e.key === "Escape") { state.renaming = null; render(); }
      },
      onblur: (e) => commitRename(session, e.target.value) });
    queueMicrotask(() => { title.focus(); title.select(); });
  } else {
    title = el("div", { class: "title" }, session.title);
  }
  return el("div", { class: "row-item" + (session.id === state.selectedId ? " selected" : ""),
                     onclick: () => select(session.id),
                     ondblclick: () => { state.renaming = session.id; render(); } },
    el("span", { class: "glyph", style: `color:${color}` }, glyph),
    el("div", { class: "texts" }, title, session.subtitle ? el("div", { class: "subtitle" }, session.subtitle) : null),
    el("button", { class: "close", title: "Close session", onclick: (e) => { e.stopPropagation(); closeSession(session); } }, "×"));
}

async function commitRename(session, value) {
  if (state.renaming !== session.id) return;
  state.renaming = null;
  if (value.trim() !== session.title.trim()) {
    try { await api("PATCH", `/api/sessions/${session.id}`, { name: value }); } catch (error) { alert(error.message); }
  }
  render();
}

async function closeSession(session) {
  if ((session.status === "running" || session.status === "needsAttention") &&
      !confirm(`Close “${session.title}”?\n\n${session.agentName} is still working in ${session.projectName}. ` +
               "The transcript is kept, so the conversation can be resumed later.")) return;
  try { await api("DELETE", `/api/sessions/${session.id}`); } catch (error) { alert(error.message); }
}

function renderMain() {
  const session = selected();
  $("empty").hidden = !!session;
  $("crumb-project").textContent = session?.projectName ?? "";
  $("crumb-session").textContent = session?.title ?? "";
  document.title = session ? `${session.title} — AgentMaster` : "AgentMaster";
  $("usage").replaceChildren(...usageParts(session));
  const attention = session?.status === "needsAttention" ? session.state.attentionMessage : null;
  $("attention").hidden = !attention;
  $("attention").textContent = attention ? "◆ " + attention : "";
  for (const [id, entry] of state.terminals) entry.node.hidden = id !== session?.id;
  if (session) showTerminal(session);
}

function usageParts(session) {
  if (!session) return [];
  const usage = session.state.usage;
  const parts = [];
  if (usage?.modelName) parts.push(usage.modelName);
  if (session.state.permissionMode) parts.push(session.state.permissionMode);
  const nodes = parts.map((part) => document.createTextNode(part));
  if (usage?.contextUsedPercent !== undefined) {
    const span = el("span", { class: usage.contextUsedPercent >= 80 ? "hot" : "",
                              title: `${usage.inputTokens} in · ${usage.outputTokens} out` },
                    `ctx ${usage.contextUsedPercent}%`);
    nodes.push(span);
  }
  if (usage && usage.costUSD > 0) nodes.push(document.createTextNode("$" + usage.costUSD.toFixed(2)));
  return nodes.flatMap((node, index) => (index ? [document.createTextNode(" · "), node] : [node]));
}

// MARK: terminals

function showTerminal(session) {
  let entry = state.terminals.get(session.id);
  if (!entry) {
    const node = el("div", { class: "term-pane", onmousedown: () => requestAnimationFrame(() => entry?.term.focus()) });
    $("terminals").append(node);
    const term = new Terminal({ fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace', fontSize: 13,
                                theme: THEME, cursorBlink: true, allowProposedApi: true, scrollback: 10000,
                                macOptionIsMeta: true, macOptionClickForcesSelection: true });
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.loadAddon(new WebLinksAddon.WebLinksAddon());
    term.open(node);
    entry = { term, fit, node, socket: null, alive: true, id: session.id };
    state.terminals.set(session.id, entry);
    term.onData((data) => send(entry, { type: "input", data }));
    term.onResize(({ cols, rows }) => send(entry, { type: "resize", columns: cols, rows }));
    // The agent runs on the server and cannot see this machine's clipboard: pasted or dropped images are
    // uploaded, and their server path is pasted instead, which the agent attaches like a clipboard image.
    node.addEventListener("paste", (event) => {
      const data = event.clipboardData;
      if (!data || data.getData("text/plain")) return;
      const images = [...data.files].filter((file) => file.type.startsWith("image/"));
      if (!images.length) return;
      event.preventDefault();
      event.stopPropagation();
      pasteImages(entry, images);
    }, true);
    node.addEventListener("dragover", (event) => event.preventDefault());
    node.addEventListener("drop", (event) => {
      const images = [...(event.dataTransfer?.files ?? [])].filter((file) => file.type.startsWith("image/"));
      if (!images.length) return;
      event.preventDefault();
      pasteImages(entry, images);
    });
    new ResizeObserver(() => { if (!node.hidden) fitTerminal(entry); }).observe(node);
    connectTerminal(entry);
  }
  entry.node.hidden = false;
  fitTerminal(entry);
  // Leave focus alone while a dialog or a rename field has it.
  if (!document.querySelector("dialog[open]") && !state.renaming) entry.term.focus();
}

async function pasteImages(entry, files) {
  for (const file of files) {
    try {
      const response = await fetch(`/api/sessions/${entry.id}/images`, {
        method: "POST", headers: { Authorization: "Bearer " + state.token, "Content-Type": file.type }, body: file,
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(body.error?.message ?? response.statusText);
      entry.term.paste(body.path);
    } catch (error) {
      alert(error.message);
    }
  }
  entry.term.focus();
}

function fitTerminal(entry) {
  try { entry.fit.fit(); } catch {}
}

function send(entry, message) {
  if (entry.socket?.readyState === WebSocket.OPEN) entry.socket.send(JSON.stringify(message));
}

function connectTerminal(entry, delay = 500) {
  const socket = new WebSocket(wsURL(`/api/terminal?id=${encodeURIComponent(entry.id)}`));
  socket.binaryType = "arraybuffer";
  entry.socket = socket;
  let first = true;
  socket.onopen = () => {
    delay = 500;
    send(entry, { type: "resize", columns: entry.term.cols, rows: entry.term.rows });
  };
  socket.onmessage = (message) => {
    // The server replays the scrollback on every (re)connect, so start from a clean screen.
    if (first) { entry.term.reset(); first = false; }
    entry.term.write(new Uint8Array(message.data));
  };
  socket.onclose = () => {
    if (!entry.alive || !state.sessions.has(entry.id)) return;
    setTimeout(() => { if (entry.alive && state.sessions.has(entry.id)) connectTerminal(entry, Math.min(delay * 2, 8000)); }, delay);
  };
}

function disposeTerminal(id) {
  const entry = state.terminals.get(id);
  if (!entry) return;
  entry.alive = false;
  entry.socket?.close();
  entry.term.dispose();
  entry.node.remove();
  state.terminals.delete(id);
}

// MARK: inspector

function renderInspector() {
  const session = selected();
  const s = session?.state;
  const panel = (name, count, body) => {
    const section = document.querySelector(`.panel[data-panel="${name}"]`);
    section.querySelector(".count").textContent = count ? `(${count})` : "";
    section.querySelector(".panel-body").replaceChildren(...(body.length ? body : [el("div", { class: "empty-line" }, "—")]));
  };
  panel("todos", s?.todos.length, (s?.todos ?? []).map((todo) => {
    const [glyph, color] = TODO[todo.status] ?? TODO.pending;
    return el("div", { class: "todo" }, el("span", { style: `color:${color}` }, glyph), el("span", {}, todo.subject));
  }));
  const now = Date.now() / 1000;
  panel("agents", s?.subagents.length, (s?.subagents ?? []).map((agent) => {
    const seconds = Math.max(0, Math.round((agent.finishedAt ?? now) - agent.startedAt));
    return el("div", { class: "subagent" },
      el("span", { style: `color:${agent.finishedAt ? "#a6e3a1" : "#8abeb7"}` }, agent.finishedAt ? "✓" : "◈"),
      el("span", {}, `${agent.type}${agent.description ? " — " + agent.description : ""} · ${duration(seconds)}`));
  }));
  panel("changes", s?.changes.length, (s?.changes ?? []).map((change) =>
    el("details", { class: "change" },
      el("summary", {}, el("span", {}, shortPath(change.path, session.projectPath)),
         el("span", { class: "added" }, `+${change.added}`), el("span", { class: "removed" }, `−${change.removed}`)),
      el("div", { class: "diff" }, change.hunks.flatMap((hunk) => [
        el("div", { class: "hunk" }, hunk.header),
        ...hunk.lines.map((line) => el("div", { class: "line-" + line.kind },
                                       (line.kind === "added" ? "+" : line.kind === "removed" ? "-" : " ") + line.text)),
      ])))));
}

function duration(seconds) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

function shortPath(path, project) {
  return path.startsWith(project + "/") ? path.slice(project.length + 1) : path;
}

$("toggle-inspector").onclick = toggleInspector;
function toggleInspector() {
  const collapsed = $("inspector").classList.toggle("collapsed");
  localStorage.setItem("am.inspectorCollapsed", String(collapsed));
  const entry = state.terminals.get(state.selectedId);
  if (entry) requestAnimationFrame(() => fitTerminal(entry));
}

// MARK: glyphs

// Kiro's ghost, traced from its app icon into a 100×100 box (x, y pairs); AgentGlyph.swift draws the same.
const GHOST_POINTS = [
  58,83.5, 56.5,83.5, 55,83, 53.7,82, 52,80.2, 51,79.8, 50,80, 47,81.5, 42.5,83.1, 39,83.4,
  36.5,83.1, 35,82.5, 32.5,80.5, 31.1,77.5, 30.8,75, 31.6,71, 31.5,70, 30.5,69.4, 27,69.7, 24.5,69.3,
  22.9,68, 22.3,67, 21.9,65.5, 22,64, 22.5,62.5, 24.7,58, 26,54.5, 27.1,49, 28.6,37.5, 30.3,31.5,
  32.4,27, 35,23.6, 39.5,19.7, 45,17.1, 51.5,15.8, 57,16.4, 60,17.2, 65.5,19.9, 68.5,22.3, 71.9,26,
  74.6,31, 76.2,35.5, 77.2,41, 77.7,49, 77.1,55.5, 75.5,63, 73.6,68.5, 70.5,74.5, 68.7,77, 66.7,79,
  62.5,82.1,
];

/// A closed Catmull-Rom spline through x, y pairs, as an SVG path of cubic Béziers.
function smoothClosedPath(flat) {
  const p = [];
  for (let i = 0; i < flat.length; i += 2) p.push([flat[i], flat[i + 1]]);
  const n = p.length, at = (i) => p[(i + n) % n];
  let d = `M${p[0][0]} ${p[0][1]}`;
  for (let i = 0; i < n; i++) {
    const [a, b, c, e] = [at(i - 1), at(i), at(i + 1), at(i + 2)];
    const c1 = [b[0] + (c[0] - a[0]) / 6, b[1] + (c[1] - a[1]) / 6];
    const c2 = [c[0] - (e[0] - b[0]) / 6, c[1] - (e[1] - b[1]) / 6];
    d += ` C${c1[0].toFixed(2)} ${c1[1].toFixed(2)} ${c2[0].toFixed(2)} ${c2[1].toFixed(2)} ${c[0]} ${c[1]}`;
  }
  return d + " Z";
}

function glyphSVG(glyph, size) {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("width", size);
  svg.setAttribute("height", size);
  svg.setAttribute("viewBox", "0 0 100 100");
  const add = (tag, attrs) => {
    const node = document.createElementNS(ns, tag);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    svg.append(node);
  };
  if (glyph.kind === "spark") {
    const lengths = [1, 0.78, 0.92, 0.74, 1, 0.82, 0.95, 0.76, 0.98, 0.8, 0.9, 0.72];
    lengths.forEach((length, i) => {
      const angle = (i / lengths.length) * 2 * Math.PI - Math.PI / 2;
      add("line", { x1: 50 + Math.cos(angle) * 8, y1: 50 + Math.sin(angle) * 8,
                    x2: 50 + Math.cos(angle) * 46 * length, y2: 50 + Math.sin(angle) * 46 * length,
                    stroke: glyph.value, "stroke-width": 9, "stroke-linecap": "round" });
    });
  } else if (glyph.kind === "ghost") {
    add("rect", { x: 0, y: 0, width: 100, height: 100, rx: 14, fill: glyph.value });
    add("path", { d: smoothClosedPath(GHOST_POINTS), fill: "#fff" });
    add("ellipse", { cx: 53, cy: 40, rx: 3.2, ry: 5.2, fill: "#0d0b12" });
    add("ellipse", { cx: 64.5, cy: 40.1, rx: 3.2, ry: 5.2, fill: "#0d0b12" });
  } else {
    add("rect", { x: 5, y: 5, width: 90, height: 90, rx: 24, fill: "none", stroke: "#ccd3db", "stroke-width": 6 });
    add("polyline", { points: "30,36 44,50 30,64", fill: "none", stroke: "#ccd3db", "stroke-width": 8,
                      "stroke-linecap": "round", "stroke-linejoin": "round" });
    add("line", { x1: 52, y1: 64, x2: 70, y2: 64, stroke: "#ccd3db", "stroke-width": 8, "stroke-linecap": "round" });
  }
  return svg;
}

// MARK: new session

const newSession = { agentId: null };

/// Every ＋: a project's ＋ fills in that project, the sidebar's ＋ the selected session's; either can be changed.
async function openNewSession(project) {
  try { await loadAgents(); } catch { return; }
  const installed = state.agents.filter((a) => a.location);
  newSession.agentId = (installed[0] ?? state.agents[0])?.id;
  $("new-error").hidden = true;
  const { paths } = await api("GET", "/api/recents");
  $("new-recents").replaceChildren(...paths.map((path) => el("option", { value: path })));
  $("new-project").value = project ?? selected()?.projectPath ?? paths[0] ?? state.home;
  renderNewAgents();
  $("new-dialog").showModal();
  $("new-start").focus();
}

function renderNewAgents() {
  $("new-agents").replaceChildren(...state.agents.map((agent) => el("div", {
    class: "agent-card" + (agent.id === newSession.agentId ? " selected" : "") + (agent.location ? "" : " missing"),
    title: agent.location ?? agent.missingHint,
    onclick: () => { if (agent.location) { newSession.agentId = agent.id; renderNewAgents(); } },
  }, glyphSVG(agent.glyph, 44), el("div", { class: "name" }, agent.name),
     el("div", { class: "detail" }, agent.location ? (agent.defaultModel ?? "default model") : "not installed"))));
  const agent = state.agents.find((a) => a.id === newSession.agentId);
  const modelOption = agent?.options.find((o) => o.id === "model");
  const select = $("new-model");
  select.replaceChildren(el("option", { value: "" }, `Default — ${agent?.defaultModel ?? (agent?.name ?? "") + " setting"}`),
    ...(modelOption?.choices ?? []).map((c) => el("option", { value: c.value }, c.detail ? `${c.label} — ${c.detail}` : c.label)),
    ...(modelOption?.allowsCustom ? [el("option", { value: CUSTOM }, "Custom…")] : []));
  $("new-model-custom").hidden = true;
  $("new-model-custom").value = "";
  $("new-start").disabled = !agent?.location;
}

$("new-model").onchange = () => {
  $("new-model-custom").hidden = $("new-model").value !== CUSTOM;
  if (!$("new-model-custom").hidden) $("new-model-custom").focus();
};
$("new-cancel").onclick = () => $("new-dialog").close();
$("new-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const choice = $("new-model").value;
  const model = choice === CUSTOM ? $("new-model-custom").value.trim() || null : choice || null;
  const projectPath = $("new-project").value.trim();
  const { cols, rows } = terminalSizeGuess();
  $("new-start").disabled = true;
  try {
    const session = await api("POST", "/api/sessions",
                              { projectPath, agentId: newSession.agentId, model, columns: cols, rows });
    adopt(session);
    $("new-dialog").close();
    select(session.id);
  } catch (error) {
    $("new-error").hidden = false;
    $("new-error").textContent = error.message;
  } finally {
    $("new-start").disabled = false;
  }
});

/// The size of an existing terminal, so a new agent starts at roughly the right size before the first fit.
function terminalSizeGuess() {
  const entry = state.terminals.get(state.selectedId) ?? state.terminals.values().next().value;
  return entry ? { cols: entry.term.cols, rows: entry.term.rows } : { cols: 120, rows: 36 };
}

$("new-session").onclick = () => openNewSession(null);
$("empty-new").onclick = () => openNewSession(null);

// Alt+N: another session next to the selected one, with the same agent (⌘N belongs to the browser).
// Captured before the terminal, which would otherwise also type the key.
document.addEventListener("keydown", async (event) => {
  if (event.altKey && !event.metaKey && !event.ctrlKey && (event.code === "KeyN")) {
    event.preventDefault();
    event.stopPropagation();
    const current = selected();
    if (!current) return openNewSession(null);
    try {
      const { cols, rows } = terminalSizeGuess();
      const session = await api("POST", "/api/sessions",
                                { projectPath: current.projectPath, agentId: current.agentId, columns: cols, rows });
      adopt(session);
      select(session.id);
    } catch (error) { alert(error.message); }
  } else if (event.altKey && !event.metaKey && !event.ctrlKey && event.code === "Digit0") {
    event.preventDefault();
    event.stopPropagation();
    toggleInspector();
  }
}, true);

// MARK: folder picker

async function browse(path) {
  try {
    const listing = await api("GET", "/api/folders?path=" + encodeURIComponent(path));
    $("folder-path").textContent = listing.path;
    $("folder-path").dataset.path = listing.path;
    $("folder-list").replaceChildren(
      ...(listing.parent ? [el("li", { class: "up", onclick: () => browse(listing.parent) }, "↑ ..")] : []),
      ...listing.folders.map((f) => el("li", { onclick: () => browse(f.path) }, "▸ " + f.name)));
  } catch (error) { alert(error.message); }
}

$("new-browse").onclick = () => {
  browse($("new-project").value.trim() || state.home);
  $("folder-dialog").showModal();
};
$("folder-cancel").onclick = () => $("folder-dialog").close();
$("folder-choose").onclick = () => {
  $("new-project").value = $("folder-path").dataset.path;
  $("folder-dialog").close();
};

// MARK: settings

let settingsPage = null;

$("open-settings").onclick = async () => {
  try { await loadAgents(); } catch { return; }
  settingsPage = settingsPage ?? state.agents[0]?.id ?? "general";
  renderSettings();
  $("settings-dialog").showModal();
};
$("settings-close").onclick = () => $("settings-dialog").close();

function renderSettings() {
  $("settings-nav").replaceChildren(
    el("div", { class: "heading" }, "AGENTS"),
    ...state.agents.map((agent) => el("div", {
      class: "item" + (settingsPage === agent.id ? " selected" : ""),
      onclick: () => { settingsPage = agent.id; renderSettings(); },
    }, glyphSVG(agent.glyph, 18), agent.name)),
    el("div", { class: "spacer" }),
    el("div", { class: "item" + (settingsPage === "general" ? " selected" : ""),
                onclick: () => { settingsPage = "general"; renderSettings(); } }, "⚙︎  General"));
  const agent = state.agents.find((a) => a.id === settingsPage);
  $("settings-page").replaceChildren(...(agent ? agentPage(agent) : generalPage()));
}

function agentPage(agent) {
  return [
    el("div", { class: "page-header" }, glyphSVG(agent.glyph, 40),
      el("div", {}, el("h2", {}, agent.name),
        el("div", { class: "status " + (agent.location ? "ok" : "missing") }, agent.location ?? agent.missingHint))),
    el("p", { class: "section-title" }, "Defaults for new sessions"),
    el("div", { class: "options" }, agent.options.map((option) => optionRow(agent, option))),
    el("p", { class: "footnote" }, "Applies to new sessions. Running sessions keep their settings. " +
                                   "Each new session can still pick another model."),
  ];
}

function optionRow(agent, option) {
  const value = agent.preferences[option.id];
  const label = el("div", { class: "label" }, el("div", {}, option.title),
                   option.note ? el("div", { class: "note" }, option.note) : null);
  let control;
  if (option.kind === "toggle") {
    const forced = agent.forcedOn.includes(option.id);
    const checked = forced || (value === undefined ? option.toggleDefault : value === "true");
    control = el("label", { class: "switch" },
      el("input", { type: "checkbox", checked, disabled: forced,
                    onchange: (e) => setOption(agent, option, e.target.checked ? "true" : "false") }),
      el("span"));
  } else {
    const known = option.choices.some((c) => c.value === value);
    const custom = value !== undefined && !known;
    const select = el("select", {},
      el("option", { value: "" }, `Follow ${agent.name} settings`),
      ...option.choices.map((c) => el("option", { value: c.value }, c.detail ? `${c.label} — ${c.detail}` : c.label)),
      ...(option.allowsCustom ? [el("option", { value: CUSTOM }, "Custom…")] : []));
    select.value = custom ? CUSTOM : value ?? "";
    const input = el("input", { type: "text", placeholder: `Custom ${option.title.toLowerCase()}`, value: custom ? value : "",
                                hidden: !custom, onchange: (e) => setOption(agent, option, e.target.value.trim() || null) });
    select.onchange = () => {
      if (select.value === CUSTOM) { input.hidden = false; input.focus(); }
      else { input.hidden = true; setOption(agent, option, select.value || null); }
    };
    control = el("div", { class: "control" }, select, input);
  }
  return el("div", { class: "option" }, label, control);
}

async function setOption(agent, option, value) {
  try {
    await api("PUT", `/api/agents/${agent.id}/options/${option.id}`, { value });
    await loadAgents();
    renderSettings();
  } catch (error) { alert(error.message); }
}

function generalPage() {
  return [
    el("div", { class: "page-header" }, el("span", { style: "font-size:30px;color:#8a9098" }, "⚙︎"),
      el("div", {}, el("h2", {}, "General"), el("div", { class: "status" }, "AgentMaster server"))),
    el("div", { class: "options" }, el("div", { class: "option" },
      el("div", { class: "label" }, el("div", {}, "Restore sessions on launch"),
         el("div", { class: "note" }, "Sessions open when the server stops come back, resuming their conversations.")),
      el("label", { class: "switch" },
        el("input", { type: "checkbox", checked: state.restoreSessionsOnLaunch, onchange: async (e) => {
          try {
            await api("PUT", "/api/general", { restoreSessionsOnLaunch: e.target.checked });
            state.restoreSessionsOnLaunch = e.target.checked;
          } catch (error) { alert(error.message); }
        } }), el("span")))),
  ];
}

// Pasting the printed link into a tab that is already open only changes the hash.
window.addEventListener("hashchange", () => { if (/token=/.test(location.hash)) start(); });
start();
