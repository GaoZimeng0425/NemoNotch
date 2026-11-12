// node --test: pure edge rules of the NemoNotch Herdr mod (no Herdr needed).
import test from "node:test";
import assert from "node:assert/strict";
import { diff, firstRun, card, closeBody, snapshot, serial, bounded } from "./edges.js";

const agent = (address, status, extra = {}) => ({
  address, status, space_name: "NemoNotch", tab_name: "fix", app: "claude-code", title: "Refactor", ...extra,
});

test("first run (prev null) emits nothing", () => {
  assert.deepEqual(diff(null, [agent("t1", "done")]), { show: [], close: [] });
});

test("entering done or blocked shows; leaving them closes; vanishing closes", () => {
  const prev = { t1: "working", t2: "idle", t3: "done", t4: "blocked", t5: "blocked" };
  const now = [agent("t1", "done"), agent("t2", "blocked"), agent("t3", "idle"), agent("t4", "working")];
  const out = diff(prev, now);
  assert.deepEqual(out.show.map((a) => a.address), ["t1", "t2"]);
  assert.deepEqual(out.close.sort(), ["t3", "t4", "t5"]);
});

test("done <-> blocked re-shows in place; unchanged status does nothing", () => {
  const out = diff({ t1: "done", t2: "blocked", t3: "working" },
    [agent("t1", "blocked"), agent("t2", "done"), agent("t3", "working")]);
  assert.deepEqual(out.show.map((a) => a.address), ["t1", "t2"]);
  assert.deepEqual(out.close, []);
});

test("firstRunClosesStaleOnly: remembered keys no longer done/blocked (or gone) close", () => {
  const out = firstRun([agent("t1", "done"), agent("t2", "idle")], ["t1", "t2", "t3"]);
  assert.deepEqual(out.close, ["t2", "t3"]);
});

test("snapshot maps address to status", () => {
  assert.deepEqual(snapshot([agent("t1", "done"), agent("t2", "idle")]), { t1: "done", t2: "idle" });
});

test("done card: green, default expiry, Herdr jump", () => {
  assert.deepEqual(card(agent("t7", "done")), {
    schema: 1, app: "Herdr", key: "t7", title: "NemoNotch / fix", body: "跑完了 · claude-code · Refactor",
    tone: "done", herdrTerminal: "t7", jumpBundleId: "dev.herdr.app",
  });
});

test("blocked card: blue and never expires", () => {
  const body = card(agent("vps/t7", "blocked"));
  assert.equal(body.tone, "approve");
  assert.equal(body.expiresAt, "infinity");
  assert.equal(body.body, "等你回应 · claude-code · Refactor");
});

test("null app drops its segment; title 120 / body 280 truncation by character", () => {
  const long = "字".repeat(300);
  const body = card(agent("t1", "done", { app: null, title: long, space_name: long }));
  assert.equal(Array.from(body.title).length, 120);
  assert.equal(Array.from(body.body).length, 280);
  assert.ok(body.body.startsWith("跑完了 · 字"));
});

test("closeBody", () => {
  assert.deepEqual(closeBody("t7"), { schema: 1, app: "Herdr", key: "t7", action: "close" });
});

test("serial runs tasks in submit order even when an earlier one is slower", async () => {
  const run = serial();
  const order = [];
  const slow = run(() => new Promise((resolve) => setTimeout(() => { order.push("show"); resolve(); }, 30)));
  const fast = run(async () => { order.push("close"); });
  await Promise.all([slow, fast]);
  assert.deepEqual(order, ["show", "close"]);
});

test("serial keeps going after a task throws", async () => {
  const run = serial();
  const order = [];
  run(async () => { throw new Error("NemoNotch down"); });
  await run(async () => { order.push("next"); });
  assert.deepEqual(order, ["next"]);
});

test("an address NemoNotch would reject drops herdrTerminal instead of losing the card", () => {
  const body = card(agent("my box/t7", "done"));
  assert.equal(body.herdrTerminal, undefined);
  assert.equal(body.key, "my box/t7");
  assert.equal(body.jumpBundleId, "dev.herdr.app");
  assert.equal(card(agent("vps/t7", "done")).herdrTerminal, "vps/t7");
  assert.equal(card(agent("-x/t7", "done")).herdrTerminal, undefined);
});

test("a hung push gives up after its wait, so the lane keeps moving", async () => {
  const run = serial();
  const order = [];
  const hung = run(() => bounded(() => new Promise(() => {}), () => Promise.resolve()));
  await assert.rejects(hung, /timed out/);
  await run(async () => { order.push("close"); });
  assert.deepEqual(order, ["close"]);
});

test("bounded returns the task's value when it finishes first", async () => {
  const value = await bounded(async () => 7, () => new Promise(() => {}));
  assert.equal(value, 7);
});
