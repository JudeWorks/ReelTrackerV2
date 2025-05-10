//
//  SettingsView.swift
//  ReelTracker
//
//  Updated on 5/9/25 to fix deprecated onChange signatures for iOS 17

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
    private let zipCodeKey               = "zipCode"
    private let selectedIdsKey           = "selectedTheatreIds"
    private let selectedReleaseTypesKey  = "selectedReleaseTypes"
    private let distanceKey              = "searchDistance"

    // MARK: – Published properties with persistence
    @Published var zipCode: String {
        didSet { UserDefaults.standard.set(zipCode, forKey: zipCodeKey) }
    }
    @Published var selectedIds: Set<Int> {
        didSet { UserDefaults.standard.set(Array(selectedIds), forKey: selectedIdsKey) }
    }
    @Published var selectedReleaseTypes: Set<ReleaseType> {
        didSet {
            let raw = selectedReleaseTypes.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: selectedReleaseTypesKey)
        }
    }
    @Published var searchDistance: Double {
        didSet { UserDefaults.standard.set(searchDistance, forKey: distanceKey) }
    }

    @Published var isLoading: Bool = false
    @Published var theatres: [TheatreLocation] = []

    private let geocoder      = CLGeocoder()
    private var userLocation: CLLocation?

    /// Only the selected theatres
    var selectedTheatres: [TheatreLocation] {
        theatres.filter { selectedIds.contains($0.id) }
    }

    init() {
        self.zipCode = UserDefaults.standard.string(forKey: zipCodeKey) ?? ""
        if let saved = UserDefaults.standard.array(forKey: selectedIdsKey) as? [Int] {
            self.selectedIds = Set(saved)
        } else {
            self.selectedIds = []
        }
        if let saved = UserDefaults.standard.array(forKey: selectedReleaseTypesKey) as? [String] {
            let types = Set(saved.compactMap { ReleaseType(rawValue: $0) })
            self.selectedReleaseTypes = types.isEmpty ? Set(ReleaseType.allCases) : types
        } else {
            self.selectedReleaseTypes = Set(ReleaseType.allCases)
        }
        let savedDist = UserDefaults.standard.double(forKey: distanceKey)
        self.searchDistance = savedDist > 0 ? savedDist : 50

        if zipCode.count == 5 {
            lookupTheatres()
        }
    }

    /// Perform theatre lookup with current ZIP and searchDistance
    func lookupTheatres() {
        guard zipCode.count == 5, Int(zipCode) != nil else { return }
        isLoading = true
        theatres = []

        geocoder.geocodeAddressString(zipCode) { placemarks, _ in
            guard let loc = placemarks?.first?.location else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.theatres = []
                }
                return
            }
            self.userLocation = loc

            AMCAPIClient.shared.fetchTheatres(
                pageNumber: 1,
                pageSize: 1000,
                postalCode: self.zipCode
            ) { result in
                DispatchQueue.main.async {
                    self.isLoading = false
                    switch result {
                    case .success(let resp):
                        let nearby = resp._embedded.theatres.compactMap { th -> TheatreLocation? in
                            guard
                                let lat = th.location?.latitude,
                                let lon = th.location?.longitude
                            else { return nil }
                            let miles = loc.distance(
                                from: CLLocation(latitude: lat, longitude: lon)
                            ) / 1609.34
                            guard miles <= self.searchDistance else { return nil }
                            return TheatreLocation(
                                id: th.id,
                                name: th.name,
                                postalCode: th.location?.postalCode,
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                distance: miles
                            )
                        }
                        self.theatres = nearby.sorted { $0.distance < $1.distance }
                    case .failure:
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
    @FocusState private var zipFieldFocused: Bool
    @State private var zipSearchWorkItem: DispatchWorkItem?

    var body: some View {
        NavigationView {
            Form {
                // Filters
                Section(header: Text("Filters")) {
                    ForEach(ReleaseType.allCases, id: \.self) { type in
                        Toggle(type.rawValue, isOn: Binding(
                            get:  { settings.selectedReleaseTypes.contains(type) },
                            set: { newValue in
                                if newValue {
                                    settings.selectedReleaseTypes.insert(type)
                                } else {
                                    settings.selectedReleaseTypes.remove(type)
                                }
                            }
                        ))
                        .tint(.primary)
                    }
                }

                // ZIP + Search + Distance slider
                Section(header: Text("Search Area")) {
                    HStack {
                        TextField("ZIP Code", text: $settings.zipCode)
                            .keyboardType(.numberPad)
                            .focused($zipFieldFocused)

                        if !settings.zipCode.isEmpty {
                            Button {
                                zipFieldFocused = false
                                settings.lookupTheatres()
                            } label: {
                                Image(systemName: "magnifyingglass.circle.fill")
                                    .imageScale(.large)
                                    .foregroundColor(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        Text("Distance: \(Int(settings.searchDistance)) mi")
                        Slider(
                            value: $settings.searchDistance,
                            in: 1...100,
                            step: 1
                        )
                        .tint(.primary)
                        .onChange(of: settings.searchDistance) { oldValue, newValue in
                            if settings.zipCode.count == 5 {
                                settings.lookupTheatres()
                            }
                        }
                    }
                }

                // Theatres list
                Section(header: Text("Theatres within \(Int(settings.searchDistance)) miles")) {
                    if settings.isLoading {
                        ProgressView()
                    } else if settings.theatres.isEmpty {
                        Text("No theatres found.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(settings.theatres) { theatre in
                            Button {
                                settings.toggleSelection(theatre)
                            } label: {
                                HStack {
                                    Image(systemName:
                                        settings.selectedIds.contains(theatre.id)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
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

                // Selected summary
                if !settings.selectedTheatres.isEmpty {
                    Section(header: Text("Selected Theatres")) {
                        ForEach(settings.selectedTheatres) {
                            Text($0.name)
                        }
                    }
                }
            }
            .accentColor(.primary)
            .navigationTitle("Settings")
            .onTapGesture {
                zipFieldFocused = false
            }
            .onChange(of: zipFieldFocused) { oldValue, focused in
                if !focused,
                   settings.zipCode.count == 5,
                   Int(settings.zipCode) != nil {
                    settings.lookupTheatres()
                }
            }
            .onChange(of: settings.zipCode) { oldValue, newValue in
                zipSearchWorkItem?.cancel()
                let task = DispatchWorkItem {
                    if newValue.count == 5, Int(newValue) != nil {
                        settings.lookupTheatres()
                    }
                }
                zipSearchWorkItem = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(SettingsViewModel())
    }
}
