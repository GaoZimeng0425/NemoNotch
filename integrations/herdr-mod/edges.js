// Pure edge rules of the NemoNotch Herdr mod — no Herdr imports, so node can
// test them (scripts/test-herdr-mod.sh). Contract: POST /v1/toast schema 1
// (README "External Toast API"); design docs/superpowers/specs/2026-11-12-herdr-mod-design.md.

// The two statuses that mean "come take over": done (finished while you
// weren't looking) and blocked (waiting on you).
const ATTENTION = new Set(["done", "blocked"]);
const WORD = { done: "跑完了", blocked: "等你回应" };
// Mirrors NemoNotch's herdrTerminal validation (ExternalToastPayload.swift):
// an address it would reject must not cost the whole card a 400.
const JUMPABLE = /^([A-Za-z0-9._-]{1,64}\/)?[A-Za-z0-9]{1,32}$/;

/** address -> status */
export function snapshot(agents) {
  return Object.fromEntries(agents.map((a) => [a.address, a.status]));
}

/**
 * What changed since `prev` (address -> status; null on the first run, which
 * only seeds the baseline). Entering done/blocked (or switching between them)
 * shows a card; leaving them, or vanishing while in them, closes it.
 */
export function diff(prev, agents) {
  if (prev === null) return { show: [], close: [] };
  const show = [];
  const close = [];
  const present = new Set();
  for (const a of agents) {
    present.add(a.address);
    const before = prev[a.address];
    if (before === a.status) continue;
    if (ATTENTION.has(a.status)) show.push(a);
    else if (ATTENTION.has(before)) close.push(a.address);
  }
  for (const [address, status] of Object.entries(prev)) {
    if (!present.has(address) && ATTENTION.has(status)) close.push(address);
  }
  return { show, close };
}

/**
 * On start: cards this mod left open (`openKeys`) whose agent is no longer
 * done/blocked — or gone — were handled while Herdr was closed; close them.
 */
export function firstRun(agents, openKeys) {
  const now = snapshot(agents);
  return { close: openKeys.filter((key) => !ATTENTION.has(now[key])) };
}

// Herdr's agent kind (`claude-code`, …) -> NemoNotch's own brand mark
// (`icon: "ai:<source>"`). Prefix match so a renamed variant still lands;
// anything else gets a terminal symbol rather than the blank generic mark.
const AI_MARKS = [
  ["claude", "ai:claude"],
  ["opencode", "ai:opencode"],
  ["gemini", "ai:gemini"],
  ["zcode", "ai:zcode"],
];

export function iconFor(app) {
  const name = (app ?? "").toLowerCase();
  const hit = AI_MARKS.find(([prefix]) => name.startsWith(prefix));
  return hit ? hit[1] : "sf:terminal";
}

function clip(text, max) {
  return Array.from(text).slice(0, max).join("");
}

/** The /v1/toast body for an agent that just entered done/blocked. */
export function card(agent) {
  const blocked = agent.status === "blocked";
  const parts = [WORD[agent.status], agent.app, agent.title].filter((p) => p);
  const body = {
    schema: 1,
    app: "Herdr",
    key: agent.address,
    title: clip(`${agent.space_name} / ${agent.tab_name}`, 120),
    body: clip(parts.join(" · "), 280),
    tone: blocked ? "approve" : "done",
    icon: iconFor(agent.app),
    jumpBundleId: "dev.herdr.app",
  };
  if (JUMPABLE.test(agent.address) && !agent.address.startsWith("-")) body.herdrTerminal = agent.address;
  if (blocked) body.expiresAt = "infinity";
  return body;
}

export function closeBody(address) {
  return { schema: 1, app: "Herdr", key: address, action: "close" };
}

/**
 * A single-lane runner: each task starts after the previous one settled, so
 * a card's show and close reach NemoNotch in edge order (independent requests
 * can arrive close-before-show and leave a never-expiring card behind).
 * A failed task never blocks the lane.
 */
export function serial() {
  let tail = Promise.resolve();
  return (task) => {
    const run = tail.then(task);
    tail = run.catch(() => {});
    return run;
  };
}

/**
 * Races `task()` against `wait()` (the caller's timer, e.g. cx.sleep): a push
 * that hangs must not hold the serial lane — and every later close — forever.
 */
export function bounded(task, wait) {
  return Promise.race([
    task(),
    wait().then(() => {
      throw new Error("push timed out");
    }),
  ]);
}
