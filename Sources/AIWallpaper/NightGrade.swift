import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Turns a daylight photo into a night version of the same scene.
///
/// Darkening alone leaves a grey day. Night reads as night because warm light
/// is gone: colors collapse towards a cool grey blue, shadows go navy, and the
/// sky is a different sky. This is the day-for-night grade film crews shoot,
/// done per pixel from the luminance of the original.
enum NightGrade {

    /// sRGB values, because that is how the eye reads them; Core Image works in
    /// linear light, so everything is converted on the way in.
    static let shadowColor = (r: 0.07, g: 0.09, b: 0.18)
    static let highlightColor = (r: 0.86, g: 0.89, b: 0.97)

    static func make(from input: CIImage, darkness: Double) throws -> CIImage {
        // 1. Luminance of the original, pulled down with a gamma curve. Lit
        //    surfaces stay readable, shadows fall away.
        let lum = DarkVariant.luminanceMap(of: input)
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.2 + 1.2 * darkness])

        // 2. Map that luminance onto the night ramp: navy in the shadows, cool
        //    white in the highlights.
        let moonlit = ramp(lum, from: shadowColor, to: highlightColor)

        // 3. Keep a trace of the real colors so the scene is still the same
        //    place, not a blue monochrome.
        let residue = input
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.30])
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 4200, y: 15),
            ])
            .applyingFilter("CIExposureAdjust", parameters: ["inputEV": -2.0 - 1.5 * darkness])
        var night = mix(moonlit, with: residue, amount: 0.35)

        // 4. Swap the daylight sky for a night one.
        let mask = skyMask(of: input)
        night = blend(nightSky(for: input), over: night, mask: mask)

        return night.cropped(to: input.extent)
    }

    // MARK: - Sky

    /// Heuristic sky: bright, blue, high in the frame, smooth.
    ///
    /// ponytail: good enough for landscape wallpapers. A real segmentation model
    /// (ADE20K class 2) is the v2 plan and would also catch sunset skies.
    nonisolated(unsafe) static var debugSkyURL: URL?

    static func skyMask(of image: CIImage) -> CIImage {
        let blueness = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -0.6, y: -0.5, z: 1.1, w: 0),
            "inputGVector": CIVector(x: -0.6, y: -0.5, z: 1.1, w: 0),
            "inputBVector": CIVector(x: -0.6, y: -0.5, z: 1.1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.15, y: 0.15, z: 0.15, w: 1),
        ])
        let candidate = clamp(DarkVariant.scale(blueness, by: 2.0, bias: -0.35))

        // Sky is above the horizon, so fade the mask out over the lower half.
        let height = image.extent.height
        let vertical = CIFilter.linearGradient()
        vertical.point0 = CGPoint(x: 0, y: height * 0.35)
        vertical.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        vertical.point1 = CGPoint(x: 0, y: height * 0.75)
        vertical.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let masked = DarkVariant.multiply(candidate, vertical.outputImage ?? CIImage(color: .white))

        let mask = DarkVariant.blur(
            clamp(DarkVariant.scale(masked, by: 1.6, bias: 0.0)).cropped(to: image.extent),
            radius: Float(min(image.extent.width, height) / 120))
        if let debugSkyURL { try? DarkVariant.write(mask, to: debugSkyURL) }
        return mask
    }

    static func nightSky(for image: CIImage) -> CIImage {
        let extent = image.extent
        // Clouds and gradients of the original sky survive as brightness.
        let structure = DarkVariant.scale(
            DarkVariant.luminanceMap(of: image), by: 0.55, bias: 0.55)

        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: extent.height)
        gradient.color0 = linear(0.03, 0.04, 0.11)
        gradient.point1 = CGPoint(x: 0, y: extent.height * 0.35)
        gradient.color1 = linear(0.10, 0.13, 0.24)

        // ponytail: no stars. Thresholded CIRandomGenerator reads as grain at
        // wallpaper resolution; real points need a sprite pass, and the sky
        // looks right without them.
        return DarkVariant.multiply(gradient.outputImage ?? CIImage(color: .black), structure)
    }

    // MARK: - Helpers

    /// Maps a greyscale image onto a two color ramp.
    static func ramp(_ grey: CIImage, from lo: (r: Double, g: Double, b: Double),
                     to hi: (r: Double, g: Double, b: Double)) -> CIImage {
        let l = (linearize(lo.r), linearize(lo.g), linearize(lo.b))
        let h = (linearize(hi.r), linearize(hi.g), linearize(hi.b))
        return grey.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: h.0 - l.0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: h.1 - l.1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: h.2 - l.2, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: l.0, y: l.1, z: l.2, w: 1),
        ])
    }

    static func mix(_ base: CIImage, with other: CIImage, amount: Double) -> CIImage {
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = base
        dissolve.targetImage = other
        dissolve.time = Float(amount)
        return dissolve.outputImage ?? base
    }

    static func blend(_ image: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = image
        filter.backgroundImage = background
        filter.maskImage = mask
        return filter.outputImage ?? background
    }

    static func clamp(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
    }

    static func linearize(_ c: Double) -> CGFloat {
        CGFloat(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
    }

    static func linear(_ r: Double, _ g: Double, _ b: Double) -> CIColor {
        CIColor(red: linearize(r), green: linearize(g), blue: linearize(b), alpha: 1)
    }
}
