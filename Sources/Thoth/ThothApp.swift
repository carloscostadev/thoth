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
        // The Thoth symbol is a drawn template image, not an SF Symbol, so it takes
        // no symbol effects: the activity state shows in the popover instead.
        Image(nsImage: ThothMark.menuBarImage)
            .onAppear {
                service.start()
            }
    }
}
