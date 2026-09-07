import { test } from "node:test";
import assert from "node:assert/strict";
import { ASPECTS, CANVAS, CLIP_SIZE, safeArea, stageLayout, type Rect } from "./layout.ts";

const within = (inner: Rect, outer: Rect) =>
  inner.x >= outer.x - 0.01 &&
  inner.y >= outer.y - 0.01 &&
  inner.x + inner.w <= outer.x + outer.w + 0.01 &&
  inner.y + inner.h <= outer.y + outer.h + 0.01;

const overlaps = (a: Rect, b: Rect) =>
  a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

for (const aspect of ASPECTS) {
  const canvas = { x: 0, y: 0, w: CANVAS[aspect].width, h: CANVAS[aspect].height };
  const safe = safeArea(aspect);
  const layout = stageLayout(aspect);

  test(`${aspect}: safe area sits inside the canvas with real margins`, () => {
    assert.ok(within(safe, canvas));
    assert.ok(safe.x >= canvas.w * 0.05 - 0.01, "side margin under 5%");
    assert.ok(safe.y >= canvas.h * 0.05 - 0.01, "top margin under 5%");
  });

  test(`${aspect}: every device stays inside the safe area`, () => {
    for (const d of layout.devices) assert.ok(within(d.rect, safe), `${d.kind} leaves the safe area`);
  });

  test(`${aspect}: devices keep their clips' native aspect ratio (no stretch, no letterbox)`, () => {
    for (const d of layout.devices) {
      const native = CLIP_SIZE[d.kind].w / CLIP_SIZE[d.kind].h;
      assert.ok(Math.abs(d.rect.w / d.rect.h - native) < 0.002, `${d.kind} ratio drifted`);
    }
  });

  test(`${aspect}: the caption box is inside the safe area and clear of every device`, () => {
    assert.ok(within(layout.caption, safe));
    for (const d of layout.devices) assert.ok(!overlaps(layout.caption, d.rect), `caption overlaps ${d.kind}`);
  });

  test(`${aspect}: devices do not overlap each other`, () => {
    for (let i = 0; i < layout.devices.length; i++)
      for (let j = i + 1; j < layout.devices.length; j++)
        assert.ok(!overlaps(layout.devices[i].rect, layout.devices[j].rect));
  });
}

test("16x9 shows the iPad and the iPhone side by side", () => {
  const kinds = stageLayout("16x9").devices.map((d) => d.kind);
  assert.deepEqual(kinds, ["ipad", "iphone"]);
  const [ipad, iphone] = stageLayout("16x9").devices;
  assert.ok(ipad.rect.x + ipad.rect.w < iphone.rect.x, "iPad should sit left of the iPhone");
});

test("9x16 and 1x1 show a single centered iPhone", () => {
  for (const aspect of ["9x16", "1x1"] as const) {
    const { devices } = stageLayout(aspect);
    assert.equal(devices.length, 1);
    assert.equal(devices[0].kind, "iphone");
    const center = devices[0].rect.x + devices[0].rect.w / 2;
    assert.ok(Math.abs(center - CANVAS[aspect].width / 2) < 0.01, "iPhone is off center");
  }
});
