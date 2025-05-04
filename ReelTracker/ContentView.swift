//
//  ContentView.swift
//  ReelTracker
//
//  Updated on 5/4/25 to remove the “ReelTracker” title
//

import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    @StateObject private var settings = SettingsViewModel()

    var body: some View {
        NavigationView {
            TabView {
                LimitedRunListView()
                    .environmentObject(settings)
                    .tabItem {
                        Label("Limited Run", systemImage: "clock")
                    }
                // other tabs if you add them later…
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(settings)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(SettingsViewModel())
    }
}
