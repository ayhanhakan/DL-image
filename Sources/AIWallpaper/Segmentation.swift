import CoreImage
import CoreML
import Foundation
import Vision

/// Labels every pixel of the wallpaper, so each kind of surface can take its own
/// amount of darkening.
///
/// The model is DETR ResNet-50 panoptic, converted to Core ML by Apple. It reads
/// a 448x448 image and returns one class index per pixel over the 200 COCO
/// panoptic classes, which include sky, tree, mountain, water, building and
/// person. Those are the classes a wallpaper is made of.
enum Segmentation {

    /// The three maps the engine needs, all at the size of the input image.
    struct Maps {
        /// How much of the darkening each pixel takes, 0 to about 1.3.
        let weight: CIImage
        /// Sky, for the night sky swap.
        let sky: CIImage
        /// People and lamps, which stay close to how they looked in daylight.
        let protected: CIImage
    }

    static let side = 448

    /// Darkening weight per class. 1.0 is the plain amount, below it the surface
    /// is spared, above it the surface goes darker than the rest of the image.
    ///
    /// Sky keeps most of its light because a black sky looks like a hole. Foliage
    /// and roads take the full amount, lit facades take more, and lamps are
    /// nearly untouched. People come from Vision instead: this model calls desert
    /// dunes people often enough that its person class cannot be trusted.
    static let weights: [Int32: Double] = [
        187: 0.40,  // sky
        155: 0.65, 148: 0.65, 178: 0.65,  // sea, river, water
        159: 0.55, 154: 0.85,  // snow, sand
        192: 0.90, 198: 0.90, 194: 0.95, 125: 0.95,  // mountain, rock, dirt, gravel
        184: 1.20, 193: 1.15, 119: 1.00, 64: 1.15,  // tree, grass, flower, potted plant
        197: 1.30, 128: 1.30, 151: 1.30,  // building, house, roof
        171: 1.25, 175: 1.25, 199: 1.25, 176: 1.25, 177: 1.25,  // walls
        181: 0.70, 180: 0.70,  // windows, which are the lit part of a facade
        149: 1.10, 191: 1.10, 190: 1.10, 144: 1.10, 147: 1.10,  // road, pavement, floor
        185: 1.15, 95: 1.15,  // fence, bridge
        130: 0.12,  // light
    ]
    static let defaultWeight: Double = 1.00
    static let weightRange: Double = 1.35  // so the stored map fits in 0...1

    static let skyClass: Int32 = 187
    static let lightClass: Int32 = 130

    nonisolated(unsafe) private static var cached: MLModel?

    /// Compiles the bundled model once and keeps it for the life of the process.
    /// `Bundle.module` traps when it cannot find the resource bundle, and it
    /// only ever looks inside the main bundle's Resources, which is nowhere near
    /// where a menu bar app keeps it. Both locations are searched by hand so a
    /// missing model turns the segmentation off instead of killing the app.
    static func modelSource() -> URL? {
        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.bundleURL,
        ].compactMap { $0 }
        for root in roots {
            let url = root
                .appendingPathComponent("AIWallpaper_AIWallpaper.bundle", isDirectory: true)
                .appendingPathComponent("Segmentation.mlpackage", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func model() throws -> MLModel {
        if let cached { return cached }
        let compiled = DarkVariant.supportDirectory
            .appendingPathComponent("Segmentation.mlmodelc", isDirectory: true)
        if !FileManager.default.fileExists(atPath: compiled.path) {
            guard let source = modelSource() else { throw CocoaError(.fileNoSuchFile) }
            let built = try MLModel.compileModel(at: source)
            try FileManager.default.createDirectory(
                at: DarkVariant.supportDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: built, to: compiled)
        }
        // ponytail: CPU and GPU only. The INT8 weights trip the Neural Engine
        // compiler on this build of macOS, and the whole run aborts.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        cached = model
        return model
    }

    /// Returns nil when the model cannot run, and the engine falls back to the
    /// luminance only path.
    /// Everything under open sky counts as sky.
    ///
    /// The model calls a lit cloud something else often enough to matter, and a
    /// hole in the mask reads as a glowing patch once the sky around it is
    /// pulled down. So in a column that starts out as sky, every row down to the
    /// skyline is filled in.
    static func fillSkyHoles(_ sky: inout [Float], gap: Int = 24, grow: Int = 3) {
        // How far down the sky reaches in each column. The walk steps over short
        // interruptions, which is what a cloud is. A long one is the ground.
        var bottom = [Int](repeating: -1, count: side)
        for x in 0..<side where sky[x] > 0.5 {
            var y = 0
            while y < side {
                if sky[y * side + x] > 0.5 { bottom[x] = y; y += 1; continue }
                var run = 0
                while y + run < side, sky[(y + run) * side + x] < 0.5 { run += 1 }
                if run > gap { break }
                y += run
            }
        }
        // A skyline moves smoothly across the frame. One column that ran much
        // deeper than its neighbours hangs off the cloud bank like a drip, so
        // the median of a small window is used instead.
        let smoothed = (0..<side).map { x -> Int in
            let w = stride(from: max(0, x - 14), through: min(side - 1, x + 14), by: 1).map { bottom[$0] }.sorted()
            return w[w.count / 2]
        }
        for x in 0..<side {
            // Grown a little past the skyline. Bright backlit haze left outside
            // the mask keeps the daylight treatment and outlines the silhouette;
            // a few darkened rows of ground cost nothing.
            let end = min(smoothed[x] + grow, side - 1)
            if end < 0 { continue }
            for y in 0...end { sky[y * side + x] = 1 }
        }
    }

    static func maps(for image: CIImage) -> Maps? {
        guard let classes = classify(image) else { return nil }

        let count = side * side
        var weight = [Float](repeating: 0, count: count)
        var sky = [Float](repeating: 0, count: count)
        var protected = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let id = classes[i]
            weight[i] = Float((weights[id] ?? defaultWeight) / weightRange)
            if id == skyClass { sky[i] = 1 }
            if id == lightClass { protected[i] = 1 }
        }

        fillSkyHoles(&sky)

        // Class edges are hard, and a hard edge in the darkness map shows up as a
        // cut across the wallpaper. Smooth the map here, while it is still 448
        // pixels: a Core Image blur on the upscaled version leaves a pale band
        // along the top edge that no amount of clamping gets rid of.
        func spread(_ values: [Float], gain: Double) -> CIImage {
            stretched(float(smoothed(values)), to: image.extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
        }
        var protectedMap = spread(protected, gain: 1)
        if let people = peopleMask(for: image) {
            protectedMap = DarkVariant.scale(
                DarkVariant.multiply(
                    DarkVariant.scale(protectedMap, by: -1, bias: 1),
                    DarkVariant.scale(people, by: -1, bias: 1)),
                by: -1, bias: 1)
        }
        return Maps(
            weight: spread(weight, gain: weightRange),
            sky: spread(sky, gain: 1),
            protected: protectedMap.cropped(to: image.extent))
    }

    /// Everybody in the frame, from Vision's own person segmentation. It knows a
    /// person from a sand dune, which the panoptic model does not.
    static func peopleMask(for image: CIImage) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? VNImageRequestHandler(ciImage: image).perform([request])) != nil,
              let buffer = request.results?.first?.pixelBuffer
        else { return nil }
        let raw = CIImage(cvPixelBuffer: buffer)
        return DarkVariant.blur(
            stretched(raw, to: image.extent),
            radius: Float(min(image.extent.width, image.extent.height) / 200))
    }

    /// Class index per pixel, 448x448, row major from the top left.
    static func classify(_ image: CIImage) -> [Int32]? {
        do {
            let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model()))
            // Fill rather than fit: the map is stretched back to the original
            // aspect ratio afterwards, and a letterboxed input labels the bars.
            request.imageCropAndScaleOption = .scaleFill
            try VNImageRequestHandler(ciImage: image).perform([request])
            guard let value = (request.results?.first as? VNCoreMLFeatureValueObservation)?
                .featureValue.multiArrayValue
            else { return nil }
            let count = side * side
            guard value.count == count else { return nil }
            return value.withUnsafeBufferPointer(ofType: Int32.self) { Array($0.prefix(count)) }
        } catch {
            FileHandle.standardError.write(Data("aiwallpaper: segmentation off (\(error))\n".utf8))
            return nil
        }
    }

    /// Class name and share of the frame, for tuning the weight table.
    static func histogram(for image: CIImage) -> [(String, Double)] {
        guard let classes = classify(image) else { return [] }
        var counts: [Int32: Int] = [:]
        for id in classes { counts[id, default: 0] += 1 }
        let total = Double(classes.count)
        return counts.sorted { $0.value > $1.value }
            .map { (labels[Int($0.key)] ?? "\($0.key)", Double($0.value) / total) }
    }

    // MARK: - Buffers

    /// Two box blur passes, which is close enough to a gaussian for a mask and
    /// stays within our own array.
    private static func smoothed(_ values: [Float], radius: Int = 3) -> [Float] {
        var current = values
        var next = values
        for _ in 0..<2 {
            for y in 0..<side {  // horizontal
                let row = y * side
                for x in 0..<side {
                    var sum: Float = 0
                    for k in -radius...radius {
                        sum += current[row + min(side - 1, max(0, x + k))]
                    }
                    next[row + x] = sum / Float(radius * 2 + 1)
                }
            }
            swap(&current, &next)
            for x in 0..<side {  // vertical
                for y in 0..<side {
                    var sum: Float = 0
                    for k in -radius...radius {
                        sum += current[min(side - 1, max(0, y + k)) * side + x]
                    }
                    next[y * side + x] = sum / Float(radius * 2 + 1)
                }
            }
            swap(&current, &next)
        }
        return current
    }

    /// A single channel float image with no color management, so the weights
    /// stay the numbers we wrote instead of being gamma corrected on the way in.
    private static func float(_ values: [Float]) -> CIImage {
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(
            bitmapData: data, bytesPerRow: side * 4,
            size: CGSize(width: side, height: side), format: .Lf, colorSpace: nil)
    }

    private static func stretched(_ map: CIImage, to extent: CGRect) -> CIImage {
        // Drop the outer row and column first: the model gets its own border
        // wrong often enough that a single stray row, blown up to wallpaper
        // size, shows as a bright band along the top edge.
        let inner = map.extent.insetBy(dx: 1, dy: 1)
        let transform = CGAffineTransform(translationX: -inner.minX, y: -inner.minY)
            .concatenating(CGAffineTransform(
                scaleX: extent.width / inner.width,
                y: extent.height / inner.height))
        // Clamp on both sides of the transform, or the upscale leaves a
        // transparent rim that shows up as a frame around the wallpaper.
        return map.cropped(to: inner).clampedToExtent()
            .transformed(by: transform)
            .clampedToExtent()
            .cropped(to: extent)
    }
}
