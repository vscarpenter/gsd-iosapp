# GSD icon sources

Editable vector sources for the app icon and launch-screen mark — the editorial
visual language: four refined quadrant pigments as rounded tiles on warm paper,
with a single white check on the Do-First (rust) tile.

- `app-icon.svg` — light app icon (2×2 tiles on warm paper, opaque; iOS masks corners on device).
- `app-icon-dark.svg` — dark-appearance variant (dark-mode pigments on dark paper).
- `launch-mark.svg` — same art, transparent background (floats on the paper LaunchBackground).

Palette (matches `QuadrantStyle` / `Surface`): rust `#B23A2E` · tide `#2C6680` ·
ochre `#8A6A22` · slate `#6F685F` on paper `#F4F1E9`. Dark: `#E0705F` `#6FAACB`
`#CFB266` `#A9A096` on `#17150F`.

## Regenerate

App icons (1024, opaque — App Store requires no alpha; flattened via Pillow):

    rsvg-convert -w 1024 -h 1024 app-icon.svg      -o /tmp/_light.png
    rsvg-convert -w 1024 -h 1024 app-icon-dark.svg -o /tmp/_dark.png
    python3 -c "from PIL import Image; \
      Image.open('/tmp/_light.png').convert('RGB').save('../../App/Assets.xcassets/AppIcon.appiconset/AppIcon.png'); \
      Image.open('/tmp/_dark.png').convert('RGB').save('../../App/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png')"

Launch mark (@1x/2x/3x, transparent — render via rsvg):

    rsvg-convert -w 120 -h 120 launch-mark.svg -o ../../App/Assets.xcassets/LaunchMark.imageset/LaunchMark.png
    rsvg-convert -w 240 -h 240 launch-mark.svg -o ../../App/Assets.xcassets/LaunchMark.imageset/LaunchMark@2x.png
    rsvg-convert -w 360 -h 360 launch-mark.svg -o ../../App/Assets.xcassets/LaunchMark.imageset/LaunchMark@3x.png
