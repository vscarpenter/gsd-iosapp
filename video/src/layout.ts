// Pure layout math for the three aspect ratios. No React or Remotion imports, so the
// invariants (safe areas, no overlap, native clip ratios) are unit-tested with node --test.

export type Aspect = "16x9" | "9x16" | "1x1";
export const ASPECTS: Aspect[] = ["16x9", "9x16", "1x1"];

export const CANVAS: Record<Aspect, { width: number; height: number }> = {
  "16x9": { width: 1920, height: 1080 },
  "9x16": { width: 1080, height: 1920 },
  "1x1": { width: 1080, height: 1080 },
};

export type DeviceKind = "iphone" | "ipad";

/** Native pixel size of the normalized simulator clips (iPhone 17 Pro portrait, iPad Pro 13" landscape). */
export const CLIP_SIZE: Record<DeviceKind, { w: number; h: number }> = {
  iphone: { w: 1206, h: 2622 },
  ipad: { w: 2752, h: 2064 },
};

export type Rect = { x: number; y: number; w: number; h: number };

export type DevicePlacement = { kind: DeviceKind; rect: Rect; radius: number };

export type TypeScale = { headline: number; secondary: number; chip: number };

export type StageLayout = {
  devices: DevicePlacement[];
  /** Band reserved for captions; never overlaps a device. */
  caption: Rect;
  type: TypeScale;
};

/**
 * Text-safe region. 16:9 keeps 5% per edge. 9:16 keeps extra room top and bottom for the
 * overlays vertical players draw (account bar, captions, action rail). 1:1 keeps 72 px all round.
 */
export function safeArea(aspect: Aspect): Rect {
  const { width, height } = CANVAS[aspect];
  switch (aspect) {
    case "16x9":
      return { x: 96, y: 54, w: width - 192, h: height - 108 };
    case "9x16":
      return { x: 72, y: 192, w: width - 144, h: height - 192 - 288 };
    case "1x1":
      return { x: 72, y: 72, w: width - 144, h: height - 144 };
  }
}

const fitHeight = (kind: DeviceKind, h: number) => ({
  w: (h * CLIP_SIZE[kind].w) / CLIP_SIZE[kind].h,
  h,
});

/**
 * Devices fill the safe area above a caption band. 16:9 pairs the landscape iPad with the
 * iPhone; the vertical and square cuts center one iPhone. Nothing is letterboxed: the paper
 * background always fills the canvas and clips keep their native ratio.
 */
export function stageLayout(aspect: Aspect): StageLayout {
  const safe = safeArea(aspect);
  const { width } = CANVAS[aspect];

  if (aspect === "16x9") {
    const captionH = 160;
    const gap = 24;
    const h = safe.h - captionH - gap;
    const ipad = fitHeight("ipad", h);
    const iphone = fitHeight("iphone", h);
    const between = 64;
    const x0 = (width - (ipad.w + between + iphone.w)) / 2;
    return {
      devices: [
        { kind: "ipad", rect: { x: x0, y: safe.y, w: ipad.w, h }, radius: 28 },
        { kind: "iphone", rect: { x: x0 + ipad.w + between, y: safe.y, w: iphone.w, h }, radius: 28 },
      ],
      caption: { x: safe.x, y: safe.y + h + gap, w: safe.w, h: captionH },
      type: { headline: 60, secondary: 32, chip: 26 },
    };
  }

  if (aspect === "9x16") {
    const captionH = 220;
    const gap = 32;
    const h = safe.h - captionH - gap;
    const iphone = fitHeight("iphone", h);
    return {
      devices: [{ kind: "iphone", rect: { x: (width - iphone.w) / 2, y: safe.y, w: iphone.w, h }, radius: 36 }],
      caption: { x: safe.x, y: safe.y + h + gap, w: safe.w, h: captionH },
      type: { headline: 58, secondary: 34, chip: 28 },
    };
  }

  const captionH = 150;
  const gap = 24;
  const h = safe.h - captionH - gap;
  const iphone = fitHeight("iphone", h);
  return {
    devices: [{ kind: "iphone", rect: { x: (width - iphone.w) / 2, y: safe.y, w: iphone.w, h }, radius: 26 }],
    caption: { x: safe.x, y: safe.y + h + gap, w: safe.w, h: captionH },
    type: { headline: 50, secondary: 28, chip: 24 },
  };
}
