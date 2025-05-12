//
//  SettingsView.swift
//  ReelTracker
//
//  Updated on 2025-05-11 to add cancellation for in-flight lookups and Sort By option
//

import SwiftUI
import CoreLocation

// ────────────────────────────────────────────────
// Sort options for how the movie list is ordered
enum SortOption: String, CaseIterable, Identifiable {
    case alphabetical      = "A → Z"
    case remainingShowings = "Showings Remaining"
    case nextShowingDate   = "Next Showing"
    var id: Self { self }
}
// ────────────────────────────────────────────────

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
    private let zipCodeKey              = "zipCode"
    private let selectedIdsKey          = "selectedTheatreIds"
    private let selectedReleaseTypesKey = "selectedReleaseTypes"
    private let distanceKey             = "searchDistance"
    private let sortOptionKey           = "sortOption"      // New key

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
    @Published var sortOption: SortOption {                     // New property
        didSet { UserDefaults.standard.set(sortOption.rawValue, forKey: sortOptionKey) }
    }

    @Published var isLoading: Bool = false
    @Published var theatres: [TheatreLocation] = []

    /// Only the selected theatres
    var selectedTheatres: [TheatreLocation] {
        theatres.filter { selectedIds.contains($0.id) }
    }

    // MARK: – Internal state for lookup & cancellation
    private let geocoder = CLGeocoder()
    private var userLocation: CLLocation?
    private var lookupTask: Task<Void, Never>?

    init() {
        // Load persisted settings
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

        // Load persisted sort option (default to nextShowingDate)
        if let raw = UserDefaults.standard.string(forKey: sortOptionKey),
           let opt = SortOption(rawValue: raw) {
            self.sortOption = opt
        } else {
            self.sortOption = .nextShowingDate
        }

        // Initial lookup if ZIP was already valid
        if zipCode.count == 5, Int(zipCode) != nil {
            lookupTheatres()
        }
    }

    /// Cancel any in-flight geocode or network lookup
    func cancelLookup() {
        lookupTask?.cancel()
        geocoder.cancelGeocode()
    }

    /// Perform theatre lookup with current ZIP and searchDistance, cancellable
    func lookupTheatres() {
        // Cancel previous work
        cancelLookup()

        // Only proceed if ZIP looks valid
        guard zipCode.count == 5, Int(zipCode) != nil else { return }

        // Kick off a new Task
        lookupTask = Task { [weak self] in
            guard let self = self else { return }
            await MainActor.run {
                self.isLoading = true
                self.theatres = []
            }

            // 1) Geocode ZIP
            let placemarks: [CLPlacemark]
            do {
                placemarks = try await withCheckedThrowingContinuation { cont in
                    self.geocoder.geocodeAddressString(self.zipCode) { marks, error in
                        if let error = error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume(returning: marks ?? [])
                        }
                    }
                }
            } catch {
                // Geocode failed (or Task was cancelled)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.isLoading = false
                    self.theatres = []
                }
                return
            }
            if Task.isCancelled { return }
            guard let location = placemarks.first?.location else {
                await MainActor.run {
                    self.isLoading = false
                    self.theatres = []
                }
                return
            }
            self.userLocation = location

            // 2) Fetch theatres from API
            do {
                let response = try await withCheckedThrowingContinuation { cont in
                    AMCAPIClient.shared.fetchTheatres(
                        pageNumber: 1,
                        pageSize: 1000,
                        postalCode: self.zipCode
                    ) { result in
                        cont.resume(with: result.mapError { $0 })
                    }
                }
                if Task.isCancelled { return }

                // 3) Filter by distance
                let nearby = response._embedded.theatres.compactMap { th -> TheatreLocation? in
                    guard
                        let lat = th.location?.latitude,
                        let lon = th.location?.longitude
                    else { return nil }
                    let miles = location
                        .distance(from: CLLocation(latitude: lat, longitude: lon))
                        / 1609.34
                    guard miles <= self.searchDistance else { return nil }
                    return TheatreLocation(
                        id: th.id,
                        name: th.name,
                        postalCode: th.location?.postalCode,
                        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        distance: miles
                    )
                }.sorted { $0.distance < $1.distance }

                await MainActor.run {
                    self.theatres = nearby
                    self.isLoading = false
                }
            } catch {
                // API fetch failed
                if Task.isCancelled { return }
                await MainActor.run {
                    self.theatres = []
                    self.isLoading = false
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
                // ── Sort By ─────────────────────────
                Section(header: Text("Sort By")) {
                    Picker("Sort By", selection: $settings.sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // ── Filters ─────────────────────────
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

                // ── ZIP + Search + Distance ──────────
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
                        .onChange(of: settings.searchDistance) { _, _ in
                            if settings.zipCode.count == 5 {
                                settings.lookupTheatres()
                            }
                        }
                    }
                }

                // ── Theatres List ─────────────────────
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

                // ── Selected Theatres Summary ────────
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
            .onChange(of: zipFieldFocused) { _, focused in
                if !focused,
                   settings.zipCode.count == 5,
                   Int(settings.zipCode) != nil {
                    settings.lookupTheatres()
                }
            }
            .onChange(of: settings.zipCode) { _, newValue in
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
        .onDisappear {
            settings.cancelLookup()
        }
    }
}
