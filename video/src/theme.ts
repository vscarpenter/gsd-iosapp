// Brand tokens, copied from https://gsdtaskmanager.com/design.html (light appearance). The
// same values live in App/Theme/Theme.swift and QuadrantStyle.swift; nothing here is invented.

export const color = {
  paper: "#F4F1E9",
  sunken: "#ECE7DC",
  surface: "#FFFFFF",
  surface2: "#FBF9F3",
  hairline: "#E3DDD0",
  hairlineStrong: "#D8D1C1",
  ink: "#211E1A",
  ink2: "#6E6760",
  ink3: "#797368",
  rust: "#B23A2E", // Do First
  tide: "#2C6680", // Schedule
  ochre: "#8A6A22", // Delegate
  slate: "#6F685F", // Eliminate
  rustWash: "#F4E4E0",
  success: "#3E7D52",
};

// Design guide: New York for headlines, SF for everything else. Headless Chrome cannot reach
// New York by name, so the video uses Newsreader, the stand-in gsdtaskmanager.com and the web
// app self-host; the system stack below resolves to SF on the rendering Mac.
export const sans =
  '-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", system-ui, "Helvetica Neue", Arial, sans-serif';
export const mono = 'ui-monospace, "SF Mono", Menlo, monospace';

// Design guide card shadow, scaled up for device-sized cards: "one soft warm card shadow".
export const cardShadow = "0 2px 4px rgba(40, 33, 22, 0.05), 0 24px 64px rgba(40, 33, 22, 0.09)";

// Motion. The app's completion spring is response 0.34 / dampingFraction 0.8; these mirror that
// feel: a calm settle for text, a light overshoot for chips.
export const springs = {
  calm: { damping: 26, stiffness: 120, mass: 1 },
  chip: { damping: 16, stiffness: 150, mass: 0.7 },
};
