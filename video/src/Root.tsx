import "./index.css";
import React from "react";
import { Composition } from "remotion";
import { GSDVideo } from "./GSDVideo";

// Three cuts of the same 45-second video: 1350 frames at 30 fps each. Deliverables render to
// ../out/gsd-<aspect>.mp4 via scripts/render.sh.
export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="GSD16x9"
        component={GSDVideo}
        durationInFrames={1350}
        fps={30}
        width={1920}
        height={1080}
        defaultProps={{ aspect: "16x9" }}
      />
      <Composition
        id="GSD9x16"
        component={GSDVideo}
        durationInFrames={1350}
        fps={30}
        width={1080}
        height={1920}
        defaultProps={{ aspect: "9x16" }}
      />
      <Composition
        id="GSD1x1"
        component={GSDVideo}
        durationInFrames={1350}
        fps={30}
        width={1080}
        height={1080}
        defaultProps={{ aspect: "1x1" }}
      />
    </>
  );
};
