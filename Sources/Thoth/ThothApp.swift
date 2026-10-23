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
        Image(systemName: "gauge.open.with.lines.needle.33percent")
            .symbolEffect(.pulse, options: .repeating, isActive: service.activityState != .sleep)
            .onAppear {
                service.start()
            }
    }
}
