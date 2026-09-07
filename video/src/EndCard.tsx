import React from "react";
import { AbsoluteFill, Img, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { COMING_SOON, PLATFORMS } from "./beats";
import { Pill } from "./Caption";
import type { Aspect } from "./layout";
import { color, sans, springs } from "./theme";

const SIZES: Record<Aspect, { lockup: number; url: number; pill: number; tagline: number }> = {
  "16x9": { lockup: 760, url: 44, pill: 28, tagline: 26 },
  "9x16": { lockup: 700, url: 42, pill: 28, tagline: 26 },
  "1x1": { lockup: 620, url: 38, pill: 24, tagline: 22 },
};

/** Closing card: lockup, the site, the platforms, and the site's own tagline. Nothing exits. */
export const EndCard: React.FC<{ aspect: Aspect }> = ({ aspect }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const size = SIZES[aspect];
  const enter = (delay: number, config = springs.calm) => spring({ frame: frame - delay, fps, config });
  const lockupIn = enter(0);
  const urlIn = enter(8);
  const taglineIn = enter(28);

  return (
    <AbsoluteFill
      style={{
        backgroundColor: color.paper,
        justifyContent: "center",
        alignItems: "center",
        gap: size.url * 0.9,
      }}
    >
      <Img
        src={staticFile("brand/gsd-lockup-horizontal.svg")}
        style={{
          width: size.lockup,
          opacity: lockupIn,
          scale: String(0.94 + 0.06 * lockupIn),
          translate: `0px ${(1 - lockupIn) * 20}px`,
        }}
      />
      <div
        style={{
          fontFamily: sans,
          fontSize: size.url,
          fontWeight: 500,
          letterSpacing: "-0.01em",
          color: color.ink,
          opacity: urlIn,
          translate: `0px ${(1 - urlIn) * 18}px`,
        }}
      >
        gsdtaskmanager.com
      </div>
      <div style={{ display: "flex", flexWrap: "wrap", justifyContent: "center", gap: size.pill * 0.45, maxWidth: size.lockup * 1.3 }}>
        {PLATFORMS.map((name, i) => (
          <Pill key={name} size={size.pill} tone="neutral" progress={enter(14 + i * 4, springs.chip)}>
            {name}
          </Pill>
        ))}
        <Pill size={size.pill} tone="muted" progress={enter(14 + PLATFORMS.length * 4, springs.chip)}>
          {COMING_SOON}
        </Pill>
      </div>
      <div
        style={{
          fontFamily: sans,
          fontSize: size.tagline,
          fontWeight: 400,
          color: color.ink3,
          opacity: taglineIn,
          translate: `0px ${(1 - taglineIn) * 12}px`,
        }}
      >
        Free · Private · No sign-up
      </div>
    </AbsoluteFill>
  );
};
