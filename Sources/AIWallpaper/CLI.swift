import CoreImage
import Foundation

/// Headless entry points, so the pipeline can be run and checked without the UI.
enum CLI {

    /// `AIWallpaper --generate <input> [output] [darkness]`
    static func generate() {
        var args = Array(CommandLine.arguments.dropFirst(2))
        guard !args.isEmpty else {
            print("usage: AIWallpaper --generate <input> [output.heic] [darkness 0-1] [dim|night]")
            exit(2)
        }
        let input = URL(fileURLWithPath: args.removeFirst())
        let output = args.first.flatMap { $0.hasSuffix(".heic") ? URL(fileURLWithPath: args.removeFirst()) : nil }
        let style = DarkVariant.Style(rawValue: args.last ?? "") ?? .dim
        if DarkVariant.Style(rawValue: args.last ?? "") != nil { args.removeLast() }
        let darkness = args.first.flatMap(Double.init) ?? 0.55
        if let sky = ProcessInfo.processInfo.environment["AIW_SKY"] {
            NightGrade.debugSkyURL = URL(fileURLWithPath: sky)
        }
        if let map = ProcessInfo.processInfo.environment["AIW_MAP"] {
            DarkVariant.debugMapURL = URL(fileURLWithPath: map)
        }

        do {
            let url: URL
            if let output {
                guard let image = CIImage(contentsOf: input) else { throw CocoaError(.fileReadCorruptFile) }
                try DarkVariant.write(DarkVariant.make(from: image, darkness: darkness, style: style), to: output)
                url = output
            } else {
                url = try DarkVariant.generate(from: input, darkness: darkness, style: style)
            }
            print(url.path)
            if let image = CIImage(contentsOf: input), let result = CIImage(contentsOf: url) {
                print(String(format: "mean luma %.3f -> %.3f", luma(image, image.extent), luma(result, result.extent)))
            }
        } catch {
            FileHandle.standardError.write("failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    /// `AIWallpaper --classes <image>` lists what the model saw, for tuning the
    /// weight table.
    static func classes() {
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])) else {
            exit(2)
        }
        for (name, share) in Segmentation.histogram(for: image) where share > 0.002 {
            print(String(format: "%6.2f%%  %@", share * 100, name))
        }
        exit(0)
    }

    static func probe() {
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        let img = CIImage(contentsOf: url)!
        let e = img.extent
        func r(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: 6, height: 6) }
        print("edge-left", luma(img, r(e.minX, e.midY)))
        print("in-left  ", luma(img, r(e.minX + 40, e.midY)))
        print("edge-top ", luma(img, r(e.midX, e.maxY - 6)))
        print("in-top   ", luma(img, r(e.midX, e.maxY - 46)))
        print("center   ", luma(img, r(e.midX, e.midY)))
        exit(0)
    }

    /// `AIWallpaper --selftest`
    static func selftest() {
        let dark = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25))
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let bright = CIImage(color: CIColor(red: 0.95, green: 0.6, blue: 0.2))
            .cropped(to: CGRect(x: 400, y: 0, width: 400, height: 400))
        let input = bright.composited(over: dark)

        let out = try! DarkVariant.make(from: input, darkness: 0.6)

        let inDark = luma(input, CGRect(x: 50, y: 50, width: 300, height: 300))
        let inBright = luma(input, CGRect(x: 450, y: 50, width: 300, height: 300))
        let outDark = luma(out, CGRect(x: 50, y: 50, width: 300, height: 300))
        let outBright = luma(out, CGRect(x: 450, y: 50, width: 300, height: 300))

        assert(outDark < inDark && outBright < inBright, "both halves must get darker")
        // The bright half must lose more of its light than the dark half.
        assert(outBright / inBright < outDark / inDark, "darkening must follow luminance")
        // Hue survives: the orange half stays orange rather than turning grey.
        let (r, g, b) = rgb(out, CGRect(x: 450, y: 50, width: 300, height: 300))
        assert(r > g && g > b, "hue order lost: \(r) \(g) \(b)")

        // Night has to cool the image down: a warm subject comes back blue led.
        let night = try! DarkVariant.make(from: input, darkness: 0.6, style: .night)
        let (nr, _, nb) = rgb(night, CGRect(x: 450, y: 50, width: 300, height: 300))
        assert(nb > nr, "night grade left the warm cast in place: \(nr) \(nb)")

        // Segmentation has to stay wired: a broken model silently falls back to
        // luminance only darkening, which still produces a plausible image.
        let photo = CIImage(color: CIColor(red: 0.4, green: 0.55, blue: 0.85))
            .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 400))
        assert(Segmentation.classify(photo)?.count == Segmentation.side * Segmentation.side,
               "segmentation model did not return a full map")
        assert(Segmentation.maps(for: photo) != nil, "segmentation maps missing")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("selftest.heic")
        try! DarkVariant.write(out, to: tmp)
        let size = (try! FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as! NSNumber).intValue
        assert(size > 0, "HEIC export is empty")
        try? FileManager.default.removeItem(at: tmp)

        print("selftest passed (bright \(round(inBright * 100)/100) -> \(round(outBright * 100)/100), dark \(round(inDark * 100)/100) -> \(round(outDark * 100)/100))")
    }

    static func rgb(_ image: CIImage, _ rect: CGRect) -> (Double, Double, Double) {
        let average = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: rect)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        DarkVariant.context.render(
            average, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    static func luma(_ image: CIImage, _ rect: CGRect) -> Double {
        let (r, g, b) = rgb(image, rect)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
