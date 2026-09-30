import AppKit
import Combine
import UniformTypeIdentifiers

/// Keeps the original wallpaper, generates the dark variant and swaps the two
/// as the system appearance changes.
@MainActor
final class WallpaperManager: ObservableObject {

    static let shared = WallpaperManager()

    @Published var status = "No wallpaper selected" {
        didSet { FileHandle.standardError.write(Data("aiwallpaper: \(status)\n".utf8)) }
    }
    @Published var darkness = UserDefaults.standard.object(forKey: "darkness") as? Double ?? 0.55 {
        didSet { UserDefaults.standard.set(darkness, forKey: "darkness"); apply() }
    }
    @Published var style = DarkVariant.Style(
        rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .dim {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "style"); apply() }
    }
    @Published var followsAppearance = UserDefaults.standard.object(forKey: "follows") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followsAppearance, forKey: "follows"); apply() }
    }

    private(set) var original: URL? {
        didSet { UserDefaults.standard.set(original?.path, forKey: "original") }
    }

    /// A Dark Mode image the user supplied. When it is set, nothing is
    /// generated: some photos have a real night version, and a real one beats
    /// anything the engine can infer.
    @Published private(set) var darkImage: URL? {
        didSet { UserDefaults.standard.set(darkImage?.path, forKey: "darkImage") }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: "original").map(URL.init(fileURLWithPath:))
        let onScreen = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        // Adopting our own output as the original would darken an already dark
        // wallpaper on every launch, so generated files are never picked up.
        original = [stored, onScreen].compactMap { $0 }.first { Self.isUsableOriginal($0) }
        UserDefaults.standard.set(original?.path, forKey: "original")
        let supplied = UserDefaults.standard.string(forKey: "darkImage")
        darkImage = supplied.flatMap {
            FileManager.default.isReadableFile(atPath: $0) ? URL(fileURLWithPath: $0) : nil
        }
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        apply()
    }

    static func isUsableOriginal(_ url: URL) -> Bool {
        !url.path.hasPrefix(DarkVariant.supportDirectory.path)
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    static var isDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    func selectWallpaper() {
        guard let url = pickImage() else { return }
        original = url
        apply()
    }

    func selectDarkImage() {
        guard let url = pickImage() else { return }
        darkImage = url
        apply()
    }

    func clearDarkImage() {
        darkImage = nil
        apply()
    }

    private func pickImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func apply() {
        guard let original else {
            status = "No wallpaper selected"
            return
        }
        guard followsAppearance, Self.isDarkMode else {
            status = "Light Mode: original wallpaper"
            set(original)
            return
        }
        if let darkImage {
            status = "Dark Mode: your image"
            set(darkImage)
            return
        }
        status = "Generating dark version…"
        let level = darkness
        let style = style
        Task.detached(priority: .userInitiated) {
            do {
                let dark = try DarkVariant.generate(from: original, darkness: level, style: style)
                await MainActor.run {
                    self.set(dark)
                    self.status = "Dark Mode: generated wallpaper"
                }
            } catch {
                await MainActor.run { self.status = "Failed: \(error.localizedDescription)" }
            }
        }
    }

    private func set(_ url: URL) {
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen)
        }
    }
}
