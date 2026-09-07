import React from "react";
import { AbsoluteFill, Sequence, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { BEATS, END_CARD, HOOK, XFADE, clipFrames } from "./beats";
import { Caption } from "./Caption";
import { ClipLayer, DeviceFrame } from "./DeviceClip";
import type { Aspect } from "./layout";
import { stageLayout } from "./layout";
import { springs } from "./theme";

/**
 * The product beats: device cards that spring up once after the hook and then stay put while the
 * footage inside them crossfades from beat to beat. Captions live in the band below the devices.
 * Frame 0 here is the end of the hook.
 */
export const Stage: React.FC<{ aspect: Aspect }> = ({ aspect }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const layout = stageLayout(aspect);
  const total = END_CARD.from - HOOK.durationInFrames;
  const enter = spring({ frame, fps, config: springs.calm, durationInFrames: 32 });
  const exit = interpolate(frame, [total - 12, total], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });

  return (
    <AbsoluteFill style={{ opacity: exit }}>
      {layout.devices.map((placement) => (
        <div
          key={placement.kind}
          style={{
            position: "absolute",
            inset: 0,
            opacity: enter,
            translate: `0px ${(1 - enter) * 48}px`,
          }}
        >
          <DeviceFrame placement={placement}>
            {BEATS.map((beat, i) => {
              const clip = beat.clips[placement.kind];
              const fadeIn = i === 0 ? 0 : XFADE;
              const fadeOut = i === BEATS.length - 1 ? 0 : XFADE;
              const span = Math.min(beat.durationInFrames + fadeIn + fadeOut, clipFrames(clip).durationInFrames);
              return (
                <Sequence
                  key={beat.id}
                  name={`${placement.kind} ${beat.id}`}
                  from={beat.from - HOOK.durationInFrames - fadeIn}
                  durationInFrames={span}
                  premountFor={fps}
                >
                  <ClipLayer clip={clip} fadeIn={fadeIn} fadeOut={fadeOut} total={span} />
                </Sequence>
              );
            })}
          </DeviceFrame>
        </div>
      ))}
      {BEATS.map((beat) => (
        <Sequence
          key={beat.id}
          name={`Caption ${beat.id}`}
          from={beat.from - HOOK.durationInFrames}
          durationInFrames={beat.durationInFrames}
          layout="none"
        >
          <Caption
            headline={beat.caption}
            secondary={beat.secondary}
            chips={beat.chips}
            platforms={beat.platforms}
            box={layout.caption}
            type={layout.type}
            durationInFrames={beat.durationInFrames}
          />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};
