// Sources/Thoth/ThothApp.swift
import SwiftUI
import AppKit

@main
struct ThothApp: App {
    @State private var service = ClaudeDataService()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(service: service)
        } label: {
            MenuBarLabel(service: service)
        }
        .menuBarExtraStyle(.window)
        .defaultSize(width: 380, height: 500)
    }

    init() {
        // Hide dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    let service: ClaudeDataService

    var body: some View {
        // Full mark while Claude Code is working, dimmed while it sleeps. No animation:
        // the image only swaps when the state changes.
        Image(nsImage: service.activityState == .sleep ? ThothMark.menuBarImageDimmed : ThothMark.menuBarImage)
            .onAppear {
                service.start()
            }
    }
}
