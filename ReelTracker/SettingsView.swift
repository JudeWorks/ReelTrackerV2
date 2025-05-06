//
//  SettingsView.swift
//  ReelTracker
//
//  Updated on 5/6/25 to persist ZIP code and selected theatre IDs
//

import SwiftUI
import CoreLocation

/// Local model for display, including distance from user
struct TheatreLocation: Identifiable {
    let id: Int
    let name: String
    let postalCode: String?
    let coordinate: CLLocationCoordinate2D
    let distance: Double    // miles
}

final class SettingsViewModel: ObservableObject {
    // MARK: – UserDefaults keys
    private let zipCodeKey = "zipCode"
    private let selectedIdsKey = "selectedTheatreIds"

    // MARK: – Published properties with persistence
    @Published var zipCode: String {
        didSet {
            UserDefaults.standard.set(zipCode, forKey: zipCodeKey)
        }
    }

    @Published var selectedIds: Set<Int> {
        didSet {
            UserDefaults.standard.set(Array(selectedIds), forKey: selectedIdsKey)
        }
    }

    @Published var isLoading: Bool = false
    @Published var theatres: [TheatreLocation] = []

    private let geocoder = CLGeocoder()
    private var userLocation: CLLocation?

    /// Only the selected theatres
    var selectedTheatres: [TheatreLocation] {
        theatres.filter { selectedIds.contains($0.id) }
    }

    init() {
        // Load saved ZIP (or default to empty)
        self.zipCode = UserDefaults.standard.string(forKey: zipCodeKey) ?? ""
        // Load saved theatre IDs (or default to empty set)
        if let saved = UserDefaults.standard.array(forKey: selectedIdsKey) as? [Int] {
            self.selectedIds = Set(saved)
        } else {
            self.selectedIds = []
        }

        // If we already have a valid ZIP, perform the lookup immediately
        if zipCode.count == 5 {
            lookupTheatres()
        }
    }

    /// 1) Geocode the ZIP -> userLocation
    /// 2) Fetch via postal-code filter
    /// 3) Filter to ≤ 50 miles and compute distance
    func lookupTheatres() {
        guard zipCode.count == 5, Int(zipCode) != nil else { return }
        isLoading = true
        theatres = []

        // Geocode ZIP to lat/lon
        geocoder.geocodeAddressString(zipCode) { placemarks, error in
            guard let loc = placemarks?.first?.location else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.theatres = []
                }
                return
            }
            self.userLocation = loc

            // Fetch theatres with postal-code filter
            AMCAPIClient.shared.fetchTheatres(
                pageNumber: 1,
                pageSize: 1000,
                postalCode: self.zipCode
            ) { result in
                DispatchQueue.main.async {
                    self.isLoading = false
                    switch result {
                    case .success(let resp):
                        guard let userLoc = self.userLocation else {
                            self.theatres = []
                            return
                        }
                        // Map and filter by distance
                        let nearby = resp._embedded.theatres.compactMap { th -> TheatreLocation? in
                            guard
                                let lat = th.location?.latitude,
                                let lon = th.location?.longitude
                            else { return nil }
                            let theatreLoc = CLLocation(latitude: lat, longitude: lon)
                            let miles = theatreLoc.distance(from: userLoc) / 1609.34
                            guard miles <= 50 else { return nil }
                            return TheatreLocation(
                                id: th.id,
                                name: th.name,
                                postalCode: th.location?.postalCode,
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                distance: miles
                            )
                        }
                        self.theatres = nearby.sorted { $0.distance < $1.distance }

                    case .failure(let error):
                        print("Error fetching theatres: \(error)")
                        self.theatres = []
                    }
                }
            }
        }
    }

    /// Toggle a theatre's selection and persist
    func toggleSelection(_ theatre: TheatreLocation) {
        if selectedIds.contains(theatre.id) {
            selectedIds.remove(theatre.id)
        } else {
            selectedIds.insert(theatre.id)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Enter ZIP Code")) {
                    TextField("ZIP Code", text: $settings.zipCode)
                        .keyboardType(.numberPad)
                    Button("Search Theatres") {
                        settings.lookupTheatres()
                    }
                    .disabled(!(settings.zipCode.count == 5 && Int(settings.zipCode) != nil))
                }

                Section(header: Text("Theatres within 50 miles")) {
                    if settings.isLoading {
                        ProgressView("Loading…")
                    } else if settings.theatres.isEmpty {
                        Text("No theatres found within 50 miles of ZIP \(settings.zipCode).")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(settings.theatres) { theatre in
                            Button {
                                settings.toggleSelection(theatre)
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: settings.selectedIds.contains(theatre.id)
                                          ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(theatre.name)
                                        if let pc = theatre.postalCode {
                                            Text(pc)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Text(String(format: "%.1f mi", theatre.distance))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !settings.selectedTheatres.isEmpty {
                    Section(header: Text("Selected Theatres")) {
                        ForEach(settings.selectedTheatres) { t in
                            Text(t.name)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(SettingsViewModel())
    }
}
