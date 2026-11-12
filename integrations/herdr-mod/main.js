// NemoNotch for Herdr: pushes a card to NemoNotch (POST /v1/toast) when an
// agent finishes unseen (green) or waits on you (blue, stays until handled),
// and closes it once you look / answer / the agent ends. Draws only a dot +
// "NemoNotch" in the sidebar's Spaces row (a kept frameless window: the main
// layout is read-only and mod.json docking doesn't take). Install with
// scripts/install-herdr-mod.sh. Edge rules live in ./edges.js (node-tested).
import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { agents, theme, layout, home, readTextFile } from "herdr";
import { diff, firstRun, card, closeBody, snapshot, serial, bounded } from "./edges.js";

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
    this.openKeys = new Set(this.loadKeys());
    this.lane = serial();
    cx.timer.every(HEALTH_EVERY_MS, (cx) => this.checkHealth(cx));
    this.checkHealth(cx);
  }

  loadKeys() {
    try {
      const keys = JSON.parse(localStorage.getItem(OPEN_KEYS) ?? "[]");
      return Array.isArray(keys) ? keys : [];
    } catch (_) {
      return [];
    }
  }

  saveKeys() {
    localStorage.setItem(OPEN_KEYS, JSON.stringify([...this.openKeys]));
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
        if (body.action === "close") this.openKeys.delete(body.key);
        else this.openKeys.add(body.key);
        this.saveKeys();
      } catch (_) {
        // NemoNotch not running, or the push timed out: nothing to do.
      }
    }));
  }

  track(cx) {
    const list = agents();
    if (this.prev === null) {
      for (const key of firstRun(list, [...this.openKeys]).close) this.send(cx, closeBody(key));
    } else {
      const { show, close } = diff(this.prev, list);
      for (const agent of show) this.send(cx, card(agent));
      for (const key of close) this.send(cx, closeBody(key));
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
