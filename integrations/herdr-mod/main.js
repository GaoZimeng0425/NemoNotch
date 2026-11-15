// NemoNotch for Herdr: pushes a card to NemoNotch (POST /v1/toast) when an
// agent finishes unseen (green) or waits on you (blue, stays until handled),
// and closes it once you look / answer / the agent ends. Draws only a dot +
// "NemoNotch" in the sidebar's Spaces row (a kept frameless window: the main
// layout is read-only and mod.json docking doesn't take). Install with
// scripts/install-herdr-mod.sh. Edge rules live in ./edges.js (node-tested).
import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { agents, panes, theme, layout, home, readTextFile } from "herdr";
import { diff, firstRun, card, closeBody, snapshot, serial, bounded, placeLabel } from "./edges.js";

const OPEN_KEYS = "nemonotch.openKeys";
const HEALTH_EVERY_MS = 30000;
const PUSH_TIMEOUT_MS = 5000;

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// Same signal as Herdr's own sidebar: folded = narrower than 160px.
const sidebarFolded = () => (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

async function endpoint() {
  const port = (await readTextFile(home() + "/.NemoNotch/hook-port"))?.trim() || "45831";
  const token = (await readTextFile(home() + "/.NemoNotch/hook-token"))?.trim() ?? "";
  return { base: `http://127.0.0.1:${port}`, token };
}

export default class NemoNotch extends View {
  init(_props, cx) {
    this.prev = null;
    this.reachable = false;
    // address -> the `app` (header) its open card was sent with: part of the
    // card's identity in NemoNotch, so a close must repeat it.
    this.openKeys = this.loadKeys();
    // address -> the header of the latest show queued: closes queued right
    // behind it (before its POST settles) still name the right card.
    this.headers = new Map(this.openKeys);
    this.lane = serial();
    cx.timer.every(HEALTH_EVERY_MS, (cx) => this.checkHealth(cx));
    this.checkHealth(cx);
  }

  loadKeys() {
    try {
      const saved = JSON.parse(localStorage.getItem(OPEN_KEYS) ?? "{}");
      // Older versions saved a plain address list, all sent as "Herdr".
      if (Array.isArray(saved)) return new Map(saved.map((key) => [key, "Herdr"]));
      return new Map(Object.entries(saved ?? {}).filter(([, app]) => typeof app === "string"));
    } catch (_) {
      return new Map();
    }
  }

  saveKeys() {
    localStorage.setItem(OPEN_KEYS, JSON.stringify(Object.fromEntries(this.openKeys)));
  }

  checkHealth(cx) {
    cx.spawn(async (cx) => {
      let ok = false;
      try {
        const { base } = await endpoint();
        ok = (await fetch(`${base}/health`)).ok;
      } catch (_) {
        ok = false;
      }
      if (ok !== this.reachable) {
        this.reachable = ok;
        cx.notify();
      }
    });
  }

  // One POST, queued on a single lane so show/close keep edge order, each
  // capped at PUSH_TIMEOUT_MS so a hung NemoNotch can't stall the lane; on 2xx
  // the open-key set follows. Failures are dropped (no retry): the next edge
  // for that agent brings things back in line.
  send(cx, body) {
    cx.spawn((cx) => this.lane(async () => {
      try {
        const { base, token } = await endpoint();
        const r = await bounded(() => fetch(`${base}/v1/toast`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-NemoNotch-Token": token },
          body: JSON.stringify(body),
        }), () => cx.sleep(PUSH_TIMEOUT_MS));
        if (!r.ok) return;
        if (body.action === "close") {
          if (this.openKeys.get(body.key) === body.app) this.openKeys.delete(body.key);
        } else {
          this.openKeys.set(body.key, body.app);
        }
        this.saveKeys();
      } catch (_) {
        // NemoNotch not running, or the push timed out: nothing to do.
      }
    }));
  }

  close(cx, key) {
    this.send(cx, closeBody(key, this.headers.get(key) ?? "Herdr"));
    this.headers.delete(key);
  }

  // Header for an agent's card: its pane's project + worktree (or branch).
  label(agent) {
    const pane = panes().find((p) => p.pane === agent.pane);
    return placeLabel(pane?.cwd, pane?.branch, agent.space_name);
  }

  track(cx) {
    const list = agents();
    if (this.prev === null) {
      for (const key of firstRun(list, [...this.openKeys.keys()]).close) this.close(cx, key);
    } else {
      const { show, close } = diff(this.prev, list);
      for (const agent of show) {
        const app = this.label(agent);
        // Moved folders since its last card: that card has another identity.
        // Fall back to the delivered header too: a close that was queued but
        // refused already dropped `headers`, yet that card may still be up.
        const before = this.headers.get(agent.address) ?? this.openKeys.get(agent.address);
        if (before !== undefined && before !== app) {
          this.send(cx, closeBody(agent.address, before));
        }
        this.headers.set(agent.address, app);
        this.send(cx, card(agent, app));
      }
      for (const key of close) this.close(cx, key);
    }
    this.prev = snapshot(list);
  }

  render(cx) {
    this.track(cx);
    if (sidebarFolded()) return div();
    const t = theme();
    return h_flex().id("root").size_full().gap(6).items_center().bg(t.chrome).text_size(11).text_color(t.muted)
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .child(div().size(6).rounded(3).bg(this.reachable ? t.done : t.dim))
      .child("NemoNotch");
  }
}
