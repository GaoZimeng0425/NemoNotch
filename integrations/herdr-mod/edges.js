// Pure edge rules of the NemoNotch Herdr mod — no Herdr imports, so node can
// test them (scripts/test-herdr-mod.sh). Contract: POST /v1/toast schema 1
// (README "External Toast API"); design docs/superpowers/specs/2026-11-12-herdr-mod-design.md.

// The two statuses that mean "come take over": done (finished while you
// weren't looking) and blocked (waiting on you).
const ATTENTION = new Set(["done", "blocked"]);
const WORD = { done: "跑完了", blocked: "等你回应" };

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
    herdrTerminal: agent.address,
    jumpBundleId: "dev.herdr.app",
  };
  if (blocked) body.expiresAt = "infinity";
  return body;
}

export function closeBody(address) {
  return { schema: 1, app: "Herdr", key: address, action: "close" };
}
