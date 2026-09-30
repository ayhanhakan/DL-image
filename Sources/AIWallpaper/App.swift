import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case "--generate": CLI.generate()
        case "--selftest": CLI.selftest()
        case "--probe": CLI.probe()
        default: AIWallpaperApp.main()
        }
    }
}

struct AIWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // The menu bar scene builds its body only when the user opens the menu, so
    // the manager has to come from the delegate to run at launch.
    @ObservedObject private var manager = WallpaperManager.shared

    var body: some Scene {
        MenuBarExtra("AI Wallpaper", systemImage: "moon.circle") {
            MenuView(manager: manager)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        WallpaperManager.shared.apply()
    }
}

struct MenuView: View {
    @ObservedObject var manager: WallpaperManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(manager.status).font(.callout).foregroundStyle(.secondary)

            Button("Select wallpaper…") { manager.selectWallpaper() }

            Picker("", selection: $manager.style) {
                Text("Dim").tag(DarkVariant.Style.dim)
                Text("Night").tag(DarkVariant.Style.night)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text("Darkness")
                Slider(value: $manager.darkness, in: 0.2...0.9)
            }

            Toggle("Follow Dark Mode", isOn: $manager.followsAppearance)

            HStack {
                Button("Apply now") { manager.apply() }
                    .disabled(manager.original == nil)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
