# GSD icon sources

Editable vector sources for the app icon and launch-screen mark.

- `app-icon.svg` — full-bleed 2×2 quadrant + checkmark (App Store icon, no rounding; iOS masks on device).
- `launch-mark.svg` — same art with a rounded-squircle clip (launch-screen centered mark).

Brightened/vibrant palette anchored on the app's quadrant hues (value boosted ~1.4×, gray lightened):
red `#FD4836` · sky blue `#3699CB` · gold `#C49823` · light gray `#A0A0A0`.

## Regenerate

App icon (1024, opaque — App Store requires no alpha):

    rsvg-convert -w 1024 -h 1024 app-icon.svg -o _raw.png
    magick _raw.png -background white -alpha remove -alpha off \
      ../../App/Assets.xcassets/AppIcon.appiconset/AppIcon.png

Launch mark (@1x/2x/3x, rounded with transparency — render via rsvg, not magick masking):

    rsvg-convert -w 120 -h 120 launch-mark.svg -o ../../App/Assets.xcassets/LaunchMark.imageset/LaunchMark.png
    rsvg-convert -w 240 -h 240 launch-mark.svg -o ../../App/Assets.xcassets/LaunchMark.imageset/LaunchMark@2x.png
    rsvg-convert -w 360 -h 360 launch-mark.svg -o ../../App/Assets.xcassets/LaunchMark.imageset/LaunchMark@3x.png
