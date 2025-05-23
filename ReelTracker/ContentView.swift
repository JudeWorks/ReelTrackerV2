// ContentView.swift
// ReelTracker
//
// Updated on 2025-05-21 to ensure the navigation bar uses dynamic black & white text.
// Updated on 2025-05-22 to add collapsing navigation bar

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var userData: UserDataStore
    @State private var showingSettings = false

    var body: some View {
        NavigationView {
            Group {
                if settings.selectedIds.isEmpty {
                    OnboardingView(showingSettings: $showingSettings)
                        .navigationTitle("Reel Tracker")
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    LimitedRunListView()
                        .navigationBarHidden(false)
                        .navigationBarTitleDisplayMode(.large)
                        .navigationTitle("Reel Tracker")
                }
            }
            .toolbar {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                        .foregroundColor(.primary)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(userData)
            }
        }
        // Force all navigation elements (back button, title, links) to use the dynamic primary color
        .accentColor(.primary)
    }
}

private struct OnboardingView: View {
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "film.stack.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(.primary)

            Text("Welcome to Reel Tracker")
                .font(.title)
                .bold()
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)

            Text("Select one or more theatres in Settings to see your limited-run movies.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)

            Button("Go to Settings") {
                showingSettings = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ContentView()
                .environmentObject(SettingsViewModel())
                .environmentObject(UserDataStore.shared)
                .preferredColorScheme(.light)

            ContentView()
                .environmentObject(SettingsViewModel())
                .environmentObject(UserDataStore.shared)
                .preferredColorScheme(.dark)
        }
    }
}
