//
//  ContentView.swift
//  ReelTracker
//
//  Updated on 5/9/25 to use default (primary) colors for text and icons

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
                                .foregroundColor(.primary)  // default black/white  [oai_citation:0‡ContentView.swift.txt](file-service://file-FBp5UVKcuz6nQEysRMJZgB)
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                        .environmentObject(settings)
                }
        }
        .accentColor(.primary)  // ensure default coloring for any tinted elements
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(SettingsViewModel())
    }
}
