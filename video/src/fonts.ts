import { loadFont } from "@remotion/google-fonts/Newsreader";

// Newsreader stands in for Apple's New York, exactly as gsdtaskmanager.com and the web app do
// (see theme.ts). loadFont blocks rendering until the faces are ready.
const { fontFamily } = loadFont("normal", { weights: ["400", "500", "600"], subsets: ["latin"] });
loadFont("italic", { weights: ["400", "600"], subsets: ["latin"] });

export const serif = `"${fontFamily}", ui-serif, "New York", Georgia, "Times New Roman", serif`;
