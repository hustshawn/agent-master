// AgentMaster web UI. Talks to agentmaster-server's /api (see WebServer.swift). No build step.
"use strict";

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

function isMobile() { return window.matchMedia("(max-width: 700px)").matches; }

// MARK: icons — a small subset of Tabler Icons (MIT, see vendor/LICENSE-tabler.txt), inlined as DOM templates.
const ICON_SOURCE = {
  "git-branch": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 18m-2 0a2 2 0 1 0 4 0a2 2 0 1 0 -4 0" /><path d="M7 6m-2 0a2 2 0 1 0 4 0a2 2 0 1 0 -4 0" /><path d="M17 6m-2 0a2 2 0 1 0 4 0a2 2 0 1 0 -4 0" /><path d="M7 8l0 8" /><path d="M9 18h6a2 2 0 0 0 2 -2v-5" /><path d="M14 14l3 -3l3 3" /></svg>',
  settings: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.325 4.317c.426 -1.756 2.924 -1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543 -.94 3.31 .826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756 .426 1.756 2.924 0 3.35a1.724 1.724 0 0 0 -1.066 2.573c.94 1.543 -.826 3.31 -2.37 2.37a1.724 1.724 0 0 0 -2.572 1.065c-.426 1.756 -2.924 1.756 -3.35 0a1.724 1.724 0 0 0 -2.573 -1.066c-1.543 .94 -3.31 -.826 -2.37 -2.37a1.724 1.724 0 0 0 -1.065 -2.572c-1.756 -.426 -1.756 -2.924 0 -3.35a1.724 1.724 0 0 0 1.066 -2.573c-.94 -1.543 .826 -3.31 2.37 -2.37c1 .608 2.296 .07 2.572 -1.065z" /><path d="M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0" /></svg>',
  plus: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5l0 14" /><path d="M5 12l14 0" /></svg>',
  cloud: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6.657 18c-2.572 0 -4.657 -2.007 -4.657 -4.483c0 -2.475 2.085 -4.482 4.657 -4.482c.393 -1.762 1.794 -3.2 3.675 -3.773c1.88 -.572 3.956 -.193 5.444 1c1.488 1.19 2.162 3.007 1.77 4.769h.99c1.913 0 3.464 1.56 3.464 3.486c0 1.927 -1.551 3.487 -3.465 3.487h-11.878" /></svg>',
  "cloud-off": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9.58 5.548c.24 -.11 .492 -.207 .752 -.286c1.88 -.572 3.956 -.193 5.444 1c1.488 1.19 2.162 3.007 1.77 4.769h.99c1.913 0 3.464 1.56 3.464 3.486c0 .957 -.383 1.824 -1.003 2.454m-2.997 1.033h-11.343c-2.572 -.004 -4.657 -2.011 -4.657 -4.487c0 -2.475 2.085 -4.482 4.657 -4.482c.13 -.582 .37 -1.128 .7 -1.62" /><path d="M3 3l18 18" /></svg>',
  "chevron-right": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6l-6 6" /></svg>',
  "arrow-left": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12l14 0" /><path d="M5 12l6 6" /><path d="M5 12l6 -6" /></svg>',
  "arrow-right": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12l14 0" /><path d="M13 18l6 -6" /><path d="M13 6l6 6" /></svg>',
  "arrow-up": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5l0 14" /><path d="M18 11l-6 -6" /><path d="M6 11l6 -6" /></svg>',
  "circle-check": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 1 0 -18 0" /><path d="M9 12l2 2l4 -4" /></svg>',
  "wifi-off": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 18l.01 0" /><path d="M9.172 15.172a4 4 0 0 1 5.656 0" /><path d="M6.343 12.343a7.963 7.963 0 0 1 3.864 -2.14m4.163 .155a7.965 7.965 0 0 1 3.287 2" /><path d="M3.515 9.515a12 12 0 0 1 3.544 -2.455m3.101 -.92a12 12 0 0 1 10.325 3.374" /><path d="M3 3l18 18" /></svg>',
  "message-circle": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 20l1.3 -3.9c-2.324 -3.437 -1.426 -7.872 2.1 -10.374c3.526 -2.501 8.59 -2.296 11.845 .48c3.255 2.777 3.695 7.266 1.029 10.501c-2.666 3.235 -7.615 4.215 -11.574 2.293l-4.7 1" /></svg>',
  clock: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0" /><path d="M12 7v5l3 3" /></svg>',
  check: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12l5 5l10 -10" /></svg>',
  "player-stop": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 5m0 2a2 2 0 0 1 2 -2h10a2 2 0 0 1 2 2v10a2 2 0 0 1 -2 2h-10a2 2 0 0 1 -2 -2z" /></svg>',
  file: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3v4a1 1 0 0 0 1 1h4" /><path d="M17 21h-10a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2h7l5 5v11a2 2 0 0 1 -2 2z" /></svg>',
  photo: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 8h.01" /><path d="M3 6a3 3 0 0 1 3 -3h12a3 3 0 0 1 3 3v12a3 3 0 0 1 -3 3h-12a3 3 0 0 1 -3 -3v-12z" /><path d="M3 16l5 -5c.928 -.893 2.072 -.893 3 0l5 5" /><path d="M14 14l1 -1c.928 -.893 2.072 -.893 3 0l3 3" /></svg>',
  x: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6l-12 12" /><path d="M6 6l12 12" /></svg>',
  "file-code": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3v4a1 1 0 0 0 1 1h4" /><path d="M17 21h-10a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2h7l5 5v11a2 2 0 0 1 -2 2z" /><path d="M10 13l-1 2l1 2" /><path d="M14 13l1 2l-1 2" /></svg>',
  server: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4m0 3a3 3 0 0 1 3 -3h12a3 3 0 0 1 3 3v2a3 3 0 0 1 -3 3h-12a3 3 0 0 1 -3 -3z" /><path d="M3 12m0 3a3 3 0 0 1 3 -3h12a3 3 0 0 1 3 3v2a3 3 0 0 1 -3 3h-12a3 3 0 0 1 -3 -3z" /><path d="M7 8l0 .01" /><path d="M7 16l0 .01" /></svg>',
  history: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 8l0 4l2 2" /><path d="M3.05 11a9 9 0 1 1 .5 4m-.5 5v-5h5" /></svg>',
  "terminal-2": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 9l3 3l-3 3" /><path d="M13 15l3 0" /><path d="M3 4m0 2a2 2 0 0 1 2 -2h14a2 2 0 0 1 2 2v12a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2z" /></svg>',
  dots: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0" /><path d="M12 12m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0" /><path d="M19 12m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0" /></svg>',
  "shield-check": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11.46 20.846a12 12 0 0 1 -7.96 -14.846a12 12 0 0 0 8.5 -3a12 12 0 0 0 8.5 3a12 12 0 0 1 -.09 7.06" /><path d="M15 19l2 2l4 -4" /></svg>',
  refresh: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 11a8.1 8.1 0 0 0 -15.5 -2m-.5 -4v4h4" /><path d="M4 13a8.1 8.1 0 0 0 15.5 2m.5 4v-4h-4" /></svg>',
  "layout-sidebar": '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4m0 2a2 2 0 0 1 2 -2h12a2 2 0 0 1 2 2v12a2 2 0 0 1 -2 2h-12a2 2 0 0 1 -2 -2z" /><path d="M9 4l0 16" /></svg>',
};
const iconTemplates = new Map();
function icon(name, size) {
  let template = iconTemplates.get(name);
  if (!template) {
    const wrapper = document.createElement("div");
    wrapper.innerHTML = ICON_SOURCE[name];
    template = wrapper.firstElementChild;
    iconTemplates.set(name, template);
  }
  const node = template.cloneNode(true);
  node.setAttribute("aria-hidden", "true");
  node.setAttribute("focusable", "false");
  if (size) { node.setAttribute("width", size); node.setAttribute("height", size); }
  return node;
}
// Static placeholders in index.html (`<svg data-icon="…">`) are hydrated once at load.
document.querySelectorAll("[data-icon]").forEach((node) => node.replaceWith(icon(node.dataset.icon)));

const state = {
  token: null,
  sessions: new Map(),        // id -> SessionJSON
  // No initial selection: a valid #session=<id> URL (parsed once the first snapshot arrives, in
  // applyLocationSelection()) or a user click chooses one; otherwise the home pane shows (see render()).
  selectedId: null,
  agents: [],                 // AgentJSON[]
  restoreSessionsOnLaunch: true,
  home: "/",
  terminals: new Map(),       // id -> { term, fit, socket, node, alive }
  events: null,
  lastUpdate: null,
  socketOpen: false,           // the /api/events stream is connected
  online: false,               // socketOpen and the browser has a network (see updateOnline)
  snapshotLoaded: false,        // the first "snapshot" event has arrived — before this, home shows a loading state
  sidebarCollapsed: localStorage.getItem("am.sidebarCollapsed") === "true",   // desktop preference, per device
  sidebarOpenMobile: false,      // the phone drawer; independent of the desktop preference, closed by default
  filter: "all",                // "all" | "needsAttention" | "running" | "review"
  requests: new Map(),        // id -> ActionRequestJSON
  messages: new Map(),        // id -> MessageReceiptJSON
  chats: new Map(),           // sessionId -> ChatItemJSON[]
  chatFetching: new Set(),    // sessionId currently mid-fetch
  chatErrors: new Map(),      // sessionId -> why its conversation failed to load, until the next try
  interrupted: new Set(),     // sessionIds interrupted from here, until their next message
  // sessionId -> draft attachments: { key, file, name, size, image, localUrl, status, progress, error,
  //              retryable, attachment (the uploaded AttachmentJSON, once ready), xhr (while uploading) }.
  // status is "uploading" | "ready" | "offline" (waiting for the connection) | "failed".
  attachments: new Map(),
  uploadLimits: null,          // UploadLimitsJSON, loaded once at login; null skips client-side checks
  sending: new Map(),         // sessionId -> { text, keys: Set(attachment key) } snapshot while a send is in flight
  chatTimers: new Map(),      // sessionId -> { soon, late } refetch timeouts
  chatStuck: new Map(),       // sessionId -> whether the transcript is scrolled to the bottom
  answerDrafts: new Map(),    // requestId -> Map(question -> Set(chosen labels))
  answerNotes: new Map(),     // requestId -> optional note string
  pendingMessageIds: new Map(), // sessionId -> client message id, kept across a retry
  composerDrafts: new Map(),  // sessionId -> composer textarea draft
  composerErrors: new Map(),  // sessionId -> last send error, until the draft changes
  terminalInputDrafts: new Map(), // sessionId -> mobile terminal input-bar draft
  renamingSelected: null,     // sessionId currently being renamed in the detail header
  settingsOpen: false,
  settingsSection: "overview", // "overview" (mobile only), an agent id, or "general"
};
let detailTab = "conversation"; // "conversation" or "changes"; reset whenever a session is selected

// MARK: token and API

function readToken() {
  const match = location.hash.match(/token=([^&]+)/);
  if (match) {
    localStorage.setItem("am.token", decodeURIComponent(match[1]));
    // Drop only the token: a link can also name a session (`#token=…&session=…`) to open after login.
    const rest = location.hash.slice(1).split("&").filter((part) => !part.startsWith("token=")).join("&");
    history.replaceState(null, "", location.pathname + location.search + (rest ? "#" + rest : ""));
  }
  return localStorage.getItem("am.token");
}

async function api(method, path, body) {
  let response;
  try {
    response = await fetch(path, {
      method,
      headers: { Authorization: "Bearer " + state.token, ...(body ? { "Content-Type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    // fetch only rejects when the request never got an answer ("Failed to fetch" / "Load failed").
    throw new Error("Couldn't reach the server. Check your connection and try again.");
  }
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
  await loadUploadLimits();
  $("login").hidden = true;
  $("app").hidden = false;
  render();   // shows the home pane's loading state right away, before the first snapshot arrives
  connectEvents();
}

async function loadAgents() {
  const response = await api("GET", "/api/agents");
  state.agents = response.agents;
  state.restoreSessionsOnLaunch = response.restoreSessionsOnLaunch;
  state.home = response.home;
}

/// The server's own format/size/count rules, for the picker and client-side validation. Not fetching this
/// is not fatal — attachments just fall back to whatever the server itself rejects.
async function loadUploadLimits() {
  try { state.uploadLimits = await api("GET", "/api/uploads/limits"); } catch { state.uploadLimits = null; }
}

// MARK: live session list

function connectEvents(delay = 500) {
  const socket = new WebSocket(wsURL("/api/events"));
  state.events = socket;
  socket.onopen = () => { state.socketOpen = true; delay = 500; updateOnline(); };
  socket.onmessage = (message) => {
    const event = JSON.parse(message.data);
    if (event.type === "snapshot") {
      state.sessions = new Map(event.sessions.map((s) => [s.id, s]));
      state.requests = new Map((event.requests ?? []).map((r) => [r.id, r]));
      state.messages = new Map((event.messages ?? []).map((m) => [m.id, m]));
      for (const id of [...state.terminals.keys()]) if (!state.sessions.has(id)) disposeTerminal(id);
      state.snapshotLoaded = true;
      applyLocationSelection();
      // After a reconnect, catch up on whatever the open conversation missed (or failed to load) while offline.
      state.chatErrors.delete(state.selectedId);
      if (state.chats.has(state.selectedId)) scheduleChatFetch(state.selectedId);
    } else if (event.type === "session") {
      state.sessions.set(event.session.id, event.session);
      if (event.session.id === state.selectedId) scheduleChatFetch(event.session.id);
    } else if (event.type === "removed") {
      state.sessions.delete(event.id);
      disposeTerminal(event.id);
      // The session is gone (closed elsewhere): go home rather than guess at another one to show. This is
      // not a navigation the user asked for, so it corrects the URL in place instead of pushing a new entry.
      if (state.selectedId === event.id) {
        state.selectedId = null;
        history.replaceState(null, "", location.pathname + location.search);
        if (isMobile()) setSidebarOpen(false);
      }
    } else if (event.type === "request") {
      state.requests.set(event.request.id, event.request);
    } else if (event.type === "message") {
      state.messages.set(event.message.id, event.message);
    }
    state.lastUpdate = Date.now();
    render();
  };
  socket.onclose = () => {
    if (state.events !== socket || $("app").hidden) return;
    state.socketOpen = false;
    updateOnline();
    setTimeout(() => connectEvents(Math.min(delay * 2, 8000)), delay);
  };
}

/// A WebSocket that is already open can outlive the network for a while (the browser does not notice at
/// once), so the browser's own offline signal counts too: sending is pointless either way.
function updateOnline() {
  const online = state.socketOpen && navigator.onLine;
  if (online === state.online) return;
  state.online = online;
  render();
}
window.addEventListener("online", () => {
  updateOnline();
  // The stream may have died silently while offline; reconnecting replaces it and resends a snapshot.
  if (state.events && state.events.readyState !== WebSocket.OPEN) return;
  state.events?.close();
});
window.addEventListener("offline", updateOnline);

function formatClock(ms) {
  return new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

/// The id in `#session=<id>` (e.g. the hash a push notification links to), or null for the home URL.
function hashSessionId() {
  const match = location.hash.match(/session=([^&]+)/);
  return match ? decodeURIComponent(match[1]) : null;
}

/// Syncs state.selectedId to whatever `#session=<id>` (or its absence) in the URL says, on first load, on
/// every hashchange (including browser back/forward, which changes the hash too) and once the first
/// snapshot arrives. Never picks a session on its own: an id the snapshot doesn't have goes home instead,
/// correcting the URL in place rather than leaving the dead link live for back/forward to land on again.
function applyLocationSelection() {
  const id = hashSessionId();
  if (!id) {
    if (state.selectedId !== null) selectInternal(null);
    return;
  }
  if (!state.snapshotLoaded) return;   // render() shows a loading state meanwhile; resolved once it arrives
  if (state.sessions.has(id)) {
    if (state.selectedId !== id) selectInternal(id);
  } else {
    selectInternal(null);
    history.replaceState(null, "", location.pathname + location.search);
  }
}

/// A session the POST just created. The event stream is the source of truth and may already carry a newer
/// state (a fast agent reports its first hook before the POST response arrives), so never overwrite it.
function adopt(session) {
  if (!state.sessions.has(session.id)) state.sessions.set(session.id, session);
}

function selected() {
  return state.sessions.get(state.selectedId) ?? null;
}

/// Applies a selection (or clears it) without touching the URL — shared by the hash-driven path above and
/// the user-driven one below, so only one of them ever decides when to push a new history entry. Whatever
/// is now showing (a session or home) should never be hidden behind a phone drawer left open from before.
function selectInternal(id) {
  state.selectedId = id;
  detailTab = "conversation";
  state.renamingSelected = null;
  $("session-menu").hidden = true;
  if (id) state.chatStuck.set(id, true);   // entering a session shows its latest messages, however long it is
  if (id) fetchChat(id);
  render();
  if (isMobile()) setSidebarOpen(false);
}

/// A session row/card was clicked: select it and push a history entry, so browser back returns here.
function select(id) {
  if (state.selectedId === id) { if (isMobile()) setSidebarOpen(false); return; }
  selectInternal(id);
  history.pushState(null, "", location.pathname + location.search + "#session=" + encodeURIComponent(id));
}

/// Returns to the home pane. This only changes navigation: it never stops, closes or otherwise touches the
/// session itself, so its view mode, drafts and attachments are exactly as they were on the next visit.
function goHome() {
  if (!state.settingsOpen && state.selectedId === null) {
    if (isMobile()) setSidebarOpen(false, { focusReturn: true });
    return;
  }
  const hadSession = state.selectedId !== null;
  state.settingsOpen = false;
  selectInternal(null);
  if (hadSession) history.pushState(null, "", location.pathname + location.search);
  $("home-pane").querySelector("h1")?.focus({ preventScroll: true });
}

// MARK: status — a session's phase drives both the list grouping and the detail status pill.

function pendingRequestsFor(sessionId) {
  return [...state.requests.values()].filter((r) => r.sessionId === sessionId && r.status === "pending");
}

/// "needsAttention" (needs you, including a startup that seems stuck), "running" (in progress), "review"
/// (a turn ended, not yet marked), "reviewed" (marked), "new" (idle, nothing asked yet) or "stopped" (ended).
function sessionPhase(session) {
  if (session.status === "needsAttention" || pendingRequestsFor(session.id).length || isStalled(session)) return "needsAttention";
  if (session.status === "running" || session.status === "starting") return "running";
  if (session.status === "ended") return "stopped";
  if (!session.hasConversation) return "new";
  return session.reviewed ? "reviewed" : "review";
}

const PHASES = [
  ["needsAttention", "Needs you"],
  ["running", "In progress"],
  ["review", "Ready for review"],
  ["new", "Not started"],
  ["reviewed", "Reviewed"],
  ["stopped", "Stopped"],
];
const PHASE_LABEL = Object.fromEntries(PHASES);
const PHASE_ICON = { needsAttention: "message-circle", running: "clock", review: "circle-check", new: "plus", reviewed: "check",
                     stopped: "player-stop" };
const PHASE_PILL_CLASS = { needsAttention: "needs-you", running: "", review: "review", new: "", reviewed: "reviewed",
                           stopped: "stopped" };

/// The title without Claude Code's "[Image #N]" placeholders, which a first prompt with an image starts with.
/// Neither are an uploaded file's paths, when the first message was attachments only.
function displayTitle(session) {
  return session.title.replace(ATTACHMENT_IN_PROMPT_G, "").replace(/\s+/g, " ").trim() || "Attachments";
}

function sessionsList() { return [...state.sessions.values()]; }
function phaseCount(phase) { return sessionsList().filter((s) => sessionPhase(s) === phase).length; }

/// The "Ready for review" filter also shows "Reviewed" sessions, matching the prototype's filter tabs.
function filterAllows(session, filter) {
  if (filter === "all") return true;
  const phase = sessionPhase(session);
  return filter === "review" ? phase === "review" || phase === "reviewed" : phase === filter;
}

/// Only `createdAt`/`lastActivityAt` are epoch seconds, not milliseconds.
function relativeTime(epochSeconds) {
  const seconds = Math.max(0, Date.now() / 1000 - epochSeconds);
  if (seconds < 60) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

// MARK: render

function render() {
  // Selection, sidebar visibility and the session collection are independent: a session is only ever
  // chosen by a URL, a notification or a click (see applyLocationSelection()/select()) — never guessed here.
  const session = selected();
  // A selection restored from the URL (or picked above) never went through select(); load its history here.
  if (session && !state.chats.has(state.selectedId) && !state.chatErrors.has(state.selectedId)) fetchChat(state.selectedId);
  sessionsList().forEach(watchStartup);
  $("app").classList.toggle("settings-open", state.settingsOpen);
  $("settings-pane").hidden = !state.settingsOpen;
  $("home-pane").hidden = !!session;
  renderList();
  renderDetailPane();
  if (!session) renderHomePane();
  if (state.settingsOpen) renderSettings();
  updateSidebarChrome();
}

// MARK: session list

function agentFor(session) { return state.agents.find((a) => a.id === session.agentId); }

function agentLabel(agent, name) {
  return el("span", { class: "agent-label" }, agent ? glyphSVG(agent.glyph, 14) : null, el("span", {}, name));
}

function requestPreviewText(request) {
  if (request.kind === "question") return request.input?.questions?.[0]?.question ?? request.title;
  return request.title;
}

function needsYouCard(session) {
  const requests = pendingRequestsFor(session.id);
  const stalled = !requests.length && isStalled(session);
  const preview = requests.length ? requestPreviewText(requests[0])
    : stalled ? "No activity since launch. " + STALLED_HINT : session.state.attentionMessage ?? session.subtitle;
  const current = session.id === state.selectedId;
  return el("div", { class: "needs-you-card" + (current ? " selected" : ""), "aria-current": current ? "true" : null },
    el("div", { class: "session-meta-line" }, icon("git-branch"), el("span", {}, session.projectName),
       el("span", { class: "agent-name" }, agentLabel(agentFor(session), session.agentName))),
    el("h3", {}, displayTitle(session)),
    el("p", {}, preview),
    stalled
      ? el("button", { class: "primary", type: "button", onclick: () => { select(session.id); showView(session, "terminal"); } },
           "Open Terminal", icon("arrow-right"))
      : el("button", { class: "primary", type: "button", onclick: () => select(session.id) }, "View and reply", icon("arrow-right")));
}

/// `showStatus` is for the home pane's "Recent sessions" (HOME-SPEC: project, agent, status and latest
/// progress), where there is no status-grouped section heading to carry that like the sidebar list has.
function sessionRow(session, { showStatus = false } = {}) {
  const agent = agentFor(session);
  const current = session.id === state.selectedId;
  const preview = showStatus ? `${PHASE_LABEL[sessionPhase(session)]} · ${session.subtitle}` : session.subtitle;
  const row = el("button", { class: "session-row" + (current ? " selected" : ""), type: "button",
                        "aria-current": current ? "true" : null, onclick: (e) => {
                          if (row.dataset.longPressed) { delete row.dataset.longPressed; e.preventDefault(); return; }
                          select(session.id);
                        } },
    el("span", { class: "session-row-icon" }, agent ? glyphSVG(agent.glyph, 20) : el("span")),
    el("div", { class: "session-row-body" },
      el("span", { class: "session-title-text" }, displayTitle(session)),
      el("span", { class: "session-row-sub" }, el("span", {}, session.projectName), el("span", {}, relativeTime(session.lastActivityAt))),
      el("span", { class: "session-preview" }, preview)),
    icon("chevron-right"));
  attachRowMenu(row, session.id);
  return row;
}

// MARK: session row menu — right-click opens it at the pointer; a touch long-press opens it as a sheet.

const LONG_PRESS_MS = 500;

function attachRowMenu(row, id) {
  let timer = null, startX = 0, startY = 0, touch = false;
  const cancel = () => { clearTimeout(timer); timer = null; };
  row.addEventListener("pointerdown", (e) => {
    delete row.dataset.longPressed;   // not every browser follows a long-press with a click to swallow
    touch = e.pointerType !== "mouse";
    if (!touch) return;
    startX = e.clientX; startY = e.clientY;
    timer = setTimeout(() => { timer = null; row.dataset.longPressed = "1"; openRowSheet(id); }, LONG_PRESS_MS);
  });
  row.addEventListener("pointermove", (e) => {
    if (timer && Math.hypot(e.clientX - startX, e.clientY - startY) > 10) cancel();
  });
  row.addEventListener("pointerup", cancel);
  row.addEventListener("pointercancel", cancel);
  row.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    if (!touch) openRowMenu(id, e.clientX, e.clientY);   // a touch long-press is handled by the timer above
  });
}

function rowMenuItems(id, done) {
  const run = (action) => () => { done(); const session = state.sessions.get(id); if (session) action(session); };
  return [
    el("button", { type: "button", role: "menuitem", onclick: run(renameFromRow) }, "Rename"),
    el("button", { type: "button", role: "menuitem", class: "danger", onclick: run(closeSession) }, "Close session"),
  ];
}

/// Rename reuses the detail header's inline editor, so the session is opened first.
function renameFromRow(session) {
  select(session.id);
  state.renamingSelected = session.id;
  renderDetailSummary(session);
}

function openRowMenu(id, x, y) {
  const menu = $("row-menu");
  menu.replaceChildren(...rowMenuItems(id, closeRowMenu));
  menu.hidden = false;
  const { width, height } = menu.getBoundingClientRect();
  menu.style.left = Math.min(x, innerWidth - width - 8) + "px";
  menu.style.top = Math.min(y, innerHeight - height - 8) + "px";
  menu.querySelector("button").focus();
}

function closeRowMenu() { $("row-menu").hidden = true; }

function openRowSheet(id) {
  const session = state.sessions.get(id);
  if (!session) return;
  $("row-sheet-title").textContent = displayTitle(session);
  $("row-sheet-choices").replaceChildren(...rowMenuItems(id, () => $("row-sheet").close()));
  $("row-sheet").showModal();
}
$("row-sheet-close").onclick = () => $("row-sheet").close();
document.addEventListener("click", (e) => { if (!$("row-menu").hidden && !e.target.closest("#row-menu")) closeRowMenu(); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !$("row-menu").hidden) closeRowMenu(); });
window.addEventListener("blur", closeRowMenu);
document.addEventListener("scroll", closeRowMenu, true);

function renderList() {
  const needsYouCount = phaseCount("needsAttention");
  const runningCount = phaseCount("running");

  const top = el("div", { class: "list-top" },
    el("div", { class: "brand-line" },
      el("div", { class: "sidebar-brand" },
        sidebarToggleButtonNode("sidebar-collapse-button"),
        // The enlarged brand is itself the clickable home entry (PR #9 review); there is no separate
        // "Home" row below it, and collapse/settings stay their own buttons.
        el("button", { class: "in-app-brand", type: "button", "aria-label": "AgentMaster home", onclick: goHome },
          el("img", { src: "icon.png", alt: "" }), "AgentMaster")),
      el("div", { class: "brand-actions" },
        el("span", { class: "cloud-state" + (state.online ? "" : " offline") },
          icon(state.online ? "cloud" : "cloud-off"),
          state.online ? "Online"
            : `${navigator.onLine ? "Reconnecting…" : "Offline"} · last synced ${state.lastUpdate ? formatClock(state.lastUpdate) : "—"}`),
        el("button", { class: "icon-button", type: "button", title: "Settings", onclick: openSettings }, icon("settings")))),
    el("div", { class: "heading-line" }, el("h1", {}, "Sessions"),
      el("button", { class: "new-session-button", type: "button", onclick: () => openNewSession(null) }, icon("plus"), "New")),
    el("p", { class: "overview-line" },
      `${runningCount} running` + (needsYouCount ? `, ${needsYouCount} need${needsYouCount === 1 ? "s" : ""} you` : ", nothing needs you")));

  const filters = el("nav", { class: "filter-tabs" },
    [["all", "All"], ["needsAttention", "Needs you"], ["running", "In progress"], ["review", "Ready for review"]].map(([key, label]) =>
      el("button", { type: "button", class: state.filter === key ? "active" : "", onclick: () => { state.filter = key; renderList(); } },
        label, key === "needsAttention" && needsYouCount ? el("span", { class: "count" }, String(needsYouCount)) : null)));

  const groups = PHASES.map(([phase, title]) => {
    const rows = sessionsList().filter((s) => sessionPhase(s) === phase && filterAllows(s, state.filter))
      .sort((a, b) => b.lastActivityAt - a.lastActivityAt);
    if (!rows.length) return null;
    return el("section", { class: "session-group" },
      el("h2", { class: "section-heading" }, phase === "needsAttention" ? el("span", { class: "attention-dot" }) : null,
        title, el("span", { class: "group-count" }, String(rows.length))),
      rows.map((session) => (phase === "needsAttention" ? needsYouCard(session) : sessionRow(session))));
  }).filter(Boolean);

  const scroll = el("div", { class: "list-scroll" },
    groups.length ? groups : el("div", { class: "list-empty" }, icon("circle-check"), "Nothing here yet. New activity will show up here."));

  $("list-pane").replaceChildren(top, filters, scroll);
}

// MARK: sidebar collapse (desktop) / drawer (phone) — layout only; never touches sessions, drafts or
// terminals. See SIDEBAR-SPEC.md and the PR #9 review's "可收起左侧栏" section.

function isSidebarOpen() {
  return isMobile() ? state.sidebarOpenMobile : !state.sidebarCollapsed;
}

/// `extraClass` tells updateSidebarChrome() which buttons are the content area's "expand" buttons (home's
/// and the session detail topbar's — hidden once a desktop sidebar is already open) versus the one inside
/// the sidebar itself (always visible whenever the sidebar is, with nothing extra to manage).
function sidebarToggleButtonNode(extraClass) {
  return el("button", { type: "button", class: "icon-button" + (extraClass ? " " + extraClass : ""),
                        "data-sidebar-toggle": "", "aria-controls": "list-pane",
                        onclick: () => setSidebarOpen(!isSidebarOpen(), { focusReturn: true }) },
    icon("layout-sidebar"));
}

/// Changes layout only — same contract as collapsing/expanding: the session list underneath, the selected
/// session, its drafts and its terminal are all untouched.
function setSidebarOpen(open, { focusReturn = false } = {}) {
  if (isMobile()) state.sidebarOpenMobile = open;
  else { state.sidebarCollapsed = !open; localStorage.setItem("am.sidebarCollapsed", String(!open)); }
  updateSidebarChrome();
  if (!focusReturn) return;
  requestAnimationFrame(() => {
    if (open) $("list-pane").querySelector(".sidebar-collapse-button")?.focus();
    else document.querySelector(".sidebar-expand-button:not([hidden])")?.focus();
  });
}

/// Applies the open/closed state to the DOM: visibility, inert/aria-hidden (a closed drawer or a collapsed
/// sidebar is reachable by neither Tab nor a screen reader), the phone drawer's modal backdrop, and every
/// `[data-sidebar-toggle]` button's label, aria-expanded and needs-you badge. Called after render() and
/// after setSidebarOpen(), never a substitute for either.
function updateSidebarChrome() {
  const open = isSidebarOpen();
  const mobile = isMobile();
  const drawer = mobile && open;
  $("app").classList.toggle("sidebar-collapsed", !mobile && !open);
  $("app").classList.toggle("sidebar-drawer-open", drawer);
  $("list-pane").inert = !open;
  $("list-pane").setAttribute("aria-hidden", String(!open));
  $("list-pane").setAttribute("role", drawer ? "dialog" : "complementary");
  if (drawer) $("list-pane").setAttribute("aria-modal", "true");
  else $("list-pane").removeAttribute("aria-modal");
  $("sidebar-backdrop").hidden = !drawer;
  // Only the phone drawer is a modal overlay; the desktop sidebar beside the content never needs this.
  $("home-pane").inert = drawer;
  $("detail-pane").inert = drawer;
  const count = phaseCount("needsAttention");
  document.querySelectorAll("[data-sidebar-toggle]").forEach((button) => {
    button.setAttribute("aria-expanded", String(open));
    const label = open ? (mobile ? "Close sidebar" : "Collapse sidebar") : "Expand sidebar";
    button.setAttribute("aria-label", label);
    button.title = label;
    if (!button.classList.contains("sidebar-expand-button")) return;
    button.hidden = !mobile && open;
    let badge = button.querySelector(".sidebar-pending-count");
    if (count > 0) {
      if (!badge) { badge = el("span", { class: "sidebar-pending-count", "aria-hidden": "true" }); button.append(badge); }
      badge.textContent = String(count);
    } else badge?.remove();
  });
}

$("sidebar-backdrop").onclick = () => setSidebarOpen(false, { focusReturn: true });
$("sidebar-toggle").onclick = () => setSidebarOpen(!isSidebarOpen(), { focusReturn: true });
$("back-to-home").onclick = goHome;

// Esc closes the phone drawer; Tab/Shift+Tab cycle inside it instead of escaping into the inert background.
document.addEventListener("keydown", (event) => {
  if (!isMobile() || !state.sidebarOpenMobile || document.querySelector("dialog[open]")) return;
  if (event.key === "Escape") {
    event.preventDefault();
    setSidebarOpen(false, { focusReturn: true });
  } else if (event.key === "Tab") {
    const items = [...$("list-pane").querySelectorAll("button:not(:disabled)")];
    if (!items.length) return;
    const first = items[0], last = items[items.length - 1];
    if (!$("list-pane").contains(document.activeElement)) { event.preventDefault(); first.focus(); }
    else if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  }
});

// Crossing the phone/desktop breakpoint (resizing the window, rotating) needs its layout re-applied even
// though neither preference changed; isSidebarOpen() already reads the right one for the new width.
window.matchMedia("(max-width: 700px)").addEventListener("change", updateSidebarChrome);

// MARK: sidebar width (desktop) — drag the list-pane's right border (#sidebar-resizer). Remembered per
// device like the collapse; the phone drawer keeps its own width. Terminals refit through their ResizeObserver.

const SIDEBAR_MIN_WIDTH = 280, SIDEBAR_MAX_WIDTH = 600, CONTENT_MIN_WIDTH = 320;   // the last also in app.css

function setSidebarWidth(width) {
  $("app").style.setProperty("--list-width", width + "px");
}

const savedSidebarWidth = Number(localStorage.getItem("am.sidebarWidth"));
if (savedSidebarWidth) setSidebarWidth(savedSidebarWidth);

$("sidebar-resizer").addEventListener("pointerdown", (event) => {
  if (event.button !== 0) return;
  event.preventDefault();   // no text selection, and the terminal underneath keeps its focus
  const resizer = event.currentTarget;
  resizer.setPointerCapture(event.pointerId);
  const startX = event.clientX;
  let width = Math.round($("list-pane").getBoundingClientRect().width);
  const startWidth = width;
  const max = Math.min(SIDEBAR_MAX_WIDTH, window.innerWidth - CONTENT_MIN_WIDTH);
  $("app").classList.add("sidebar-resizing");
  const move = (moveEvent) => {
    width = Math.round(Math.max(SIDEBAR_MIN_WIDTH, Math.min(max, startWidth + moveEvent.clientX - startX)));
    setSidebarWidth(width);
  };
  resizer.addEventListener("pointermove", move);
  // Fires after pointerup and pointercancel alike.
  resizer.addEventListener("lostpointercapture", () => {
    resizer.removeEventListener("pointermove", move);
    $("app").classList.remove("sidebar-resizing");
    localStorage.setItem("am.sidebarWidth", String(width));
  }, { once: true });
});

// MARK: home — shown whenever no valid session is selected. See HOME-SPEC.md and the PR #9 review's "首页"
// section: a loading state before the first snapshot, a first-run guide with none ever created, otherwise
// New session plus needs-you items first and up to four recent sessions, sorted by real last activity.

function homeTopbar() {
  return el("header", { class: "home-topbar" },
    sidebarToggleButtonNode("sidebar-expand-button"),
    el("span", { class: "home-topbar-label" }, "Home"),
    el("button", { class: "icon-button home-settings-button", type: "button", title: "Settings", "aria-label": "Settings",
                  onclick: openSettings }, icon("settings")));
}

function renderHomePane() {
  const pane = $("home-pane");
  document.title = "AgentMaster";
  if (!state.snapshotLoaded) {
    pane.replaceChildren(homeTopbar(),
      el("div", { class: "detail-scroll home-scroll" },
        el("div", { class: "home-content" }, el("p", { class: "chat-placeholder" }, "Loading sessions…"))));
    return;
  }
  const empty = state.sessions.size === 0;
  const pending = sessionsList().filter((s) => sessionPhase(s) === "needsAttention")
    .sort((a, b) => b.lastActivityAt - a.lastActivityAt);
  const recent = sessionsList().filter((s) => sessionPhase(s) !== "needsAttention")
    .sort((a, b) => b.lastActivityAt - a.lastActivityAt).slice(0, 4);
  const runningCount = phaseCount("running");

  const newButton = el("button", { class: "primary home-create", type: "button", disabled: !state.online,
                                   onclick: () => openNewSession(null) }, icon("plus"), "New session");
  const note = el("p", { class: "home-start-note" },
    state.online ? "Your work keeps running in the cloud after you leave." : "Reconnect to start a new session.");

  const start = el("section", { class: "home-start" },
    el("h1", { tabindex: "-1" }, empty ? "Start your first session" : "Continue your work"),
    el("p", {}, empty ? "Choose a project and an agent, and hand off what you want done."
      : !state.online ? "Showing the last synced sessions. Reconnect for updates."
      : `${runningCount} running` + (pending.length ? `, ${pending.length} need${pending.length === 1 ? "s" : ""} you` : ", nothing needs you")),
    newButton, note);

  const pendingSection = empty || !pending.length ? null : el("section", { class: "home-section" },
    el("h2", { class: "section-heading" }, el("span", { class: "attention-dot" }), "Needs you",
      el("span", { class: "group-count" }, String(pending.length))),
    pending.map(needsYouCard));

  const recentSection = empty || !recent.length ? null : el("section", { class: "home-section" },
    el("h2", { class: "section-heading" }, "Recent sessions"),
    recent.map((session) => sessionRow(session, { showStatus: true })));

  pane.replaceChildren(homeTopbar(),
    el("div", { class: "detail-scroll home-scroll" },
      el("div", { class: "home-content" + (empty ? " home-empty" : "") }, start, pendingSection, recentSection)));
}

// MARK: detail pane

function renderDetailPane() {
  const session = selected();
  $("detail-pane").hidden = !session;
  if (!session) return;
  document.title = `${displayTitle(session)} — AgentMaster`;

  renderDetailSummary(session);
  renderToolbar(session);

  const view = chatViewFor(session.id);
  for (const button of $("view-toggle").children) {
    const active = button.dataset.view === view;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
  }
  $("chat-pane").hidden = view !== "chat";
  $("terminal-pane").hidden = view !== "terminal";
  $("detail-pane").classList.toggle("terminal-view", view === "terminal");   // compact summary above the TUI
  for (const [id, entry] of state.terminals) entry.node.hidden = id !== session.id || view !== "terminal";

  if (view === "terminal") {
    showTerminal(session);
    renderTerminalInputBar(session);
    renderTerminalAttachmentsNote(session);
  } else {
    renderChatArea(session);
  }
}

/// Each session remembers its own choice of chat vs. terminal, like the Mac app remembers panel layout.
function chatViewFor(id) {
  return localStorage.getItem("am.view." + id) ?? "chat";
}

function renderDetailSummary(session) {
  const phase = sessionPhase(session);
  if (state.renamingSelected === session.id) {
    const input = el("input", { value: session.title,
      onkeydown: (e) => {
        if (e.key === "Enter") commitRename(session, e.target.value);
        if (e.key === "Escape") { state.renamingSelected = null; renderDetailSummary(session); }
      },
      onblur: (e) => commitRename(session, e.target.value) });
    $("detail-summary").replaceChildren(
      el("div", { class: "session-meta-line" }, icon("git-branch"), el("span", {}, session.projectName)),
      el("h1", {}, input));
    queueMicrotask(() => { input.focus(); input.select(); });
    return;
  }
  $("detail-summary").replaceChildren(
    el("div", { class: "session-meta-line" }, icon("git-branch"), el("span", {}, session.projectName),
      el("span", { class: "agent-name" }, agentLabel(agentFor(session), session.agentName))),
    el("h1", {}, displayTitle(session)),
    el("div", { class: "summary-row" },
      el("span", { class: "status-pill" + (PHASE_PILL_CLASS[phase] ? " " + PHASE_PILL_CLASS[phase] : "") },
        icon(PHASE_ICON[phase]), PHASE_LABEL[phase]),
      reviewToggleButton(session, phase)));
}

/// Only offered once a session has had a prompt — nothing to mark reviewed on an untouched session.
function reviewToggleButton(session, phase) {
  const prompted = session.state.firstPrompt != null || session.state.lastMessage != null;
  if (!prompted) return null;
  if (phase === "review") {
    return el("button", { class: "review-toggle", type: "button", onclick: () => setReviewed(session, true) }, "Mark reviewed");
  }
  if (phase === "reviewed" && session.reviewed) {
    // The pill already says Reviewed; this only takes it back.
    return el("button", { class: "review-toggle is-reviewed", type: "button", onclick: () => setReviewed(session, false) }, "Undo");
  }
  return null;
}

async function setReviewed(session, reviewed) {
  try { await api("PUT", `/api/sessions/${session.id}/reviewed`, { reviewed }); } catch (error) { alert(error.message); }
}

function telemetryParts(session) {
  const usage = session.state.usage;
  return {
    model: usage?.modelName || "—",
    policy: session.state.permissionMode || "—",
    ctx: usage?.contextUsedPercent != null ? `${usage.contextUsedPercent}%` : "—",
    cost: usage?.costUSD != null ? `$${usage.costUSD.toFixed(2)}` : "—",
  };
}

function renderToolbar(session) {
  const t = telemetryParts(session);
  // Before the agent's first status line there is nothing to show; say so instead of a row of dashes.
  if (!session.state.usage) {
    const text = agentFor(session)?.reportsUsage ? "Usage not reported yet" : `${session.agentName} doesn't report usage`;
    $("session-telemetry").replaceChildren(el("span", { class: "t-model t-none dim" }, text));
    return;
  }
  $("session-telemetry").replaceChildren(
    el("span", { class: "t-model" }, t.model), el("span", { class: "t-policy" }, t.policy),
    el("span", { class: "t-ctx" }, `ctx ${t.ctx}`), el("span", { class: "t-cost" }, t.cost));
}

for (const button of $("view-toggle").children) {
  button.onclick = () => {
    const session = selected();
    if (!session) return;
    localStorage.setItem("am.view." + session.id, button.dataset.view);
    renderDetailPane();
  };
}

$("session-menu-button").onclick = (event) => {
  event.stopPropagation();
  $("session-menu").hidden = !$("session-menu").hidden;
};
document.addEventListener("click", (event) => {
  if (!$("session-menu").hidden && !event.target.closest(".session-menu-wrap")) $("session-menu").hidden = true;
});
$("menu-rename").onclick = () => {
  $("session-menu").hidden = true;
  const session = selected();
  if (!session) return;
  state.renamingSelected = session.id;
  renderDetailSummary(session);
};
$("menu-close").onclick = () => {
  $("session-menu").hidden = true;
  const session = selected();
  if (session) closeSession(session);
};

async function commitRename(session, value) {
  if (state.renamingSelected !== session.id) return;
  state.renamingSelected = null;
  if (value.trim() !== session.title.trim()) {
    try { await api("PATCH", `/api/sessions/${session.id}`, { name: value }); } catch (error) { alert(error.message); }
  }
  const current = selected();
  if (current) renderDetailSummary(current);
}

async function closeSession(session) {
  if ((session.status === "running" || session.status === "needsAttention") &&
      !confirm(`Close “${displayTitle(session)}”?\n\n${session.agentName} is still working in ${session.projectName}. ` +
               "The transcript is kept, so the conversation can be resumed later.")) return;
  try { await api("DELETE", `/api/sessions/${session.id}`); } catch (error) { alert(error.message); }
}

// MARK: chat area — pending decision, resolved history, conversation / changes tabs, composer

function renderChatArea(session) {
  const pending = pendingRequestsFor(session.id);
  const decisionArea = $("decision-area");
  const normalArea = $("normal-area");
  const footer = $("decision-footer");
  const composer = $("composer");

  if (pending.length) {
    normalArea.hidden = true;
    footer.hidden = false;
    composer.hidden = true;
    decisionArea.hidden = false;
    renderDecision(pending[0]);
  } else {
    decisionArea.hidden = true;
    decisionArea.replaceChildren();
    footer.hidden = true;
    footer.replaceChildren();
    normalArea.hidden = false;
    composer.hidden = false;
    renderDetailTabs();
    renderResolvedRequests(session);
    renderConversation(session);
    renderChangesTab(session);
    renderComposer(session);
  }
  if (!pending.length && detailTab === "conversation" && (state.chatStuck.get(session.id) ?? true)) {
    const scroll = $("chat-scroll");
    requestAnimationFrame(() => { scroll.scrollTop = scroll.scrollHeight; });
  }
}

$("chat-scroll").addEventListener("scroll", () => {
  const scroll = $("chat-scroll");
  state.chatStuck.set(state.selectedId, scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 40);
});

/// While the reader is at the bottom, the bottom stays in view however the conversation grows: its history
/// arriving after the session opened, a new message, an image finishing loading. Scrolling up stops this.
new ResizeObserver(() => {
  const scroll = $("chat-scroll");
  if (detailTab !== "conversation" || $("normal-area").hidden) return;
  if (state.chatStuck.get(state.selectedId) ?? true) scroll.scrollTop = scroll.scrollHeight;
}).observe($("chat-messages"));

$("detail-tabs").querySelectorAll("button").forEach((button) => {
  button.onclick = () => { detailTab = button.dataset.tab; renderDetailTabs(); };
});
function renderDetailTabs() {
  for (const button of $("detail-tabs").children) {
    const active = button.dataset.tab === detailTab;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
  }
  $("tab-conversation").hidden = detailTab !== "conversation";
  $("tab-changes").hidden = detailTab !== "changes";
}

// MARK: pending decision

function refreshDecision(request) {
  if (!$("decision-area").hidden) renderDecision(request);
}

function renderDecision(request) {
  if (request.kind === "permission") {
    $("decision-area").replaceChildren(permissionDecisionCard(request));
    $("decision-footer").replaceChildren(...permissionFooter(request));
  } else {
    $("decision-area").replaceChildren(questionDecisionCard(request));
    $("decision-footer").replaceChildren(...questionFooter(request));
  }
}

function questionDecisionCard(request) {
  const questions = request.input?.questions ?? [];
  const draft = state.answerDrafts.get(request.id) ?? new Map();
  state.answerDrafts.set(request.id, draft);
  const blocks = questions.map((question, qi) => {
    const chosen = draft.get(question.question) ?? new Set();
    draft.set(question.question, chosen);
    const toggle = (label, checked) => {
      if (question.multiSelect) { checked ? chosen.add(label) : chosen.delete(label); }
      else { chosen.clear(); if (checked) chosen.add(label); }
      refreshDecision(request);
    };
    return el("div", { class: "decision-question" },
      el("h2", {}, question.header || question.question),
      question.header ? el("p", { class: "decision-subtext" }, question.question) : null,
      (question.options ?? []).map((option) =>
        el("label", { class: "choice" },
          el("input", { type: question.multiSelect ? "checkbox" : "radio", name: `am-question-${qi}`,
                       checked: chosen.has(option.label), onchange: (e) => toggle(option.label, e.target.checked) }),
          el("span", {}, el("strong", {}, option.label), option.description ? el("small", {}, option.description) : null))));
  });
  const note = el("textarea", { class: "decision-note", rows: 2, placeholder: "Add a note (optional)",
                                oninput: (e) => state.answerNotes.set(request.id, e.target.value) },
                  state.answerNotes.get(request.id) ?? "");
  return el("div", { class: "decision-card" },
    el("div", { class: "decision-label" }, icon("message-circle"), "Needs your decision"), blocks, note);
}

function questionFooter(request) {
  const questions = request.input?.questions ?? [];
  const draft = state.answerDrafts.get(request.id) ?? new Map();
  const answered = questions.every((q) => (draft.get(q.question) ?? new Set()).size > 0);
  return [
    el("div", { class: "button-row" },
      el("button", { class: "primary", type: "button", disabled: !answered,
                    onclick: () => submitAnswers(request, questions, draft) }, "Send decision", icon("arrow-up"))),
    el("p", { class: "decision-help" }, answered ? "The agent continues with your choice once you send it."
                                                  : "Choose an option to send your decision."),
  ];
}

async function submitAnswers(request, questions, draft) {
  const note = (state.answerNotes.get(request.id) ?? "").trim();
  const answers = {};
  for (const question of questions) {
    const labels = [...(draft.get(question.question) ?? new Set())].join(", ");
    answers[question.question] = note ? `${labels} — ${note}` : labels;
  }
  try {
    await decide(request.id, { answers });
    state.answerDrafts.delete(request.id);
    state.answerNotes.delete(request.id);
  } catch {}
}

function permissionDecisionCard(request) {
  return el("div", { class: "decision-card" },
    el("div", { class: "decision-label" }, icon("shield-check"), "Needs your approval"),
    el("h2", {}, request.title),
    el("pre", { class: "permission-detail" }, detailText(request.input)),
    el("textarea", { class: "decision-note", rows: 2, placeholder: "Reason, if you deny (optional)",
                     oninput: (e) => state.answerNotes.set(request.id, e.target.value) },
       state.answerNotes.get(request.id) ?? ""));
}

function detailText(input) {
  if (typeof input?.command === "string") return input.command;
  if (typeof input?.file_path === "string") return input.file_path;
  return JSON.stringify(input, null, 2);
}

function permissionFooter(request) {
  return [
    el("div", { class: "button-row" },
      el("button", { class: "primary", type: "button", onclick: () => decide(request.id, { behavior: "allow" }) }, "Allow"),
      el("button", { type: "button", onclick: () => decide(request.id,
          { behavior: "deny", message: (state.answerNotes.get(request.id) ?? "").trim() || undefined }) }, "Deny")),
    el("p", { class: "decision-help" }, "Allow or deny this one action; the agent will continue either way"),
  ];
}

async function decide(requestId, body) {
  try {
    await api("POST", `/api/requests/${requestId}`, body);
  } catch (error) {
    // A 409 (answered elsewhere, or expired) is already reflected by the request event that caused it;
    // anything else is worth telling the user about.
    if (!/already/.test(error.message)) alert(error.message);
  }
}

// MARK: resolved request history

function renderResolvedRequests(session) {
  const resolved = [...state.requests.values()].filter((r) => r.sessionId === session.id && r.status !== "pending")
    .sort((a, b) => (a.resolvedAt ?? a.createdAt) - (b.resolvedAt ?? b.createdAt));
  $("resolved-requests").replaceChildren(...resolved.map(resolvedCard));
}

function resolvedCard(request) {
  return el("div", { class: "resolved-card" },
    el("div", { class: "resolved-title" }, request.title),
    el("div", { class: "resolved-outcome" }, outcomeText(request)));
}

function outcomeText(request) {
  if (request.status === "expired") return "Expired — " + (request.outcome ?? "timed out");
  if (request.kind === "permission") return request.outcome === "allowed" ? "Allowed" : "Denied";
  return "Answered";
}

// MARK: conversation — rendered from the transcript (chat), restyled from the previous implementation.

// marked renders everything else as usual, but raw HTML tokens (inline or block) are escaped instead of
// passed through: an agent's transcript is not trusted content, and the chat view must not run it as markup.
const mdRenderer = new marked.Renderer();
mdRenderer.html = (token) => escapeHtml(token.text ?? token.raw ?? "");
marked.setOptions({ renderer: mdRenderer, breaks: true });

function escapeHtml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/// Debounced per `docs/superpowers/specs/2026-10-04-cross-device-design.md` 4.3: a quick refetch plus one
/// later one, since the transcript is flushed slightly after the hook that triggered the `session` event.
function scheduleChatFetch(id) {
  const timers = state.chatTimers.get(id) ?? {};
  clearTimeout(timers.soon);
  clearTimeout(timers.late);
  timers.soon = setTimeout(() => fetchChat(id), 300);
  timers.late = setTimeout(() => fetchChat(id), 800);
  state.chatTimers.set(id, timers);
}

async function fetchChat(id) {
  // Guards against two overlapping fetches (e.g. select() and a debounced refetch) racing on the same
  // cached snapshot; the one already in flight will pick up anything the other would have fetched.
  if (!state.sessions.has(id) || state.chatFetching.has(id)) return;
  state.chatFetching.add(id);
  const cached = state.chats.get(id) ?? [];
  let page;
  try {
    page = await api("GET", `/api/sessions/${id}/chat?after=${cached.length}`);
  } catch (error) {
    // Shown only while nothing is cached; with messages on screen, the next refetch catches up quietly.
    state.chatFetching.delete(id);
    state.chatErrors.set(id, error.message);
    if (id === state.selectedId) renderConversation(selected());
    return;
  }
  state.chatFetching.delete(id);
  state.chatErrors.delete(id);
  state.chats.set(id, [...cached.slice(0, page.start), ...page.items]);
  if (id === state.selectedId) renderConversation(selected());
}

/// Consecutive tool calls fold into one "N steps" group; everything else renders on its own.
function groupChatItems(items) {
  const groups = [];
  let run = [];
  const flush = () => {
    if (run.length) groups.push(run.length > 1 ? { type: "steps", items: run } : { type: "step", item: run[0] });
    run = [];
  };
  for (const item of items) {
    if (item.kind === "tool") run.push(item);
    else { flush(); groups.push({ type: item.kind, item }); }
  }
  flush();
  return groups;
}

/// What an empty conversation means: still loading, failed to load, stuck at startup, or simply nothing yet.
function emptyConversation(session) {
  if (isStalled(session)) {
    return el("div", { class: "silent-notice" },
      el("strong", {}, `${session.agentName} hasn't reported anything yet`),
      el("p", {}, STALLED_HINT + " If it isn't, its CLI may be too old to report activity to AgentMaster; " +
                  "its terminal still works as usual."),
      el("button", { type: "button", class: "primary", onclick: () => showView(session, "terminal") }, "Open Terminal"));
  }
  if (state.chatErrors.has(session.id)) {
    return el("div", { class: "silent-notice" },
      el("strong", {}, "Couldn't load the conversation"),
      el("p", {}, state.chatErrors.get(session.id)),
      el("button", { type: "button", onclick: () => fetchChat(session.id) }, "Try again"));
  }
  if (!state.chats.has(session.id)) return el("p", { class: "chat-placeholder" }, "Loading conversation…");
  return el("p", { class: "chat-placeholder" },
    session.hasConversation ? "No messages to show yet." : "Nothing asked yet. Send a message below to start.");
}

function renderConversation(session) {
  if (!session) return;
  const items = state.chats.get(session.id) ?? [];
  const lastItem = items[items.length - 1];
  const agent = agentFor(session);
  const stepNode = (item) => stepRow(item, item === lastItem, session);
  if (!items.length) {
    $("chat-messages").replaceChildren(emptyConversation(session));
    return;
  }
  // Each receipt with attachments is linked to at most one transcript item, oldest first (see receiptForItem).
  const consumedReceipts = new Set();
  $("chat-messages").replaceChildren(...groupChatItems(items).map((group) => {
    if (group.type === "user") return userBubble(group.item, session, consumedReceipts);
    if (group.type === "assistant") return assistantBubble(group.item, agent, session.agentName);
    if (group.type === "step") return stepNode(group.item);
    return el("details", { class: "step-group" },
      el("summary", {}, `${group.items.length} steps`),
      el("div", { class: "step-group-body" }, group.items.map(stepNode)));
  }));
}

/// An attachment's place in a prompt: Claude Code's "[Image #N]", or the path of a file uploaded from here
/// (`…/sessions/<id>/files/<8 hex>-<name>`, or `…/images/` from a terminal paste).
const ATTACHMENT_IN_PROMPT = /(\[Image #\d+\]|\/\S+\/sessions\/[^/\s]+\/(?:files|images)\/\S+)/;
const ATTACHMENT_IN_PROMPT_G = new RegExp(ATTACHMENT_IN_PROMPT.source, "g");

function withoutWhitespace(text) { return text.replace(/\s+/g, ""); }

/// The receipt (if any) that produced this transcript item: its text, once Claude Code's own placeholders
/// and any attachment paths are stripped, is exactly what the browser sent (see Messages.swift, which does
/// this same comparison live to confirm delivery). Each receipt is claimed by at most one item.
function receiptForItem(item, sessionId, consumed) {
  const stripped = withoutWhitespace(item.text.replace(ATTACHMENT_IN_PROMPT_G, ""));
  for (const receipt of state.messages.values()) {
    if (receipt.sessionId !== sessionId || !receipt.attachments.length || consumed.has(receipt.id)) continue;
    if (withoutWhitespace(receipt.text) === stripped) { consumed.add(receipt.id); return receipt; }
  }
  return null;
}

/// A sent message: its attachments (if any) as thumbnails or file cards, then its own text. Falls back to
/// tagging raw placeholders when no receipt matches — typed into the terminal, or lost to a server restart.
function userBubble(item, session, consumed) {
  const receipt = receiptForItem(item, session.id, consumed);
  if (receipt) {
    return el("div", { class: "msg msg-user" }, el("div", { class: "bubble" },
      receipt.attachments.length ? sentAttachments(receipt.attachments) : null, receipt.text || null));
  }
  const parts = item.text.split(ATTACHMENT_IN_PROMPT).filter(Boolean).map((part) => {
    const image = part.match(/^\[Image #(\d+)\]$/);
    if (image) return el("span", { class: "image-tag" }, icon("photo"), `Image ${image[1]}`);
    if (!ATTACHMENT_IN_PROMPT.test(part) || !part.startsWith("/")) return part;
    const name = part.split("/").pop().replace(/^[0-9a-f]{8}-/, "");
    const isImage = /\.(png|jpe?g|gif|webp)$/i.test(name);
    return el("span", { class: "image-tag", title: part }, icon(isImage ? "photo" : "file"), name);
  });
  return el("div", { class: "msg msg-user" }, el("div", { class: "bubble" }, parts));
}

function assistantBubble(item, agent, agentName) {
  const bubble = el("div", { class: "bubble markdown" });
  bubble.innerHTML = marked.parse(item.text ?? "");
  return el("div", { class: "msg msg-assistant" },
    el("div", { class: "agent-line" }, agent ? glyphSVG(agent.glyph, 14) : null, agentName), bubble);
}

function stepGlyph(item, isLast, session) {
  if (item.output !== undefined && item.output !== null) return el("span", { class: "step-glyph done" }, "✓");
  if (isLast && (session.status === "running" || session.status === "needsAttention")) {
    return el("span", { class: "step-glyph spin" }, "◐");
  }
  return el("span", { class: "step-glyph" });
}

function stepRow(item, isLast, session) {
  return el("details", { class: "step" },
    el("summary", {}, stepGlyph(item, isLast, session), el("span", { class: "step-title" }, item.title ?? item.name)),
    el("div", { class: "step-body" },
      el("div", { class: "step-label" }, "Input"), el("pre", {}, item.input ?? ""),
      item.output != null ? el("div", { class: "step-label" }, "Output") : null,
      item.output != null ? el("pre", {}, item.output) : null));
}

// MARK: changes tab — the former inspector's TODO / AGENTS / CHANGES panels, merged into one scrollable section.

function renderChangesTab(session) {
  const s = session.state;
  const now = Date.now() / 1000;
  // File changes lead; Todo and Subagents only appear once the agent has some.
  const changes = el("div", { class: "changes-section" }, el("h3", {}, "File changes"),
    s.changes.length ? changesList(session) : el("div", { class: "empty-line" }, "No file changes yet."));
  const todos = s.todos.length ? el("div", { class: "changes-section" }, el("h3", {}, "Todo"),
    s.todos.map((todo) => {
      const [glyph, color] = TODO[todo.status] ?? TODO.pending;
      return el("div", { class: "todo" }, el("span", { style: `color:${color}` }, glyph), el("span", {}, todo.subject));
    })) : null;
  const subagents = s.subagents.length ? el("div", { class: "changes-section" }, el("h3", {}, "Subagents"),
    s.subagents.map((agent) => {
      const seconds = Math.max(0, Math.round((agent.finishedAt ?? now) - agent.startedAt));
      return el("div", { class: "subagent" },
        el("span", { style: `color:${agent.finishedAt ? "#a6e3a1" : "#8abeb7"}` }, agent.finishedAt ? "✓" : "◈"),
        el("span", {}, `${agent.type}${agent.description ? " — " + agent.description : ""} · ${duration(seconds)}`));
    })) : null;
  $("tab-changes").replaceChildren(...[changes, todos, subagents].filter(Boolean));
  $("changes-count").textContent = s.changes.length ? `(${s.changes.length})` : "";
}

/// Shared with nothing else now that the inspector is gone, but kept separate for readability.
function changesList(session) {
  return (session.state.changes ?? []).map((change) =>
    el("details", { class: "change" },
      el("summary", {}, el("span", {}, shortPath(change.path, session.projectPath)),
         el("span", { class: "added" }, `+${change.added}`), el("span", { class: "removed" }, `−${change.removed}`)),
      el("div", { class: "diff" }, change.hunks.flatMap((hunk) => [
        el("div", { class: "hunk" }, hunk.header),
        ...hunk.lines.map((line) => el("div", { class: "line-" + line.kind },
                                       (line.kind === "added" ? "+" : line.kind === "removed" ? "-" : " ") + line.text)),
      ]))));
}

function duration(seconds) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

function shortPath(path, project) {
  return path.startsWith(project + "/") ? path.slice(project.length + 1) : path;
}

// MARK: composer

let lastComposerSessionId = null;

/// How long an agent normally takes to report its first hook after launch.
const STARTUP_GRACE_SECONDS = 8;
const stallTimers = new Set();

/// Still "starting" after the grace period: the CLI is up (its terminal works) but has reported nothing.
/// Either it waits on a startup question only its terminal shows (Claude asking to trust a new folder), or
/// its hooks never load (an older CLI). Either way it needs the user, and Chat cannot help.
function isStalled(session) {
  return session.status === "starting" && Date.now() / 1000 - session.createdAt > STARTUP_GRACE_SECONDS;
}

/// Re-renders once a starting session's grace period is over, so it moves to Needs you on its own.
function watchStartup(session) {
  if (session.status !== "starting" || isStalled(session) || stallTimers.has(session.id)) return;
  stallTimers.add(session.id);
  const remaining = session.createdAt + STARTUP_GRACE_SECONDS - Date.now() / 1000;
  setTimeout(render, Math.max(0, remaining * 1000) + 300);
}

const STALLED_HINT = "It may be waiting for a confirmation in its terminal, such as trusting this folder.";

function showView(session, view) {
  localStorage.setItem("am.view." + session.id, view);
  renderDetailPane();
}

function renderComposer(session) {
  if (lastComposerSessionId !== session.id) {
    $("composer-text").value = state.composerDrafts.get(session.id) ?? "";
    autosizeComposer($("composer-text"));
    lastComposerSessionId = session.id;
  }
  const idle = session.status === "idle";
  const sending = state.sending.has(session.id);
  const list = attachmentsFor(session.id);
  const blocked = list.some((a) => a.status !== "ready");
  // Offline, typing still works (the draft is kept), only sending waits for the connection.
  $("composer-text").disabled = !idle || sending;
  // Attachments can be added while the agent works, ready for the next message — but not mid-send.
  $("composer-attach").disabled = session.status === "ended" || sending;
  // Blocked while any attachment is not ready: the attachment-status line (renderAttachments) says why.
  $("composer-send").disabled = !idle || !state.online || blocked || sending;
  renderAttachments(session);
  const status = $("composer-status");
  const error = state.composerErrors.get(session.id);
  if (!state.online) {
    status.textContent = "You're offline. Your message is kept and can be sent once the connection is back.";
  } else if (sending) {
    status.textContent = list.length ? "Sending message and attachments…" : "Sending message…";
  } else if (error) {
    status.textContent = error;
  } else if (session.status === "running" || session.status === "needsAttention") {
    status.replaceChildren("Agent is working — ",
      el("button", { type: "button", class: "link", onclick: () => interruptSession(session) }, "Interrupt this turn"));
  } else if (isStalled(session)) {
    status.replaceChildren("Nothing reported yet. " + STALLED_HINT + " ",
      el("button", { type: "button", class: "link", onclick: () => showView(session, "terminal") }, "Open Terminal"));
  } else if (session.status === "starting") {
    status.replaceChildren("Starting…");
  } else if (session.status === "ended") {
    status.replaceChildren("Session ended.");
  } else if (state.interrupted.has(session.id)) {
    status.textContent = "Interrupted — the agent stopped this turn and is waiting for your next message.";
  } else {
    const receipts = [...state.messages.values()].filter((m) => m.sessionId === session.id);
    const last = receipts.length ? receipts.reduce((a, b) => (a.createdAt > b.createdAt ? a : b)) : null;
    status.replaceChildren(last ? receiptText(last) : "");
  }
}

function receiptText(receipt) {
  return receipt.status === "written" ? "Sent" : receipt.status === "delivered" ? "Delivered" : "Not confirmed";
}

async function interruptSession(session) {
  try {
    await api("POST", `/api/sessions/${session.id}/interrupt`);
    state.interrupted.add(session.id);   // until the next message, so the last "Delivered" is not read as pending
    renderComposer(session);
  } catch (error) { alert(error.message); }
}

// MARK: attachments — a draft per session, uploaded as soon as they are added and sent by id with the next
// message. Uploading and sending are separate: a message only clears its attachments once the server has
// confirmed the send, and the server (not here) adds the attachments' paths to the agent's prompt.

/// What "+" offers, in order. With one kind, "+" opens its picker straight away; with more, a menu (desktop)
/// or a sheet (phone) lets the user choose. Another kind (a project file picker…) is one more entry here plus
/// its handling in pickAttachment. The system's file picker already offers photos, the camera and files.
const ATTACH_KINDS = [
  { id: "file", label: "File", description: "Photos, screenshots, documents…", icon: "file", accept: "" },
];

function attachmentsFor(sessionId) { return state.attachments.get(sessionId) ?? []; }

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/// The extension if the name has a short one, else a generic label — never the raw name or a bare mime type.
function attachmentTypeLabel(name, image) {
  const ext = name.includes(".") ? name.split(".").pop() : "";
  return ext && ext.length <= 8 ? ext.toUpperCase() : (image ? "Image" : "File");
}

/// Where the browser previews or downloads an uploaded attachment; the token goes in the query because an
/// <img> or <a> cannot send an Authorization header.
function attachmentUrl(attachment) { return `${attachment.url}?token=${encodeURIComponent(state.token)}`; }

function addFiles(session, files) {
  if (!files.length || state.sending.has(session.id)) return;
  const list = attachmentsFor(session.id);
  state.attachments.set(session.id, list);
  const limit = state.uploadLimits?.maxAttachmentsPerMessage;
  let incoming = files;
  if (limit != null) {
    const room = Math.max(0, limit - list.length);
    if (files.length > room) {
      incoming = files.slice(0, room);
      state.composerErrors.set(session.id, room === 0
        ? `This message already has the maximum of ${limit} attachments.`
        : `Only ${room} more fit this message (max ${limit} attachments) — the rest were skipped.`);
    } else {
      state.composerErrors.delete(session.id);   // clears a stale over-limit message from an earlier add
    }
  }
  const added = [];
  for (const file of incoming) {
    const image = file.type.startsWith("image/");
    const attachment = { key: crypto.randomUUID(), file, name: file.name || (image ? "image" : "file"),
      size: file.size, image, localUrl: image ? URL.createObjectURL(file) : null,
      status: "uploading", progress: 0, error: null, retryable: true, attachment: null, xhr: null };
    const maxBytes = state.uploadLimits?.maxFileBytes;
    if (maxBytes != null && file.size > maxBytes) {
      attachment.status = "failed";
      attachment.retryable = false;
      attachment.error = `This file is larger than the ${formatBytes(maxBytes)} limit.`;
    }
    list.push(attachment);
    added.push(attachment);
  }
  renderComposer(session);
  if (added.length) revealAttachment(session, added[added.length - 1].key);
  for (const attachment of added) if (attachment.status === "uploading") startUpload(session, attachment);
}

function removeAttachment(session, key) {
  if (state.sending.has(session.id)) return;
  const list = attachmentsFor(session.id);
  const index = list.findIndex((a) => a.key === key);
  if (index < 0) return;
  const [attachment] = list.splice(index, 1);
  attachment.xhr?.abort();
  if (attachment.localUrl) URL.revokeObjectURL(attachment.localUrl);
  renderComposer(session);
  $("composer-attach").focus();
}

function retryAttachment(session, key) {
  if (!navigator.onLine || state.sending.has(session.id)) return;
  const attachment = attachmentsFor(session.id).find((a) => a.key === key);
  if (attachment) startUpload(session, attachment);
}

/// Scrolls a just-added or just-failed card into view, so a reason or a retry button is never off-screen.
function revealAttachment(session, key) {
  if (state.selectedId !== session.id) return;
  $("draft-attachments").querySelector(`[data-attachment-key="${key}"]`)?.scrollIntoView({ block: "nearest", inline: "nearest" });
}

// Uploads are a plain HTTP request, independent of the events WebSocket: gated on the browser's own
// online/offline signal, not state.online, so a reconnecting events socket never aborts a perfectly
// good upload (nor leaves one stuck) — see resumeOfflineAttachments()/pauseAttachmentUploads() below.
function startUpload(session, attachment) {
  if (!navigator.onLine) {
    attachment.status = "offline";
    if (state.selectedId === session.id) renderComposer(session);
    return;
  }
  attachment.status = "uploading";
  attachment.progress = 0;
  attachment.error = null;
  if (state.selectedId === session.id) renderComposer(session);
  const { xhr, promise } = uploadAttachment(session.id, attachment.file,
    (percent) => patchAttachmentProgress(session.id, attachment.key, percent));
  attachment.xhr = xhr;
  promise.then((json) => {
    attachment.attachment = json;
    attachment.status = "ready";
    attachment.progress = 100;
    attachment.xhr = null;
    if (state.selectedId === session.id) renderComposer(session);
  }).catch((error) => {
    attachment.status = "failed";
    attachment.error = error.message;
    attachment.retryable = error.retryable !== false;
    attachment.xhr = null;
    if (state.selectedId === session.id) { renderComposer(session); revealAttachment(session, attachment.key); }
  });
}

/// POSTs the file with upload.onprogress, so the card's progress bar can be patched in place (see
/// patchAttachmentProgress) instead of re-rendering the whole composer on every percent.
function uploadAttachment(sessionId, file, onProgress) {
  const xhr = new XMLHttpRequest();
  const promise = new Promise((resolve, reject) => {
    xhr.open("POST", `/api/sessions/${sessionId}/files?name=${encodeURIComponent(file.name || "file")}`);
    xhr.setRequestHeader("Authorization", "Bearer " + state.token);
    xhr.setRequestHeader("Content-Type", file.type || "application/octet-stream");
    xhr.upload.onprogress = (event) => { if (event.lengthComputable) onProgress(Math.round((event.loaded / event.total) * 100)); };
    xhr.onload = () => {
      let body = {};
      try { body = JSON.parse(xhr.responseText); } catch {}
      if (xhr.status >= 200 && xhr.status < 300) return resolve(body);
      const error = new Error(body.error?.message || xhr.statusText || "Upload failed.");
      error.retryable = xhr.status !== 413;   // 413 is a size problem retrying cannot fix
      reject(error);
    };
    xhr.onerror = () => reject(new Error("Couldn't reach the server. Check your connection and try again."));
    xhr.onabort = () => reject(new Error("Upload cancelled."));
    xhr.send(file);
  });
  return { xhr, promise };
}

/// Only touches this one card's progress bar and label — never re-renders the composer, so the textarea's
/// value, cursor and focus are untouched while an upload is in flight.
function patchAttachmentProgress(sessionId, key, percent) {
  const attachment = attachmentsFor(sessionId).find((a) => a.key === key);
  if (attachment) attachment.progress = percent;
  if (state.selectedId !== sessionId) return;
  const card = $("draft-attachments").querySelector(`[data-attachment-key="${key}"]`);
  if (!card) return;
  const bar = card.querySelector(".attachment-progress");
  if (bar) { bar.setAttribute("aria-valuenow", String(percent)); bar.firstElementChild.style.width = percent + "%"; }
  const label = card.querySelector(".attachment-state span");
  if (label) label.textContent = `Uploading ${percent}%`;
}

// Tied to the browser's own online/offline signal, not state.online (which also reflects the events
// WebSocket): that socket reconnects independently and can flap right as the network returns, and
// aborting a plain HTTP upload because of that would just undo an upload that was going through fine.
window.addEventListener("online", resumeOfflineAttachments);
window.addEventListener("offline", pauseAttachmentUploads);

function resumeOfflineAttachments() {
  for (const [sessionId, list] of state.attachments) {
    const session = state.sessions.get(sessionId);
    for (const attachment of list) if (session && attachment.status === "offline") startUpload(session, attachment);
  }
}
function pauseAttachmentUploads() {
  for (const list of state.attachments.values()) for (const attachment of list) if (attachment.status === "uploading") {
    attachment.xhr?.abort();
    attachment.xhr = null;
    attachment.status = "offline";
  }
}

/// One line summarizing the whole draft: what is blocking a send, or that everything is ready.
function attachmentStatusText(session, list) {
  if (state.sending.has(session.id)) return list.length ? "Sending message and attachments…" : "Sending message…";
  if (!list.length) return "";
  if (!navigator.onLine) return "You're offline. Uploads will resume once you're back online; your draft is kept.";
  const failed = list.filter((a) => a.status === "failed").length;
  const uploading = list.filter((a) => a.status === "uploading").length;
  const ready = list.filter((a) => a.status === "ready").length;
  if (failed) {
    // Retrying cannot fix a file that is too large, so only offer what can.
    const action = list.some((a) => a.status === "failed" && a.retryable) ? "retry or remove" : "remove";
    return `${failed} attachment${failed === 1 ? "" : "s"} failed — ${action} ${failed === 1 ? "it" : "them"} to send.`;
  }
  if (uploading) return `Uploading ${uploading} of ${list.length}…`;
  return `${ready} attachment${ready === 1 ? "" : "s"} uploaded — they'll be sent with your message.`;
}

function attachmentCardStatusText(a) {
  if (a.status === "uploading") return `Uploading ${a.progress}%`;
  if (a.status === "offline") return "Waiting for connection";
  if (a.status === "failed") return a.error || "Upload failed.";
  return "Uploaded";
}

/// A thumbnail with a fallback for an image that cannot be decoded, or a plain file icon.
function attachmentMedia(a) {
  if (!a.image) return [el("span", { class: "attachment-file-icon" }, icon("file"))];
  const fallback = el("span", { class: "attachment-fallback", hidden: true }, icon("photo"));
  const img = el("img", { src: a.localUrl ?? (a.attachment ? attachmentUrl(a.attachment) : ""), alt: a.name });
  img.addEventListener("error", () => { img.hidden = true; fallback.hidden = false; });
  return [img, fallback];
}

function attachmentCard(session, a, locked) {
  return el("article", { class: `attachment-card ${a.image ? "is-image" : "is-file"} ${a.status}`,
                         "data-attachment-key": a.key, role: "listitem" },
    el("button", { type: "button", class: "attachment-preview", "aria-label": `Preview ${a.name}`, title: a.name,
                   onclick: () => openAttachmentPreview(draftAttachmentPreview(a)) },
      attachmentMedia(a),
      el("span", { class: "attachment-meta" }, el("strong", {}, a.name),
        el("small", {}, `${attachmentTypeLabel(a.name, a.image)} · ${formatBytes(a.size)}`))),
    el("button", { type: "button", class: "attachment-remove", "aria-label": `Remove ${a.name}`, disabled: locked,
                   onclick: () => removeAttachment(session, a.key) }, icon("x")),
    el("div", { class: "attachment-state" },
      a.status === "ready" ? icon("check") : null,
      el("span", {}, attachmentCardStatusText(a)),
      a.status === "failed" && a.retryable
        ? el("button", { type: "button", disabled: locked || !navigator.onLine, onclick: () => retryAttachment(session, a.key) },
            icon("refresh"), "Retry")
        : null),
    a.status === "uploading"
      ? el("div", { class: "attachment-progress", role: "progressbar", "aria-label": `${a.name} upload progress`,
                    "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(a.progress) },
          el("div", { style: `width:${a.progress}%` }))
      : null);
}

/// The draft list above the textarea, and the one-line summary of where the whole draft stands.
function renderAttachments(session) {
  const list = attachmentsFor(session.id);
  const locked = state.sending.has(session.id);
  $("draft-attachments").hidden = !list.length;
  $("draft-attachments").replaceChildren(...list.map((a) => attachmentCard(session, a, locked)));
  const text = attachmentStatusText(session, list);
  $("attachment-status").hidden = !text;
  $("attachment-status").textContent = text;
}

// MARK: attachment preview — a draft or sent attachment's full-size image, or a file's details and a link.

/// A uniform shape for openAttachmentPreview(), whether the attachment is still a draft or already sent.
function draftAttachmentPreview(a) {
  return { name: a.name, size: a.size, image: a.image, url: a.localUrl ?? (a.attachment ? attachmentUrl(a.attachment) : null),
          downloadUrl: a.attachment ? attachmentUrl(a.attachment) : null };
}
function sentAttachmentPreview(attachment) {
  const image = attachment.type.startsWith("image/");
  return { name: attachment.name, size: attachment.size, image, url: attachmentUrl(attachment), downloadUrl: attachmentUrl(attachment) };
}

function openAttachmentPreview(preview) {
  const dialog = $("attachment-preview-dialog");
  let body;
  if (preview.image) {
    // Upload failure (never gets here) is distinct from a format the browser just cannot decode: that
    // case keeps the dialog open and swaps in this note instead of failing silently.
    const fallback = el("p", { hidden: true }, "This format can't be previewed here. Download the file to view it.");
    const img = el("img", { src: preview.url ?? "", alt: preview.name });
    img.addEventListener("error", () => { img.hidden = true; fallback.hidden = false; });
    body = [img, fallback];
  } else {
    body = [el("div", { class: "file-preview-summary" }, icon("file"), el("p", {}, `${attachmentTypeLabel(preview.name, false)} file`))];
  }
  dialog.replaceChildren(
    el("div", { class: "attachment-preview-heading" }, el("h2", {}, preview.name),
      el("button", { type: "button", class: "icon-button", "aria-label": "Close preview", onclick: () => dialog.close() }, icon("x"))),
    el("div", { class: "attachment-preview-content" }, body),
    el("div", { class: "attachment-preview-footer" }, el("span", {}, formatBytes(preview.size)),
      preview.downloadUrl
        ? el("a", { href: preview.downloadUrl, target: "_blank", rel: "noopener" }, "Open / Download")
        : el("span", {}, "Not uploaded yet")));
  dialog.showModal();
}

/// A sent message's own attachments: thumbnails open the preview; file cards open or download directly.
function sentAttachments(attachments) {
  return el("div", { class: "message-attachments", role: "list", "aria-label": "Message attachments" },
    attachments.map((attachment) => {
      const image = attachment.type.startsWith("image/");
      const fallback = el("span", { class: "attachment-fallback", hidden: true }, icon("photo"));
      const img = image ? el("img", { src: attachmentUrl(attachment), alt: attachment.name }) : null;
      if (img) img.addEventListener("error", () => { img.hidden = true; fallback.hidden = false; });
      const media = image ? [img, fallback] : [el("span", { class: "attachment-file-icon" }, icon("file"))];
      const meta = el("span", { class: "sent-attachment-meta" }, el("strong", {}, attachment.name),
        el("small", {}, `${attachmentTypeLabel(attachment.name, image)} · ${formatBytes(attachment.size)}`));
      const card = image
        ? el("button", { type: "button", class: "sent-attachment is-image", "aria-label": `View ${attachment.name}`,
                        onclick: () => openAttachmentPreview(sentAttachmentPreview(attachment)) }, media, meta)
        : el("a", { class: "sent-attachment is-file", href: attachmentUrl(attachment), target: "_blank", rel: "noopener",
                   "aria-label": `Open ${attachment.name}` }, media, meta);
      return el("div", { role: "listitem" }, card);
    }));
}

// MARK: sending — a stable snapshot of text and ready attachments, cleared only once the server confirms.

async function sendMessage(session) {
  if (state.sending.has(session.id)) return;   // one send in flight at a time; this also blocks Enter
  const textarea = $("composer-text");
  const list = attachmentsFor(session.id);
  if (list.some((a) => a.status !== "ready")) return;
  const text = textarea.value.trim();
  const ids = list.map((a) => a.attachment.id);
  if (!text && !ids.length) return;
  const id = state.pendingMessageIds.get(session.id) ?? crypto.randomUUID();
  state.pendingMessageIds.set(session.id, id);
  const keys = new Set(list.map((a) => a.key));
  state.sending.set(session.id, { text, keys });
  state.composerErrors.delete(session.id);
  renderComposer(session);
  try {
    const receipt = await api("POST", `/api/sessions/${session.id}/messages`, { id, text, attachments: ids });
    state.messages.set(receipt.id, receipt);
    state.pendingMessageIds.delete(session.id);
    for (const attachment of attachmentsFor(session.id)) if (keys.has(attachment.key) && attachment.localUrl) {
      URL.revokeObjectURL(attachment.localUrl);
    }
    state.attachments.set(session.id, attachmentsFor(session.id).filter((a) => !keys.has(a.key)));
    textarea.value = "";
    state.composerDrafts.delete(session.id);
    state.interrupted.delete(session.id);
    autosizeComposer(textarea);
  } catch (error) {
    // Not confirmed: the text and every attachment (even the ones just sent) stay in the draft, and the
    // same message id is kept, so retrying never creates a duplicate prompt once the server does confirm.
    state.composerErrors.set(session.id, error.message);
  } finally {
    state.sending.delete(session.id);
    renderComposer(session);
  }
}

function autosizeComposer(textarea) {
  textarea.style.height = "auto";
  textarea.style.height = Math.min(textarea.scrollHeight, 160) + "px";
}

$("composer").addEventListener("submit", (event) => {
  event.preventDefault();
  const session = selected();
  if (session) sendMessage(session);
});

// MARK: the "+" menu/sheet — a small anchored menu on desktop, a bottom sheet on mobile; same two choices.

let attachMenuButton = null;   // the "+" a desktop menu is currently open for, to return focus to on close

// With a single kind "+" opens the picker itself, so it is not a menu button and is named for what it does.
if (ATTACH_KINDS.length === 1) {
  for (const button of [$("composer-attach"), $("terminal-attach")]) {
    button.removeAttribute("aria-haspopup");
    button.removeAttribute("aria-expanded");
    button.title = "Add files";
    button.setAttribute("aria-label", "Add files");
  }
}

function attachChoiceButtons(onPick, menuRole) {
  return ATTACH_KINDS.map((kind) => el("button", { type: "button", class: "attach-menu-item", role: menuRole ? "menuitem" : undefined,
    onclick: () => onPick(kind) }, icon(kind.icon), el("span", {}, el("strong", {}, kind.label), el("small", {}, kind.description))));
}

/// The "+" menu, shared by the chat composer and the terminal input bar: `onFiles` receives what was picked.
function openAttachMenu(button, onFiles, { multiple }) {
  if (ATTACH_KINDS.length === 1) return pickAttachment(ATTACH_KINDS[0], onFiles, multiple);
  if (isMobile()) return openAttachSheet(button, onFiles, multiple);
  const menu = $("attach-menu");
  if (!menu.hidden && menu.parentElement === button.parentElement) return closeAttachMenu();
  menu.replaceChildren(...attachChoiceButtons((kind) => { closeAttachMenu(false); pickAttachment(kind, onFiles, multiple); }, true));
  button.parentElement.append(menu);   // positioned against the input's own box, which moves with the keyboard
  menu.hidden = false;
  attachMenuButton = button;
  button.setAttribute("aria-expanded", "true");
  menu.querySelector("button")?.focus();
}

function closeAttachMenu(returnFocus = true) {
  $("attach-menu").hidden = true;
  document.querySelectorAll("[aria-haspopup=menu]").forEach((b) => b.setAttribute("aria-expanded", "false"));
  if (returnFocus) attachMenuButton?.focus();
  attachMenuButton = null;
}

/// The mobile bottom sheet; a native <dialog> handles Esc and restores focus to `button` on its own.
function openAttachSheet(button, onFiles, multiple) {
  $("attach-sheet-choices").replaceChildren(
    ...attachChoiceButtons((kind) => { $("attach-sheet").close(); pickAttachment(kind, onFiles, multiple); }, false));
  button.setAttribute("aria-expanded", "true");
  $("attach-sheet").showModal();
}
$("attach-sheet").addEventListener("close", () => {
  document.querySelectorAll("[aria-haspopup=menu]").forEach((b) => b.setAttribute("aria-expanded", "false"));
});
$("attach-sheet-close").onclick = () => $("attach-sheet").close();

function pickAttachment(kind, onFiles, multiple) {
  const input = $("attach-input");
  input.accept = kind.accept;
  input.multiple = multiple;
  input.onchange = () => {
    const files = [...input.files];
    input.value = "";   // picking the same file again still fires change
    if (files.length) onFiles(files);
  };
  input.click();
}

document.addEventListener("click", (event) => {
  if (!$("attach-menu").hidden && !event.target.closest("#attach-menu, [aria-haspopup=menu]")) closeAttachMenu(false);
});
document.addEventListener("keydown", (event) => {
  const menu = $("attach-menu");
  if (menu.hidden) return;
  if (event.key === "Escape") { event.preventDefault(); closeAttachMenu(); }
  else if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
    event.preventDefault();
    const items = [...menu.querySelectorAll("button")];
    const index = items.indexOf(document.activeElement);
    const next = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1
      : (index + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
    items[next]?.focus();
  }
});

$("composer-attach").onclick = (event) => openAttachMenu(event.currentTarget, (files) => {
  const session = selected();
  if (session) addFiles(session, files);
}, { multiple: true });
// A screenshot or file on the clipboard (desktop) or dragged in becomes an attachment instead of text.
$("composer-text").addEventListener("paste", (event) => {
  const session = selected();
  const files = [...(event.clipboardData?.files ?? [])];
  if (!session || !files.length) return;
  event.preventDefault();
  addFiles(session, files);
});
$("composer").addEventListener("dragover", (event) => { event.preventDefault(); $("composer").classList.add("is-dragging"); });
$("composer").addEventListener("dragleave", (event) => {
  if (!$("composer").contains(event.relatedTarget)) $("composer").classList.remove("is-dragging");
});
$("composer").addEventListener("drop", (event) => {
  $("composer").classList.remove("is-dragging");
  const session = selected();
  if (!session || !event.dataTransfer?.files.length) return;
  event.preventDefault();
  addFiles(session, [...event.dataTransfer.files]);
});
// The terminal bar has no attachment strip: the uploaded path goes into its input, to send like any text.
$("terminal-attach").onclick = (event) => openAttachMenu(event.currentTarget, async ([file]) => {
  const session = selected();
  if (!session) return;
  const input = $("terminal-send-input");
  input.placeholder = `Uploading ${file.name || "file"}…`;
  try {
    const path = await uploadFile(session.id, file);
    input.value = [input.value.trim(), path].filter(Boolean).join(" ");
    state.terminalInputDrafts.set(session.id, input.value);
  } catch (error) {
    alert(error.message);
  } finally {
    input.placeholder = "Add to this session…";
  }
}, { multiple: false });
$("composer-text").addEventListener("input", (event) => {
  autosizeComposer(event.target);
  const session = selected();
  if (session) { state.composerDrafts.set(session.id, event.target.value); state.composerErrors.delete(session.id); }
});
$("composer-text").addEventListener("keydown", (event) => {
  if (event.key !== "Enter" || event.shiftKey || isMobile()) return;
  event.preventDefault();
  const session = selected();
  // The Send button's own disabled state is the one source of truth for "an attachment isn't ready yet".
  if (session && !$("composer-send").disabled) sendMessage(session);
});

// MARK: Terminal's note about the Chat draft — the terminal's own send never includes these attachments.

function renderTerminalAttachmentsNote(session) {
  const list = attachmentsFor(session.id);
  $("terminal-attachments-note").hidden = !list.length;
  if (list.length) {
    $("terminal-attachments-note-text").textContent = `${list.length} attachment${list.length === 1 ? "" : "s"} in the Chat draft`;
  }
}
$("terminal-attachments-note-view").onclick = () => {
  const session = selected();
  if (session) showView(session, "chat");
};

// MARK: terminal view

function showTerminal(session) {
  $("terminal-empty").hidden = true;
  let entry = state.terminals.get(session.id);
  if (!entry) {
    const node = el("div", { class: "term-pane", onmousedown: () => requestAnimationFrame(() => entry?.term.focus()) });
    $("terminals").append(node);
    const term = new Terminal({ fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace', fontSize: 13,
                                theme: { background: "#1e1e22", foreground: "#ccd3db", cursor: "#ccd3db",
                                        selectionBackground: "#263854", black: "#2a2a30", red: "#f38ba8",
                                        green: "#a6e3a1", yellow: "#ffe14a", blue: "#5aa0ff", magenta: "#c5a3ff",
                                        cyan: "#8abeb7", white: "#ccd3db", brightBlack: "#676c74", brightRed: "#ff9eb8",
                                        brightGreen: "#b5e8b0", brightYellow: "#fff08a", brightBlue: "#8cbcff",
                                        brightMagenta: "#d7bfff", brightCyan: "#a8d8d2", brightWhite: "#ffffff" },
                                cursorBlink: true, allowProposedApi: true, scrollback: 10000,
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
  // Leave focus alone while a dialog, Settings or a rename field has it.
  if (!document.querySelector("dialog[open]") && !state.settingsOpen && state.renamingSelected !== session.id) {
    entry.term.focus();
  }
}

/// Saves a file (an image, a document…) in the session's folder on the server and returns its path there.
/// The path goes into the prompt; an agent attaches an image from it and reads other files with its tools.
async function uploadFile(sessionId, file) {
  let response;
  try {
    response = await fetch(`/api/sessions/${sessionId}/files?name=${encodeURIComponent(file.name || "file")}`, {
      method: "POST", headers: { Authorization: "Bearer " + state.token, "Content-Type": file.type || "application/octet-stream" },
      body: file,
    });
  } catch {
    throw new Error("Couldn't reach the server. Check your connection and try again.");
  }
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error?.message ?? response.statusText);
  return body.path;
}

async function pasteImages(entry, files) {
  for (const file of files) {
    try { entry.term.paste(await uploadFile(entry.id, file)); } catch (error) { alert(error.message); }
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

// MARK: mobile terminal input bar — a text field plus a row of common TUI keys, for phones without a keyboard
// row. Writes straight to the PTY over the same WebSocket the xterm instance itself uses.

let lastTerminalInputSessionId = null;

function renderTerminalInputBar(session) {
  if (lastTerminalInputSessionId !== session.id) {
    $("terminal-send-input").value = state.terminalInputDrafts.get(session.id) ?? "";
    lastTerminalInputSessionId = session.id;
  }
}

$("terminal-send-input").addEventListener("input", (event) => {
  const session = selected();
  if (session) state.terminalInputDrafts.set(session.id, event.target.value);
});
$("terminal-send-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const session = selected();
  const entry = session && state.terminals.get(session.id);
  const input = $("terminal-send-input");
  if (!entry || !input.value) return;
  send(entry, { type: "input", data: input.value + "\r" });
  input.value = "";
  state.terminalInputDrafts.delete(session.id);
});
const TERMINAL_KEYS = { esc: "\u001b", up: "\u001b[A", down: "\u001b[B", tab: "\t", enter: "\r" };
document.querySelectorAll(".terminal-keys button").forEach((button) => {
  button.onclick = () => {
    const session = selected();
    const entry = session && state.terminals.get(session.id);
    if (entry) send(entry, { type: "input", data: TERMINAL_KEYS[button.dataset.key] });
    entry?.term.focus();
  };
});

// MARK: agent glyphs

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
  if (isMobile()) setSidebarOpen(false);   // from the drawer (or anywhere else) — never show it under the dialog
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
  // Real buttons acting as a radio group, so Tab reaches them and assistive tech reads the choice.
  $("new-agents").setAttribute("role", "radiogroup");
  $("new-agents").setAttribute("aria-label", "Agent");
  $("new-agents").replaceChildren(...state.agents.map((agent) => el("button", {
    type: "button", role: "radio", "aria-checked": String(agent.id === newSession.agentId), disabled: !agent.location,
    class: "agent-card" + (agent.id === newSession.agentId ? " selected" : "") + (agent.location ? "" : " missing"),
    title: agent.location ?? agent.missingHint,
    onclick: () => { newSession.agentId = agent.id; renderNewAgents(); },
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
$("close-new").onclick = () => $("new-dialog").close();
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

// Alt+N: another session next to the selected one, with the same agent (⌘N belongs to the browser).
// Captured before the terminal, which would otherwise also type the key.
document.addEventListener("keydown", async (event) => {
  if (!(event.altKey && !event.metaKey && !event.ctrlKey && event.code === "KeyN")) return;
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

// MARK: settings — a full page (not a modal): a left category list plus a right detail pane on desktop,
// an overview list that drills into one agent (or General) on mobile. See docs' settings §7.

function openSettings() {
  if (isMobile()) setSidebarOpen(false);   // from the drawer (or anywhere else) — never show it under settings
  loadAgents().then(() => { state.settingsOpen = true; render(); }).catch(() => {});
}
/// Closing just flips settingsOpen back off; state.selectedId was never touched by opening it, so this
/// naturally returns to wherever settings was opened from — home or the session that was selected.
function closeSettings() {
  state.settingsOpen = false;
  render();
}
$("settings-back").onclick = () => {
  if (isMobile() && state.settingsSection !== "overview") { state.settingsSection = "overview"; renderSettings(); }
  else closeSettings();
};

let savedUntil = 0;
function settingsIdleLabel() { return state.online ? "Changes save automatically" : "Reconnect to make changes"; }
function markSaved() {
  savedUntil = Date.now() + 2000;
  renderSettings();
  setTimeout(renderSettings, 2000);
}

function modelLabel(agent) {
  const modelOption = agent.options.find((o) => o.id === "model");
  const choice = modelOption?.choices.find((c) => c.value === agent.defaultModel);
  if (choice) return choice.detail ? `${choice.label} — ${choice.detail}` : choice.label;
  return agent.defaultModel;
}

function settingsOverview() {
  return el("div", { class: "settings-overview" },
    el("div", { class: "settings-intro" }, el("h1", {}, "Settings"),
      el("p", {}, "Manage cloud agents, and defaults for new sessions.")),
    el("h2", { class: "settings-group-label" }, "Agent"),
    el("div", {}, state.agents.map((agent) => el("button", { class: "settings-agent-row", type: "button",
        onclick: () => { state.settingsSection = agent.id; renderSettings(); } },
      glyphSVG(agent.glyph, 29),
      el("span", {}, el("strong", {}, agent.name),
        el("small", {}, agent.defaultModel ? `Default model: ${modelLabel(agent)}` : "Follows agent settings")),
      icon("chevron-right")))),
    el("h2", { class: "settings-group-label general-group" }, "Server"),
    el("button", { class: "settings-agent-row", type: "button",
                  onclick: () => { state.settingsSection = "general"; renderSettings(); } },
      el("span", { class: "general-glyph" }, icon("server")),
      el("span", {}, el("strong", {}, "General"), el("small", {}, "Session restore, notifications")),
      icon("chevron-right")),
    el("p", { class: "settings-overview-note" }, icon("cloud"), state.online ? "Connected" : "Not connected"));
}

function optionRow(agent, option) {
  const value = agent.preferences[option.id];
  const disabled = !state.online;
  const label = el("div", { class: "setting-description" },
    el("label", {}, option.title), option.note ? el("p", {}, option.note) : null);
  let control;
  if (option.kind === "toggle") {
    const forced = agent.forcedOn.includes(option.id);
    const checked = forced || (value === undefined ? option.toggleDefault : value === "true");
    control = el("label", { class: "settings-switch" },
      el("input", { type: "checkbox", checked, disabled: forced || disabled, "aria-label": option.title,
                    onchange: (e) => setOption(agent, option, e.target.checked ? "true" : "false") }),
      el("span"));
  } else {
    const known = option.choices.some((c) => c.value === value);
    const custom = value !== undefined && !known;
    const select = el("select", { disabled, "aria-label": option.title },
      el("option", { value: "" }, `Follow ${agent.name} settings`),
      ...option.choices.map((c) => el("option", { value: c.value }, c.detail ? `${c.label} — ${c.detail}` : c.label)),
      ...(option.allowsCustom ? [el("option", { value: CUSTOM }, "Custom…")] : []));
    select.value = custom ? CUSTOM : value ?? "";
    const input = el("input", { type: "text", placeholder: `Custom ${option.title.toLowerCase()}`, "aria-label": `Custom ${option.title}`,
                                value: custom ? value : "", hidden: !custom, disabled,
                                onchange: (e) => setOption(agent, option, e.target.value.trim() || null) });
    select.onchange = () => {
      if (select.value === CUSTOM) { input.hidden = false; input.focus(); }
      else { input.hidden = true; setOption(agent, option, select.value || null); }
    };
    control = el("div", { class: "setting-control" }, select, input);
  }
  return el("div", { class: "setting-row" + (option.kind === "toggle" ? " toggle-row" : " select-row") }, label, control);
}

async function setOption(agent, option, value) {
  try {
    await api("PUT", `/api/agents/${agent.id}/options/${option.id}`, { value });
    await loadAgents();
    markSaved();
  } catch (error) { alert(error.message); }
}

function agentPage(agent) {
  return [
    el("header", { class: "settings-agent-header" }, glyphSVG(agent.glyph, 38),
      el("div", {}, el("h1", {}, agent.name), el("p", {}, "Defaults for new sessions")),
      el("span", { class: "installed-status" + (agent.location ? "" : " missing") },
         icon(agent.location ? "circle-check" : "x"), agent.location ? "Found" : "Not found")),
    el("div", { class: "agent-location" }, icon("terminal-2"),
       agent.location ? el("code", {}, agent.location) : el("span", {}, agent.missingHint)),
    el("section", { class: "settings-section" }, agent.options.map((option) => optionRow(agent, option))),
  ];
}

function generalPage() {
  const disabled = !state.online;
  return [
    el("header", { class: "settings-agent-header" }, el("span", { class: "general-glyph large" }, icon("server")),
      el("div", {}, el("h1", {}, "General"), el("p", {}, "AgentMaster server"))),
    el("section", { class: "settings-section" },
      el("div", { class: "setting-row toggle-row" },
        el("div", { class: "setting-description" }, el("label", {}, "Restore sessions on launch"),
          el("p", {}, "Sessions open when the server stops come back, resuming their conversations.")),
        el("label", { class: "settings-switch" },
          el("input", { type: "checkbox", checked: state.restoreSessionsOnLaunch, disabled, "aria-label": "Restore sessions on launch",
            onchange: async (e) => {
              try {
                await api("PUT", "/api/general", { restoreSessionsOnLaunch: e.target.checked });
                state.restoreSessionsOnLaunch = e.target.checked;
                markSaved();
              } catch (error) { alert(error.message); }
            } }), el("span")))),
    el("h2", { class: "settings-group-label" }, "Notifications"),
    notificationsSection(),
  ];
}

function renderSettings() {
  if (!isMobile() && state.settingsSection === "overview") state.settingsSection = state.agents[0]?.id ?? "general";
  const overview = isMobile() && state.settingsSection === "overview";
  const agent = state.agents.find((a) => a.id === state.settingsSection);

  $("settings-back-label").textContent = isMobile() ? (overview ? "Sessions" : "Settings") : "Back";
  $("settings-save-state").hidden = overview;
  if (!overview) {
    $("settings-save-state").replaceChildren(
      Date.now() < savedUntil ? icon("check") : icon(state.online ? "cloud" : "wifi-off"),
      el("span", {}, Date.now() < savedUntil ? "Saved" : settingsIdleLabel()));
  }

  $("settings-sidebar").replaceChildren(
    el("h1", {}, "Settings"), el("p", {}, "Agent"),
    ...state.agents.map((item) => el("button", { type: "button", class: state.settingsSection === item.id ? "active" : "",
      onclick: () => { state.settingsSection = item.id; renderSettings(); } }, glyphSVG(item.glyph, 18), item.name)),
    el("div", { class: "settings-nav-divider" }),
    el("button", { type: "button", class: state.settingsSection === "general" ? "active" : "",
      onclick: () => { state.settingsSection = "general"; renderSettings(); } }, icon("server"), "General"));

  $("settings-detail-scroll").replaceChildren(
    overview ? settingsOverview() : el("div", { class: "settings-page-content" }, agent ? agentPage(agent) : generalPage()));
  $("settings-scope").hidden = overview;
  if (!overview) {
    $("settings-scope").replaceChildren(icon("history"),
      el("p", {}, agent ? "Changes apply to new sessions; running sessions keep their settings."
                         : "Settings apply to the AgentMaster server; this does not depend on a browser tab staying open."));
  }
}

// MARK: push notifications

/// iOS Safari only grants Web Push to a PWA added to the home screen; everywhere else, service workers
/// and the Push API are the only requirement.
function pushSupportStatus() {
  // iPadOS asks for desktop sites by default and then reports itself as a Mac with a touch screen.
  const isIOS = /iP(hone|od|ad)/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
  const standalone = navigator.standalone === true || window.matchMedia("(display-mode: standalone)").matches;
  if (isIOS && !standalone) return "needs-install";
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) return "unsupported";
  return "ok";
}

/// The service worker's registration, or an error saying why there is none, instead of waiting forever
/// on `navigator.serviceWorker.ready` when it never installed.
async function serviceWorkerRegistration() {
  if (serviceWorkerError) throw new Error("The service worker did not register: " + serviceWorkerError);
  const timeout = new Promise((_, reject) =>
    setTimeout(() => reject(new Error("The service worker did not start. Reload the page and try again.")), 5000));
  return Promise.race([navigator.serviceWorker.ready, timeout]);
}

function notificationsSection() {
  const status = pushSupportStatus();
  const note = status === "unsupported" ? "Push notifications are not supported in this browser."
    : status === "needs-install" ? "Add to Home Screen first, then open AgentMaster from there to enable notifications."
    : null;
  if (note) {
    return el("div", { class: "setting-row" },
      el("div", { class: "setting-description" }, el("label", {}, "Notifications on this device"), el("p", {}, note)));
  }
  const container = el("section", { class: "settings-section" });
  loadNotificationsSection(container);
  return container;
}

async function loadNotificationsSection(container) {
  let subscription = null;
  let devices = [];
  let problem = null;
  try {
    subscription = await (await serviceWorkerRegistration()).pushManager.getSubscription();
  } catch (error) { problem = error.message; }
  try {
    devices = (await api("GET", "/api/push/subscriptions")).subscriptions;
  } catch {}
  container.replaceChildren(
    el("div", { class: "setting-row" },
      el("div", { class: "setting-description" }, el("label", {}, "Notifications on this device"),
        el("p", {}, problem ?? (subscription ? "Enabled on this device."
          : "Get notified when a session needs you, finishes a turn, or exits."))),
      subscription
        ? el("button", { type: "button", onclick: () => disableNotifications(container) }, "Disable")
        : el("button", { type: "button", class: "primary", onclick: () => enableNotifications(container) }, "Enable")),
    ...(devices.length ? [el("div", { class: "setting-row" },
      el("div", { class: "setting-description" }, el("label", {}, "Registered devices")),
      el("div", { class: "device-list" }, devices.map((device) => el("div", { class: "device-row" },
        el("span", {}, device.label || device.endpoint.slice(-24)),
        el("button", { type: "button", onclick: () => removeDevice(device.endpoint, container) }, "Remove")))))] : []),
    el("div", { class: "setting-row" },
      el("div", { class: "setting-description" }, el("label", {}, "Test")),
      el("button", { type: "button", onclick: sendTestNotification }, "Send test notification")));
}

async function enableNotifications(container) {
  try {
    if (await Notification.requestPermission() !== "granted") throw new Error("Notifications permission was not granted.");
    const { publicKey } = await api("GET", "/api/push/key");
    const registration = await serviceWorkerRegistration();
    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(publicKey),
    });
    const json = subscription.toJSON();
    await api("POST", "/api/push/subscriptions", { endpoint: json.endpoint, keys: json.keys, label: shortUserAgent() });
  } catch (error) { alert(error.message); }
  loadNotificationsSection(container);
}

async function disableNotifications(container) {
  try {
    const registration = await serviceWorkerRegistration();
    const subscription = await registration.pushManager.getSubscription();
    if (subscription) {
      await api("DELETE", "/api/push/subscriptions", { endpoint: subscription.endpoint });
      await subscription.unsubscribe();
    }
  } catch (error) { alert(error.message); }
  loadNotificationsSection(container);
}

async function removeDevice(endpoint, container) {
  try { await api("DELETE", "/api/push/subscriptions", { endpoint }); } catch (error) { alert(error.message); }
  loadNotificationsSection(container);
}

async function sendTestNotification() {
  try { await api("POST", "/api/push/test"); } catch (error) { alert(error.message); }
}

/// A short label for the device list, e.g. "iPhone OS 17_5" instead of the whole user-agent string.
function shortUserAgent() {
  const match = navigator.userAgent.match(/(iPhone|iPad|Android|Macintosh|Windows)[^;)]*/);
  return (match ? match[0] : navigator.userAgent).slice(0, 60);
}

function urlBase64ToUint8Array(base64url) {
  const base64 = (base64url + "=".repeat((4 - (base64url.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from([...atob(base64)].map((c) => c.charCodeAt(0)));
}

// MARK: on-screen keyboard

/// iOS does not shrink the page for the on-screen keyboard: it scrolls the page up, which takes the top of
/// the pinned app off the screen. While the visible area is shorter than the layout (keyboard up), the app is
/// fitted to that visible area instead, so the toolbar stays and the input sits right above the keyboard.
function fitToVisibleArea() {
  const viewport = window.visualViewport;
  const app = $("app");
  const covered = viewport && window.matchMedia("(max-width: 700px)").matches && viewport.height < window.innerHeight - 1;
  app.style.height = covered ? viewport.height + "px" : "";
  app.style.bottom = covered ? "auto" : "";
  app.style.transform = covered ? `translateY(${viewport.offsetTop}px)` : "";
  // A shorter pane would hide the newest message behind the input; keep the bottom in view.
  if (state.chatStuck.get(state.selectedId) ?? true) {
    requestAnimationFrame(() => { const scroll = $("chat-scroll"); scroll.scrollTop = scroll.scrollHeight; });
  }
}
if (window.visualViewport) {
  window.visualViewport.addEventListener("resize", fitToVisibleArea);
  window.visualViewport.addEventListener("scroll", fitToVisibleArea);
}

let serviceWorkerError = null;
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").catch((error) => { serviceWorkerError = error.message || String(error); });
}

// Pasting the printed link into a tab that is already open only changes the hash; a notification click
// does the same with `#session=`, so both are handled on hashchange as well as on first load. Browser
// back/forward across the history entries select()/goHome() push also lands here, since they change the
// hash too — pushState/replaceState do not fire this on their own, so there is no risk of a loop.
window.addEventListener("hashchange", () => {
  if (/token=/.test(location.hash)) return start();
  applyLocationSelection();
});
start();
