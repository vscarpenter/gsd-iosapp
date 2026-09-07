import React from "react";
import { AbsoluteFill, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { HOOK } from "./beats";
import type { Aspect } from "./layout";
import { serif } from "./fonts";
import { color, springs } from "./theme";

const SIZES: Record<Aspect, { mark: number; headline: number; maxWidth: number }> = {
  "16x9": { mark: 132, headline: 112, maxWidth: 1400 },
  "9x16": { mark: 128, headline: 96, maxWidth: 900 },
  "1x1": { mark: 112, headline: 84, maxWidth: 900 },
};

// The landing page headline, verbatim: "right" and "done" carry the italic rust emphasis.
const WORDS: { text: string; emphasis: boolean }[] = [
  { text: "Get", emphasis: false },
  { text: "the", emphasis: false },
  { text: "right", emphasis: true },
  { text: "things", emphasis: false },
  { text: "done.", emphasis: true },
];

/** Three-second title card: the quadrant mark settles in, then the headline arrives word by word. */
export const Hook: React.FC<{ aspect: Aspect }> = ({ aspect }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const size = SIZES[aspect];
  const markIn = spring({ frame, fps, config: springs.calm });
  const exit = interpolate(frame, [HOOK.durationInFrames - 10, HOOK.durationInFrames], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <AbsoluteFill
      style={{
        backgroundColor: color.paper,
        justifyContent: "center",
        alignItems: "center",
        gap: size.headline * 0.4,
        opacity: exit,
      }}
    >
      <Img
        src={staticFile("brand/gsd-mark.svg")}
        style={{
          width: size.mark,
          height: size.mark,
          opacity: markIn,
          scale: String(0.8 + 0.2 * markIn),
        }}
      />
      <div
        style={{
          fontFamily: serif,
          fontSize: size.headline,
          fontWeight: 600,
          letterSpacing: "-0.025em",
          lineHeight: 1.04,
          color: color.ink,
          maxWidth: size.maxWidth,
          textAlign: "center",
          textWrap: "balance",
          display: "flex",
          flexWrap: "wrap",
          justifyContent: "center",
          columnGap: size.headline * 0.26,
        }}
      >
        {WORDS.map((word, i) => {
          const wordIn = spring({ frame: frame - 8 - i * 3, fps, config: springs.calm });
          return (
            <span
              key={word.text}
              style={{
                display: "inline-block",
                fontStyle: word.emphasis ? "italic" : "normal",
                color: word.emphasis ? color.rust : color.ink,
                opacity: wordIn,
                translate: `0px ${(1 - wordIn) * 30}px`,
              }}
            >
              {word.text}
            </span>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
