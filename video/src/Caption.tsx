import React from "react";
import { interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import type { Chip } from "./beats";
import { COMING_SOON, PLATFORMS } from "./beats";
import type { Rect, TypeScale } from "./layout";
import { serif } from "./fonts";
import { color, mono, sans, springs } from "./theme";

/** A pill in the brand's chip language: hairline border, pill radius, surface or wash fill. */
export const Pill: React.FC<{
  size: number;
  tone: "rust" | "neutral" | "muted";
  progress: number;
  children: React.ReactNode;
}> = ({ size, tone, progress, children }) => (
  <span
    style={{
      display: "inline-flex",
      alignItems: "baseline",
      gap: size * 0.35,
      padding: `${size * 0.28}px ${size * 0.8}px`,
      borderRadius: 999,
      border: `${Math.max(1, size / 14)}px solid ${tone === "rust" ? "transparent" : color.hairlineStrong}`,
      backgroundColor: tone === "rust" ? color.rustWash : tone === "muted" ? color.sunken : color.surface,
      color: tone === "rust" ? color.rust : tone === "muted" ? color.ink2 : color.ink,
      fontFamily: sans,
      fontSize: size,
      fontWeight: 500,
      lineHeight: 1.2,
      whiteSpace: "nowrap",
      opacity: progress,
      scale: String(0.9 + 0.1 * progress),
      translate: `0px ${(1 - progress) * 14}px`,
    }}
  >
    {children}
  </span>
);

const useEnter = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return {
    calm: (delay: number) => spring({ frame: frame - delay, fps, config: springs.calm }),
    chip: (delay: number) => spring({ frame: frame - delay, fps, config: springs.chip }),
    frame,
  };
};

/**
 * One beat's caption, inside the caption band. The headline settles in, the second line follows a
 * beat later, and chips or platform pills pop in one after another. Everything leaves faster than
 * it arrived (an 8-frame fade at the end of the beat).
 */
export const Caption: React.FC<{
  headline: string;
  secondary?: string;
  chips?: Chip[];
  platforms?: boolean;
  box: Rect;
  type: TypeScale;
  durationInFrames: number;
}> = ({ headline, secondary, chips, platforms, box, type, durationInFrames }) => {
  const { calm, chip, frame } = useEnter();
  const exit = interpolate(frame, [durationInFrames - 8, durationInFrames], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const headlineIn = calm(0);
  const secondIn = calm(6);

  return (
    <div
      style={{
        position: "absolute",
        left: box.x,
        top: box.y,
        width: box.w,
        height: box.h,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "flex-start",
        gap: type.secondary * 0.45,
        textAlign: "center",
        opacity: exit,
      }}
    >
      {platforms ? (
        <div style={{ display: "flex", gap: type.chip * 0.45, opacity: 1 }}>
          {PLATFORMS.map((name, i) => (
            <Pill key={name} size={type.chip} tone="neutral" progress={chip(i * 4)}>
              {name}
            </Pill>
          ))}
          <Pill size={type.chip} tone="muted" progress={chip(PLATFORMS.length * 4)}>
            {COMING_SOON}
          </Pill>
        </div>
      ) : null}
      <div
        style={{
          fontFamily: serif,
          fontSize: platforms ? type.headline * 0.72 : type.headline,
          fontWeight: 600,
          letterSpacing: "-0.015em",
          lineHeight: 1.12,
          color: color.ink,
          maxWidth: box.w,
          textWrap: "balance",
          opacity: platforms ? calm(PLATFORMS.length * 4 + 6) : headlineIn,
          translate: `0px ${(1 - (platforms ? calm(PLATFORMS.length * 4 + 6) : headlineIn)) * 24}px`,
        }}
      >
        {headline}
      </div>
      {secondary ? (
        <div
          style={{
            fontFamily: sans,
            fontSize: type.secondary,
            fontWeight: 400,
            lineHeight: 1.35,
            color: color.ink2,
            maxWidth: box.w,
            textWrap: "balance",
            opacity: secondIn,
            translate: `0px ${(1 - secondIn) * 18}px`,
          }}
        >
          {secondary}
        </div>
      ) : null}
      {chips ? (
        <div style={{ display: "flex", gap: type.chip * 0.5, marginTop: type.chip * 0.1 }}>
          {chips.map((c, i) => (
            <Pill key={c.token} size={type.chip} tone={c.tone} progress={chip(8 + i * 5)}>
              <span style={{ fontFamily: mono, fontWeight: 600 }}>{c.token}</span>
              <span>{c.label}</span>
            </Pill>
          ))}
        </div>
      ) : null}
    </div>
  );
};
