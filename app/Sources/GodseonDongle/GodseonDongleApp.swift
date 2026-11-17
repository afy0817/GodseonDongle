// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

@main
struct GodseonDongleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("GodseonDongle", id: "main") {
            MainView(model: delegate.model)
        }
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        // The menu bar keeps only an icon; everything else lives in the window.
        MenuBarExtra {
            MenuBarMenu(model: delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var quitReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Closing the window keeps the app (and the dongle connection) running from the menu bar icon.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again (Finder, Dock, Spotlight) while only the menu bar icon is left
    /// brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .openMainWindow, object: nil) }
        return true
    }

    /// Hands the dongle back and drops the Mac routes before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitReady { return .terminateNow }
        Task {
            await model.prepareForQuit()
            quitReady = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("GodseonDongleOpenMainWindow")
}

/// The menu bar label lives as long as the app, so it is the view that can open the window
/// when nothing else is on screen.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon.onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate()
        }
    }

    private var icon: Image {
        switch model.phase {
        case .connected: return Image(systemName: "antenna.radiowaves.left.and.right")
        case .off, .needsHelper: return Image(systemName: "antenna.radiowaves.left.and.right.slash")
        case .problem, .vmFailed, .dongleError, .noDongle: return Image(systemName: "exclamationmark.triangle")
        default: return Image(systemName: "antenna.radiowaves.left.and.right.circle")
        }
    }
}

struct MenuBarMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(PhaseText(model: model).title)
        Divider()
        Button(t("GodseonDongle 열기")) {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button(t("종료")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
