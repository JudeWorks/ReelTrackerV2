//
//  ContentView.swift
//  ReelTracker
//
//  Updated on 5/6/25 to remove bottom tab bar
//
import SwiftUI

struct ContentView: View {
    @StateObject private var settings = SettingsViewModel()
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            LimitedRunListView()
                .environmentObject(settings)
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
