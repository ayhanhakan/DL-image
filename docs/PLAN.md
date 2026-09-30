# Design plan

The full design for AI Wallpaper Dark Mode. Written before the code, so treat
every number here as a starting point to tune, not a decision.

## 1. The idea

A macOS wallpaper utility. When the system switches to Dark Mode, it analyses
the content of the current wallpaper and generates a darkened version of that
same image, without replacing what the user picked.

```
Light Mode
    ↓
Original wallpaper
Dark Mode
    ↓
Computer vision analysis
    ↓
Semantic + luminance analysis
    ↓
Dark variant
    ↓
macOS wallpaper
```

The difference from existing tools: no `image * 0.6`. The app works out which
regions benefit from darkening on a desktop and treats them differently.

## 2. User experience

The app should be as invisible as possible.

First run:

```
AI Wallpaper
[ Select Wallpaper ]
[x] Automatically adapt to Dark Mode
Darkness
 ●──────────
Natural
[ Generate Preview ]
```

The user picks a wallpaper. The app analyses it, generates the dark version,
shows a preview, and once the user approves it starts managing the desktop.

## 3. How it stores things

Two files, never one:

```
~/Library/Application Support/AIWallpaper/original.heic   Light Mode
~/Library/Application Support/AIWallpaper/dark.heic       Dark Mode
```

`dark.heic` is generated, never hand-made.

## 4. Analysis pipeline

No generative AI in the first version. Apple's native frameworks should be
enough: Vision, Core ML, Core Image, Accelerate, ImageIO, AppKit, SwiftUI.

```
Input image
     ↓
Resize / normalize
     ↓
Luminance analysis
     ↓
Saliency detection
     ↓
Semantic segmentation
     ↓
Edge / detail detection
     ↓
Desktop UI zone detection
     ↓
Darkness map
     ↓
Local tone mapping
     ↓
Color preservation
     ↓
Dark wallpaper
```

## 5. Luminance analysis

Per pixel, roughly:

```
Luminance = 0.2126R + 0.7152G + 0.0722B
```

`0.0` is black, `0.5` mid, `1.0` white. This value is one input to the darkness
map, never the darkening amount on its own.

## 6. Saliency detection

Find the regions the eye lands on.

```
       SKY
   ┌──────────────┐
   │              │
   │      O       │  <- high saliency
   │              │
   │   ^  ^  ^    │
   └──────────────┘
```

Salient regions stay lighter: faces, the main subject, vehicles, buildings,
clear foreground objects. Vision and Core ML both offer saliency requests.

## 7. Semantic segmentation

Split the image into regions such as sky, mountain, building, tree, person,
road, water, foreground, background, then darken each by a different amount.
Example weights (illustrative):

```
Sky          0.75
Background   0.70
Trees        0.65
Building     0.60
Person       0.90
Face         0.95
```

## 8. Desktop awareness

A wallpaper is not only a picture. Icons, the Dock, the menu bar, windows and
widgets sit on top of it, so some regions gain from being darker:

```
####################
####################
####################
        DOCK
```

The area around the Dock can go slightly darker. Hard gradients that break the
look of the photo are not worth the readability.

## 9. Darkness map

The centre of the algorithm. Each pixel gets a `darknessFactor`, where `0.0` is
no change and `0.8` is strong. Rather than multiplying weights:

```
darkness = base * luminance * saliency * semantic * desktop
```

build it additively and smooth the result:

```
DarknessMap = baseMap + luminanceMap + semanticMap + saliencyMap + desktopMap
```

## 10. Natural darkening

Plain RGB multiplication kills color:

```
R *= 0.6   G *= 0.6   B *= 0.6
```

Work in a perceptual space instead:

```
RGB -> linear / Lab / LCH -> lower lightness, keep chroma and hue -> RGB
```

A blue sky should end up as a dark blue sky, not dark grey.

## 11. Local contrast

Too much darkening flattens detail:

```
original       over-darkened
##########     ::::::::::
##########     ::::::::::
```

Local contrast has to survive. CLAHE or a similar local operator is worth
evaluating here.

## 12. Protecting faces and objects

When Vision or Core ML reports a face, person, animal, car or other salient
object, darken that region less. A face should not disappear into the dark.

## 13. Why no generative AI in v1

The job is the same photo in the dark. A generative model changes faces and
objects, invents detail, loses the original, and takes far longer. So v1 is
Vision, Core ML, Core Image and custom image processing.

## 14. Where Core ML comes in

Later, one model can produce the maps in a single pass:

```
Input -> Core ML -> semantic map + saliency map + depth map -> darkness engine
```

The model never renders the wallpaper. It only answers: which regions, how much.

## 15. macOS integration

A menu bar app built on SwiftUI's `MenuBarExtra`:

```
AI Wallpaper
  Light Mode / Dark Mode
  Current wallpaper
  ---
  Generate dark version
  Regenerate
  Darkness
  Settings
  Quit
```

Appearance changes come from `NSApp.effectiveAppearance` and the matching
distributed notification. On a switch to Dark Mode the app sets the generated
file as the desktop image through `NSWorkspace.shared.setDesktopImageURL`.

## 16. Multi-monitor

Each display keeps its own pair:

```json
{
  "display-1": { "original": "...", "dark": "..." },
  "display-2": { "original": "...", "dark": "..." }
}
```

## 17. Cache

Analysis should not run on every appearance change. Key the cache on the hash of
the original plus the parameters that affect the output:

```
wallpaperHash      SHA256(original)
algorithmVersion
darknessLevel
generatedFile
```

A hit skips generation entirely.

## 18. Image formats

Input: JPG, PNG, HEIC, HEIF. Output: HEIC, for the smaller file at high quality
and because macOS handles it natively for wallpapers.

## 19. Performance

Analysis and rendering run on the GPU where possible: Core Image, `CIFilter`,
`CIContext`, Metal, Accelerate. Generation happens in the background right after
the user picks a wallpaper, so the appearance switch itself is only a file swap
and the user never waits.

## 20. Scope

**v1 (MVP)**

- [ ] Menu bar app
- [ ] Wallpaper picker
- [ ] Light/Dark detection
- [ ] Store the original
- [ ] Luminance analysis
- [ ] Saliency analysis
- [ ] Smart darkening
- [ ] Dark wallpaper generation
- [ ] Set the macOS wallpaper
- [ ] Cache
- [ ] Multi-monitor

Semantic segmentation, depth and a custom model are out of scope for v1.

**v2**

- [ ] Semantic segmentation
- [ ] Face detection
- [ ] Object detection
- [ ] Sky detection
- [ ] Foreground/background separation
- [ ] Desktop icon area optimization
- [ ] Adaptive color preservation
- [ ] Local contrast optimization

**v3**

Core ML with a custom segmentation model, depth estimation and saliency, feeding
an image understanding layer:

```
"Sunset photo."
Sky         high luminance, medium saliency
Mountain    low luminance, high structure
Person      high saliency, protect
Foreground  medium saliency
```

## 21. The design principle

The app is not "darken the photo". It is "make the photo usable in Dark Mode".
The target is a natural night version of the same scene, not a black rectangle.

## 22. Architecture

```
┌───────────────────────────────┐
│           SwiftUI             │
│          MenuBarExtra         │
└───────────────┬───────────────┘
                ▼
┌───────────────────────────────┐
│       WallpaperManager        │
│  light / dark detection       │
│  display management           │
│  wallpaper switching          │
└───────────────┬───────────────┘
                ▼
┌───────────────────────────────┐
│       WallpaperAnalyzer       │
│  luminance, saliency          │
│  Vision, Core ML              │
└───────────────┬───────────────┘
                ▼
┌───────────────────────────────┐
│        DarknessEngine         │
│  darkness map                 │
│  semantic weights             │
│  local contrast               │
│  color preservation           │
└───────────────┬───────────────┘
                ▼
┌───────────────────────────────┐
│        ImageRenderer          │
│  Core Image, Metal            │
│  HEIC export                  │
└───────────────┬───────────────┘
                ▼
┌───────────────────────────────┐
│             Cache             │
└───────────────────────────────┘
```

## 23. Stack

Swift, SwiftUI, macOS 14+, `MenuBarExtra`, Core Image, ImageIO, Vision, Core ML,
Metal, Accelerate, `NSWorkspace`, `FileManager`, `UserDefaults`.

## 24. Build order

1. Pick a wallpaper.
2. Build the luminance map.
3. Build the saliency map.
4. Combine the two.
5. Produce the darkness map.
6. Process the image with Core Image.
7. Write the dark wallpaper.
8. Set it as the macOS wallpaper.
9. Listen for appearance changes.

If that prototype looks good, add semantic segmentation, then depth, then a
custom Core ML model.

## 25. What counts as success

A good dark version of a wallpaper:

- keeps the original photo recognisable
- keeps the colors alive
- keeps the main subjects visible
- brings down bright regions in a controlled way
- makes desktop icons easier to read
- reduces clashes with the Dock and menu bar
- does not feel like a filter
- appears fast enough that the user does not notice the work
- comes from cache on a repeat

## 26. What the product really is

```
Light wallpaper + image understanding -> context-aware dark wallpaper
```

Not a wallpaper darkener. An adaptive wallpaper engine, which later extends past
Dark Mode to day, sunset, night and deep night.
