# AI Wallpaper Dark Mode

A macOS menu bar utility that generates a dark version of your own wallpaper
and swaps it in when the system switches to Dark Mode.

> **Status: design stage.** The plan is written, the code is not. See
> [docs/PLAN.md](docs/PLAN.md) and the [roadmap](#roadmap). Contributions welcome.

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

## How it works

```
Input image
    ↓
Luminance analysis      how bright is each region
    ↓
Saliency detection      where does the eye land
    ↓
Semantic segmentation   sky, building, person, foreground   (v2)
    ↓
Desktop zone awareness  dock, menu bar, icon columns
    ↓
Darkness map            per-pixel darkening factor
    ↓
Local tone mapping      lightness down, chroma and hue kept
    ↓
dark.heic
```

Two details carry most of the quality. Color is edited in a perceptual space
rather than RGB: lightness comes down while chroma and hue stay where they are,
so a blue sky becomes a dark blue sky instead of grey. And salient regions are
protected, so faces, people and the main subject get a lighter touch than the
background and the photo stays readable.

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

- [ ] Menu bar app (`MenuBarExtra`)
- [ ] Wallpaper picker and preview
- [ ] Light/Dark appearance detection
- [ ] Store the original
- [ ] Luminance analysis
- [ ] Saliency analysis (Vision)
- [ ] Darkness map and tone mapping
- [ ] HEIC export
- [ ] Set the desktop image (`NSWorkspace`)
- [ ] Cache
- [ ] Multi-monitor

**v2: image understanding**

- [ ] Semantic segmentation
- [ ] Face and object detection
- [ ] Sky detection
- [ ] Foreground/background separation
- [ ] Desktop icon area optimization
- [ ] Local contrast preservation

**v3: beyond Dark Mode**

- [ ] Core ML model for segmentation, saliency and depth in one pass
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

## Build

```sh
git clone https://github.com/ayhanhakan/ai-wallpaper-dark-mode.git
cd ai-wallpaper-dark-mode
open AIWallpaper.xcodeproj
```

Requires macOS 14 and Xcode 15 or newer. (The Xcode project lands with the
first v1 commit.)

## Contributing

The pipeline stages are independent, which makes them easy to pick up one at a
time. Luminance, saliency, tone mapping and HEIC export can each be built and
tested on their own. Open an issue before starting on something large so two
people don't write the same stage.

Before-and-after screenshots are the most useful thing you can attach to a pull
request that touches the darkening math.

## License

MIT, see [LICENSE](LICENSE).
