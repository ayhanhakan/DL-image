import CoreImage
import CoreML
import Foundation
import Vision

/// Labels every pixel of the wallpaper, so each kind of surface can take its own
/// amount of darkening.
///
/// The model is UperNet with a ConvNeXt-Tiny backbone, trained on ADE20K and
/// converted to Core ML here. It reads a 512x512 image and returns one class
/// index per pixel over 150 classes. ADE20K is a scene parsing set, so sky,
/// mountain, water, tree, building and road are all classes of their own, which
/// is what a wallpaper is made of.
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

    static let side = 512

    /// Darkening weight per class. 1.0 is the plain amount, below it the surface
    /// is spared, above it the surface goes darker than the rest of the image.
    ///
    /// Sky keeps most of its light because a black sky looks like a hole. Foliage
    /// and roads take the full amount, lit facades take more, and lamps are
    /// nearly untouched. People come from Vision instead: a dune reads as a
    /// person often enough that the class cannot be trusted on its own.
    static let weights: [Int32: Double] = [
        2: 0.40,  // sky
        21: 0.65, 26: 0.65, 60: 0.65, 128: 0.65, 113: 0.70,  // water, sea, river, lake, waterfall
        46: 0.85,  // sand
        16: 0.90, 34: 0.90, 68: 0.92, 13: 0.95, 94: 0.95,  // mountain, rock, hill, earth, land
        4: 1.20, 72: 1.20, 9: 1.15, 17: 1.15, 29: 1.10, 66: 1.00,  // tree, palm, grass, plant, field, flower
        1: 1.30, 25: 1.30, 48: 1.30, 79: 1.25, 84: 1.25,  // building, house, skyscraper, hovel, tower
        0: 1.25, 42: 1.20,  // wall, column
        8: 0.70, 14: 0.85,  // windowpane, door
        6: 1.10, 11: 1.10, 52: 1.10, 3: 1.10, 54: 1.10, 91: 1.10,  // road, sidewalk, path, floor, runway, dirt track
        32: 1.15, 61: 1.15, 38: 1.15, 95: 1.15,  // fence, bridge, railing, bannister
        36: 0.12, 82: 0.12, 87: 0.12, 85: 0.12, 134: 0.12,  // lamp, light, streetlight, chandelier, sconce
    ]
    static let defaultWeight: Double = 1.00
    static let weightRange: Double = 1.35  // so the stored map fits in 0...1

    static let skyClass: Int32 = 2
    /// Anything that gives off light of its own, which a night version should
    /// leave alone.
    static let lightClasses: Set<Int32> = [36, 82, 87, 85, 134, 136]

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
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        cached = model
        return model
    }

    /// Returns nil when the model cannot run, and the engine falls back to the
    /// luminance only path.
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
            if lightClasses.contains(id) { protected[i] = 1 }
        }

        // Class edges are hard, and a hard edge in the darkness map shows up as a
        // cut across the wallpaper. Smooth the map here, while it is still 512
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
    /// person from a sand dune, which the scene parsing model does not.
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

    /// Class index per pixel, 512x512, row major from the top left.
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
