import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Vision

/// Generates the Dark Mode version of a wallpaper.
///
/// Pipeline: semantic segmentation + luminance map + saliency map -> darkness
/// map -> multiply in Core Image's linear working space -> HEIC.
enum DarkVariant {

    static let algorithmVersion = 5

    /// How far the dark variant goes: a dimmed version of the same daylight, or
    /// the same scene at night.
    enum Style: String, CaseIterable {
        case dim, night
    }

    static let context = CIContext(options: [.cacheIntermediates: false])

    /// - Parameter darkness: 0 = untouched, 1 = as dark as the engine goes.
    /// Debug hook: set to a URL to dump the brightness factor map.
    nonisolated(unsafe) static var debugMapURL: URL?

    static func make(from input: CIImage, darkness: Double, style: Style = .dim) throws -> CIImage {
        let maps = Segmentation.maps(for: input)
        if style == .night {
            return try NightGrade.make(from: input, darkness: darkness, maps: maps)
        }
        let size = input.extent.size
        // Regional, not per-pixel: a blur the size of a few percent of the image
        // keeps the map smooth so no edge shows up in the result.
        let radius = Float(min(size.width, size.height) / 40)

        let luminance = blur(luminanceMap(of: input), radius: radius)
        let saliency = blur(saliencyMap(of: input), radius: radius * 6)

        // Bright regions take most of the darkening, salient ones are spared.
        let byLuminance = scale(luminance, by: 0.95, bias: 0.55)   // 0.55 ... 1.50
        // Kept gentle on purpose: a strong saliency weight reads as a vignette,
        // because attention maps are center heavy on most photos.
        let bySaliency = scale(saliency, by: -0.25, bias: 1.0)     // 0.75 ... 1.00
        var amount = multiply(byLuminance, bySaliency)
        // What the surface is decides more than how bright it is: sky and faces
        // hold their light, foliage and lit facades give theirs up.
        if let maps { amount = multiply(amount, maps.weight) }
        // Sparing the sky takes most of the darkening out of a landscape, since
        // the sky is both the brightest and the largest part of it. The slider
        // pushes harder to make up for it.
        var factor = scale(amount, by: -darkness * 1.5, bias: 1.0)  // brightness factor
        factor = multiply(factor, dockGradient(size: size))
        // Never go fully black: detail has to survive the darkest setting.
        factor = factor.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0.12, y: 0.12, z: 0.12, w: 1),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        factor = factor.cropped(to: input.extent)

        if let debugMapURL { try? write(factor, to: debugMapURL) }

        let darkened = multiply(input, factor).cropped(to: input.extent)

        // Multiplying in linear space keeps hue and scales chroma with
        // lightness; a little vibrance puts back what the eye expects.
        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = darkened
        vibrance.amount = Float(0.25 * darkness)
        return vibrance.outputImage ?? darkened
    }

    // MARK: - Maps

    static func luminanceMap(of image: CIImage) -> CIImage {
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": luma, "inputGVector": luma, "inputBVector": luma,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    static func saliencyMap(of image: CIImage) -> CIImage {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(ciImage: image)
        guard (try? handler.perform([request])) != nil,
              let buffer = (request.results?.first)?.pixelBuffer
        else {
            // ponytail: no saliency means uniform darkening, which is still
            // better than failing the whole generation.
            return CIImage(color: .black).cropped(to: image.extent)
        }
        // Vision hands back a ~68x68 single channel map; spread it to RGB and
        // stretch it over the image.
        let raw = CIImage(cvPixelBuffer: buffer).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let sx = image.extent.width / raw.extent.width
        let sy = image.extent.height / raw.extent.height
        // Clamp first: a 68x68 map stretched to full size leaves a transparent
        // rim otherwise, which shows up as a dark frame around the wallpaper.
        return raw.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .clampedToExtent()
            .cropped(to: image.extent)
    }

    /// Slightly darker behind the Dock so icon labels stay readable.
    static func dockGradient(size: CGSize) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.color0 = CIColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1)
        gradient.point1 = CGPoint(x: 0, y: size.height * 0.22)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        return gradient.outputImage ?? CIImage(color: .white)
    }

    // MARK: - Small Core Image helpers

    static func blur(_ image: CIImage, radius: Float) -> CIImage {
        guard radius >= 1 else { return image }
        return image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
            .cropped(to: image.extent)
    }

    static func scale(_ image: CIImage, by factor: Double, bias: Double) -> CIImage {
        let v = CIVector(x: CGFloat(factor), y: 0, z: 0, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v,
            "inputGVector": CIVector(x: 0, y: CGFloat(factor), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(factor), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 1),
        ])
    }

    static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.multiplyCompositing()
        filter.inputImage = b
        filter.backgroundImage = a
        return filter.outputImage ?? a
    }

    // MARK: - Files

    /// Generates `dark.heic` for `original`, or returns the cached file when the
    /// same image and settings were rendered before.
    @discardableResult
    static func generate(from original: URL, darkness: Double, style: Style = .dim) throws -> URL {
        let output = cacheURL(for: original, darkness: darkness, style: style)
        if FileManager.default.fileExists(atPath: output.path) { return output }

        guard let input = CIImage(contentsOf: original) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let dark = try make(from: input, darkness: darkness, style: style)
        try write(dark, to: output)
        prune()
        return output
    }

    /// A rotator hands the app a new photo every few hours and each one leaves a
    /// rendered file behind, so the oldest are dropped once there are enough.
    private static func prune(keeping limit: Int = 8) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: supportDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let heics = files.filter { $0.pathExtension == "heic" }
        guard heics.count > limit else { return }
        let date = { (url: URL) in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
        }
        for url in heics.sorted(by: { date($0) > date($1) }).dropFirst(limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func write(_ image: CIImage, to url: URL) throws {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try context.writeHEIFRepresentation(
            of: image, to: url, format: .RGBA8, colorSpace: space,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIWallpaper", isDirectory: true)
    }

    static func cacheURL(for original: URL, darkness: Double, style: Style) -> URL {
        let hash = (try? Data(contentsOf: original)).map {
            SHA256.hash(data: $0).prefix(8).map { String(format: "%02x", $0) }.joined()
        } ?? UUID().uuidString
        let level = Int((darkness * 100).rounded())
        return supportDirectory
            .appendingPathComponent("\(hash)-v\(algorithmVersion)-\(style.rawValue)-d\(level).heic")
    }
}
