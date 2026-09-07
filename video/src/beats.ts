// The approved 45-second timeline (docs/superpowers/specs/2026-09-07-product-video-design.md).
// Pure data, no imports, so beats.test.ts can check the frame math with node --test.

export const FPS = 30;
export const TOTAL_FRAMES = 45 * FPS;
/** Frames of crossfade on each side of a beat boundary, so a clip must outlast its beat by 2 × XFADE. */
export const XFADE = 8;

export type DeviceKind = "iphone" | "ipad";

/** A normalized clip in public/captures. Durations must match scripts/capture-video-clips.sh. */
export type Clip = { file: string; durationSeconds: number };

export type Segment = { id: string; from: number; durationInFrames: number };

export type Chip = { token: string; label: string; tone: "rust" | "neutral" };

export type Beat = Segment & {
  caption: string;
  secondary?: string;
  chips?: Chip[];
  platforms?: boolean;
  clips: Record<DeviceKind, Clip>;
};

export const HOOK: Segment = { id: "hook", from: 0, durationInFrames: 3 * FPS };

const clip = (file: string, durationSeconds: number): Clip => ({ file: `captures/${file}.mp4`, durationSeconds });

export const BEATS: Beat[] = [
  {
    id: "problem",
    from: 3 * FPS,
    durationInFrames: 6 * FPS,
    caption: "Two questions sort every task into four quadrants.",
    clips: { iphone: clip("iphone-matrix", 8), ipad: clip("ipad-matrix", 7) },
  },
  {
    id: "capture",
    from: 9 * FPS,
    durationInFrames: 9 * FPS,
    caption: "Capture in one line.",
    chips: [
      { token: "!!", label: "Do First", tone: "rust" },
      { token: "#home", label: "adds the tag", tone: "neutral" },
    ],
    clips: { iphone: clip("iphone-capture", 9.6), ipad: clip("ipad-capture", 9.6) },
  },
  {
    id: "complete",
    from: 18 * FPS,
    durationInFrames: 8 * FPS,
    caption: "Swipe to finish.",
    clips: { iphone: clip("iphone-complete", 8.7), ipad: clip("ipad-complete", 8.7) },
  },
  {
    id: "dashboard",
    from: 26 * FPS,
    durationInFrames: 7 * FPS,
    caption: "See what you finished and what is overdue.",
    clips: { iphone: clip("iphone-dashboard", 8), ipad: clip("ipad-dashboard", 8) },
  },
  {
    id: "platforms",
    from: 33 * FPS,
    durationInFrames: 7 * FPS,
    caption: "Your tasks stay on your device unless you turn on sync.",
    platforms: true,
    clips: { iphone: clip("iphone-widget", 7.6), ipad: clip("ipad-drag", 7.6) },
  },
];

export const END_CARD: Segment = { id: "end", from: 40 * FPS, durationInFrames: 5 * FPS };

export const PLATFORMS = ["iPhone", "iPad", "Mac", "Web"] as const;
export const COMING_SOON = "Android coming soon";

export const clipFrames = (c: Clip) => ({ durationInFrames: Math.round(c.durationSeconds * FPS) });
