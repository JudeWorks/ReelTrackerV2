//
//  ReelTrackerApp.swift
//  ReelTracker
//
//  Updated on 5/8/25 to purge expired cache at launch
//

import SwiftUI

@main
struct ReelTrackerApp: App {
    @StateObject private var settings = SettingsViewModel()

    /// Purge cached data older than the expiration interval on app launch
    init() {
        DataCache.shared.purgeExpiredEntries()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
        }
    }
}
