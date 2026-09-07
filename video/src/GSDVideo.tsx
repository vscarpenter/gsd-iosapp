import React from "react";
import { AbsoluteFill, Sequence, staticFile } from "remotion";
import { Audio } from "@remotion/media";
import { END_CARD, HOOK } from "./beats";
import { EndCard } from "./EndCard";
import { Hook } from "./Hook";
import type { Aspect } from "./layout";
import { Stage } from "./Stage";
import { color, sans } from "./theme";

/**
 * The whole 45-second video, shared by all three compositions. `aspect` picks the layout; the
 * timeline (hook, five beats, end card) and the music are the same everywhere.
 */
export const GSDVideo: React.FC<{ aspect: Aspect }> = ({ aspect }) => {
  return (
    <AbsoluteFill style={{ backgroundColor: color.paper, fontFamily: sans, color: color.ink }}>
      {/* music.m4a is already trimmed to 45 s with a 2 s fade out (see scripts/make-music.sh). */}
      <Audio src={staticFile("music.m4a")} name="Music" />
      <Sequence name="Hook" from={HOOK.from} durationInFrames={HOOK.durationInFrames}>
        <Hook aspect={aspect} />
      </Sequence>
      <Sequence name="Stage" from={HOOK.durationInFrames} durationInFrames={END_CARD.from - HOOK.durationInFrames}>
        <Stage aspect={aspect} />
      </Sequence>
      <Sequence name="End card" from={END_CARD.from} durationInFrames={END_CARD.durationInFrames}>
        <EndCard aspect={aspect} />
      </Sequence>
    </AbsoluteFill>
  );
};
