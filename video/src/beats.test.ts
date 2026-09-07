import { test } from "node:test";
import assert from "node:assert/strict";
import { BEATS, FPS, TOTAL_FRAMES, HOOK, END_CARD, XFADE, clipFrames } from "./beats.ts";

test("the video is exactly 45 seconds at 30 fps", () => {
  assert.equal(FPS, 30);
  assert.equal(TOTAL_FRAMES, 1350);
});

test("hook, beats, and end card tile the timeline with no gaps or overlaps", () => {
  const segments = [HOOK, ...BEATS, END_CARD];
  assert.equal(segments[0].from, 0);
  for (let i = 1; i < segments.length; i++) {
    assert.equal(segments[i].from, segments[i - 1].from + segments[i - 1].durationInFrames, `gap before ${segments[i].id}`);
  }
  const last = segments[segments.length - 1];
  assert.equal(last.from + last.durationInFrames, TOTAL_FRAMES);
});

test("the hook is 3 seconds and the end card is 5 seconds", () => {
  assert.equal(HOOK.durationInFrames, 3 * FPS);
  assert.equal(END_CARD.durationInFrames, 5 * FPS);
});

test("there are five beats: problem, three features, cross-platform", () => {
  assert.deepEqual(
    BEATS.map((b) => b.id),
    ["problem", "capture", "complete", "dashboard", "platforms"],
  );
});

test("every beat has an iPhone clip and an iPad clip, and each clip window is 6 to 10 seconds", () => {
  for (const beat of BEATS) {
    for (const kind of ["iphone", "ipad"] as const) {
      const clip = beat.clips[kind];
      assert.ok(clip, `${beat.id} has no ${kind} clip`);
      const seconds = clip.durationSeconds;
      assert.ok(seconds >= 6 && seconds <= 10, `${clip.file} is ${seconds}s`);
      // A clip also has to cover the crossfade on both sides of its beat, or the video runs dry.
      assert.ok(
        clipFrames(clip).durationInFrames >= beat.durationInFrames + 2 * XFADE,
        `${clip.file} cannot cover its beat plus the crossfades`,
      );
    }
  }
});

test("no caption carries an em dash or a double hyphen", () => {
  for (const beat of BEATS) {
    for (const line of [beat.caption, beat.secondary ?? ""]) {
      assert.ok(!/[—–]|--/.test(line), `${beat.id}: ${line}`);
    }
  }
});
