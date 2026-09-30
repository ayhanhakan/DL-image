# AI Wallpaper Dark Mode

A macOS menu bar utility that generates a dark version of your own wallpaper
and swaps it in when the system switches to Dark Mode.

> **Status: v1 works.** The menu bar app segments the picture, generates the
> dark variant and swaps it as the system appearance changes. See
> [docs/PLAN.md](docs/PLAN.md) for the full design.

## Why

macOS lets you attach a separate image to Dark Mode, but you have to find or
make that second image yourself. Most tools that automate it multiply every
pixel by a constant:

```
R *= 0.6   G *= 0.6   B *= 0.6
```

A blue sky turns grey, faces sink into the shadows, and the result looks like a
filter someone forgot to turn off.

This project looks at the picture first, then decides which regions should go
dark and by how much.

```
Light Mode ──> original.heic
Dark Mode  ──> analysis ──> darkness map ──> dark.heic
```

## Two modes

**Dim** keeps the daylight and takes the brightness down where it helps, so the
photo still looks like the photo.

**Night** turns the same daylight scene into a night version of itself. Warm
light is what makes an image read as daytime, so dimming alone leaves a grey
afternoon. Night collapses the colors onto a cool ramp, navy in the shadows and
moonlit white in the highlights, keeps about a third of the original color so
the place is still recognisable, and swaps the blue sky for a night sky that
keeps its own clouds. This is the day for night grade film crews shoot, done per
pixel from the luminance of the original.

On Apple's own Mojave pair, the generated night version lands close to the one
they photographed at night.

## How it works

```
Input image
    ↓
Luminance analysis      how bright is each region
    ↓
Saliency detection      where does the eye land
    ↓
Semantic segmentation   sky, tree, building, water, person
    ↓
Desktop zone awareness  dock, menu bar, icon columns
    ↓
Darkness map            per-pixel darkening factor
    ↓
Local tone mapping      lightness down, chroma and hue kept
    ↓
dark.heic
```

Two details carry most of the quality. The engine edits color in a perceptual
space: lightness comes down while chroma and hue stay where they are, so a blue
sky becomes a dark blue sky and never grey. It also spares the salient regions,
so faces and the main subject get a lighter touch than the background and the
photo stays readable.

## What it sees

A Core ML segmentation model labels every pixel before anything is darkened. The
model is DETR ResNet-50 panoptic, the conversion Apple publishes, running on 200
COCO classes. Each class carries its own share of the darkening:

| Class | Share |
| --- | --- |
| Sky | 0.40 |
| Snow, sea, river, water | 0.55 to 0.65 |
| Sand, mountain, rock, dirt | 0.85 to 0.95 |
| Grass, tree, potted plant | 1.15 to 1.20 |
| Building, house, roof, wall | 1.25 to 1.30 |
| Lamps and other light sources | 0.12 |

So a landscape keeps its sky and loses its foreground, and a city keeps its lit
windows while the facades around them go down. People are the one class the
model gets wrong often enough to matter. They come from Vision's person
segmentation instead, and they keep their daylight look in both modes.

The night sky mask is the segmented sky widened by a blue heuristic. The model
finds overcast and sunset skies the heuristic misses, and the heuristic catches
the thin gaps between branches and rooftops that a 448 pixel map rounds off.

## Wallpaper rotators

If something else changes your wallpaper on a schedule, like
[Irvue](https://irvue.tumblr.com), the app takes whatever it finds on the
desktop as the new original and generates a dark version for it. macOS sends no
notification when the wallpaper changes, so the desktop is checked every 20
seconds. Generated files are skipped, so the app never darkens its own output.

## Your own dark image

Some photos already have a night version, and a real one beats anything the
engine can infer. Pick it under "Use my own dark image" and nothing is
generated: Light Mode shows the original, Dark Mode shows yours. That is what
[Umbra](https://exsesx.dev/blog/en/umbra-light-dark-wallpapers) does, and it is
the way out when the generated version is not what you wanted.

The original file is never modified. Both versions live side by side:

```
~/Library/Application Support/AIWallpaper/
    original.heic
    dark.heic
```

Results are cached by `SHA256(original) + algorithmVersion + darknessLevel`, so
switching to Dark Mode only swaps a file instead of rendering one.

## Roadmap

**v1: MVP**

- [x] Menu bar app (`MenuBarExtra`)
- [x] Wallpaper picker
- [x] Light/Dark appearance detection
- [x] Store the original
- [x] Luminance analysis
- [x] Saliency analysis (Vision)
- [x] Darkness map and tone mapping
- [x] HEIC export
- [x] Set the desktop image (`NSWorkspace`)
- [x] Cache
- [x] Multi-monitor
- [x] Night mode: day for night grade and sky replacement
- [x] Semantic segmentation (Core ML) with per class darkening
- [x] Person protection (Vision)
- [x] Supply your own dark image
- [x] Pick up wallpapers other apps set
- [ ] Preview before applying
- [x] Open at login

**v2: image understanding**

- [ ] Face and object detection
- [ ] Foreground/background separation
- [ ] Desktop icon area optimization
- [ ] Local contrast preservation
- [ ] Per display settings

**v3: beyond Dark Mode**

- [ ] One model for segmentation, saliency and depth in a single pass
- [ ] Ambience modes: day, sunset, night, deep night

No generative AI in v1 or v2. The goal is the same photo in the dark, and a
diffusion model would rewrite faces and hallucinate detail it never saw.

## Architecture

```
SwiftUI / MenuBarExtra
        ↓
WallpaperManager     appearance detection, displays, wallpaper switching
        ↓
WallpaperAnalyzer    luminance, saliency, Vision, Core ML
        ↓
DarknessEngine       darkness map, semantic weights, color preservation
        ↓
ImageRenderer        Core Image, Metal, HEIC export
        ↓
Cache
```

## Stack

Swift · SwiftUI · macOS 14+ · Vision · Core ML · Core Image · Metal ·
Accelerate · ImageIO · AppKit

Apple frameworks only, no third-party dependencies.

## Install

```sh
git clone https://github.com/ayhanhakan/DL-image.git
cd DL-image
./make-app.sh
cp -R .build/AIWallpaper.app /Applications/
open /Applications/AIWallpaper.app
```

Requires macOS 14 and a Swift 6 toolchain. There is no Xcode project: the app is
a Swift package, and `make-app.sh` wraps the binary in a menu bar only bundle.

The icon appears in the menu bar with the current status, a wallpaper picker, a
Dim/Night switch, a darkness slider, a slot for your own dark image and a switch
for following the system appearance. On first launch it adopts the wallpaper
already on the desktop.

The segmentation model ships inside the app, about 40 MB. It is compiled once on
first run into `~/Library/Application Support/AIWallpaper/`.

The same binary runs without the UI, which is how the darkening is tuned:

```sh
.build/release/AIWallpaper --generate photo.jpg out.heic 0.55 night  # dim | night
.build/release/AIWallpaper --generate photo.jpg out.heic 0.55        # mean luma before and after
.build/release/AIWallpaper --probe out.heic                          # edge and center samples
.build/release/AIWallpaper --classes photo.jpg                       # what the model saw
/Applications/AIWallpaper.app/Contents/MacOS/AIWallpaper --login on   # on | off, or read the state
.build/debug/AIWallpaper --selftest                                  # asserts on the pipeline
AIW_MAP=map.heic .build/release/AIWallpaper --generate photo.jpg out.heic
AIW_SKY=sky.heic .build/release/AIWallpaper --generate photo.jpg out.heic 0.55 night
```

The last two write the brightness factor map and the sky mask next to the
result, which is the fastest way to see what the engine decided.

## Contributing

The pipeline stages are independent, which makes them easy to pick up one at a
time. Luminance, saliency, tone mapping and HEIC export can each be built and
tested on their own. Open an issue before starting on something large so two
people don't write the same stage.

Before-and-after screenshots are the most useful thing you can attach to a pull
request that touches the darkening math.

## License

MIT, see [LICENSE](LICENSE).
