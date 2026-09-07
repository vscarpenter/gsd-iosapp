import React from "react";
import { OffthreadVideo, interpolate, staticFile, useCurrentFrame } from "remotion";
import type { DevicePlacement } from "./layout";
import type { Clip } from "./beats";
import { cardShadow, color } from "./theme";

/**
 * The device "card": the raw simulator frame with continuous-feeling rounded corners, the brand's
 * soft warm shadow, and a hairline edge. No fake bezel. Children are the clip layers.
 */
export const DeviceFrame: React.FC<{ placement: DevicePlacement; children: React.ReactNode }> = ({
  placement,
  children,
}) => {
  const { rect, radius } = placement;
  return (
    <div
      style={{
        position: "absolute",
        left: rect.x,
        top: rect.y,
        width: rect.w,
        height: rect.h,
        borderRadius: radius,
        overflow: "hidden",
        backgroundColor: color.surface,
        boxShadow: cardShadow,
      }}
    >
      {children}
      <div
        style={{
          position: "absolute",
          inset: 0,
          borderRadius: radius,
          boxShadow: `inset 0 0 0 2px ${color.hairline}`,
          pointerEvents: "none",
        }}
      />
    </div>
  );
};

/**
 * One beat's footage inside a frame. Plays from the clip's first frame; fades at the edges so
 * consecutive beats crossfade instead of jump-cutting between two seeded app states.
 */
export const ClipLayer: React.FC<{ clip: Clip; fadeIn: number; fadeOut: number; total: number }> = ({
  clip,
  fadeIn,
  fadeOut,
  total,
}) => {
  const frame = useCurrentFrame();
  const opacityIn = fadeIn > 0 ? interpolate(frame, [0, fadeIn], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }) : 1;
  const opacityOut =
    fadeOut > 0 ? interpolate(frame, [total - fadeOut, total], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }) : 1;
  return (
    <OffthreadVideo
      src={staticFile(clip.file)}
      muted
      style={{
        position: "absolute",
        inset: 0,
        width: "100%",
        height: "100%",
        objectFit: "cover",
        opacity: opacityIn * opacityOut,
      }}
    />
  );
};
