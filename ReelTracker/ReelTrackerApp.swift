//
//  ReelTrackerApp.swift
//  ReelTracker
//
//  Updated on 5/3/25 to inject SettingsViewModel into ContentView
//

import SwiftUI

@main
struct ReelTrackerApp: App {
    @StateObject private var settings = SettingsViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
        }
    }
}
