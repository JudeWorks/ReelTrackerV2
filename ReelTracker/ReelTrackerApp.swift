//
//  ReelTrackerApp.swift
//  ReelTracker
//
//  Updated on 5/12/25 to inject UserDataStore alongside SettingsViewModel
//

import SwiftUI

@main
struct ReelTrackerApp: App {
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var userData  = UserDataStore.shared

    /// Purge cached data older than the expiration interval on app launch
    init() {
        DataCache.shared.purgeExpiredEntries()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(userData)
        }
    }
}
