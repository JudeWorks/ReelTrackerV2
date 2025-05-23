import SwiftUI
import UIKit

/// ViewModel for fetching and managing limited-run movies
@MainActor
final class LimitedRunViewModel: ObservableObject {
    @Published var limitedMovies: [LimitedMovie] = []
    @Published var isLoading: Bool = false

    /// Fetch limited movies using the AMCMovieFetchService
    func fetchLimitedMovies(theatreIds: [Int]) {
        guard !theatreIds.isEmpty else {
            limitedMovies = []
            isLoading = false
            return
        }

        isLoading = true
        
        Task {
            do {
                let movies = try await AMCMovieFetchService.shared.fetchLimitedMovies(for: theatreIds)
                // Debug: Log the movies and their counts
                for movie in movies {
                    if movie.showtimeCount == 0 {
                        print("DEBUG: \(movie.name) has \(movie.showtimeCount) showings, next: \(movie.nextShowing?.description ?? "nil")")
                    }
                }
                limitedMovies = movies
                isLoading = false
            } catch {
                print("Error fetching limited movies: \(error)")
                limitedMovies = []
                isLoading = false
            }
        }
    }
}

struct LimitedRunListView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var userData: UserDataStore
    @StateObject private var vm = LimitedRunViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    /// Formatter for "Next Showing"
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = .current
        return f
    }()

    /// Apply hidden, release-type, and A-List filters, then group and sort
    private var groupedMovies: [(type: ReleaseType, movies: [LimitedMovie])] {
        // First, filter movies
        let filtered = vm.limitedMovies.filter { movie in
            if userData.isHidden(movie: movie.id) { return false }
            guard settings.selectedReleaseTypes.contains(movie.releaseType) else { return false }
            if settings.showAListOnly && !movie.availableForAList { return false }
            return true
        }
        
        // Group by release type
        let grouped = Dictionary(grouping: filtered) { $0.releaseType }
        
        // Create ordered sections with Limited Release first, then Leaving Soon
        var sections: [(type: ReleaseType, movies: [LimitedMovie])] = []
        
        // Add sections in preferred order
        let orderedTypes: [ReleaseType] = [.limitedRelease, .leavingSoon, .live, .sensoryFriendly]
        
        for type in orderedTypes {
            if let movies = grouped[type], !movies.isEmpty {
                // Sort movies within each section
                let sorted: [LimitedMovie]
                switch settings.sortOption {
                case .alphabetical:
                    sorted = movies.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                case .remainingShowings:
                    sorted = movies.sorted { $0.showtimeCount > $1.showtimeCount }
                case .nextShowingDate:
                    sorted = movies.sorted {
                        let a = $0.nextShowing ?? Date.distantFuture
                        let b = $1.nextShowing ?? Date.distantFuture
                        return a < b
                    }
                }
                sections.append((type: type, movies: sorted))
            }
        }
        
        return sections
    }
    
    /// Format next showing date in a concise way
    private func formatNextShowing(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "Today \(formatter.string(from: date))"
        } else if calendar.isDateInTomorrow(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "Tomorrow \(formatter.string(from: date))"
        } else if let days = calendar.dateComponents([.day], from: now, to: date).day, days < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE h:mm a"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, h:mm a"
            return formatter.string(from: date)
        }
    }
    
    /// Get display name for release type
    private func sectionTitle(for type: ReleaseType) -> String {
        switch type {
        case .limitedRelease: return "Limited Release"
        case .leavingSoon: return "Leaving Soon"
        case .live: return "Live Events"
        case .sensoryFriendly: return "Sensory Friendly"
        }
    }

    var body: some View {
        Group {
            if settings.selectedIds.isEmpty {
                Text("Please select theatres in Settings.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else if vm.isLoading {
                ProgressView("Loading…")
            } else if groupedMovies.isEmpty {
                Text("No movies found for the selected filters.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groupedMovies, id: \.type) { section in
                            Section {
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(section.movies) { movie in
                                        NavigationLink(destination: MovieDetailView(movieId: movie.id)) {
                                            VStack(alignment: .center, spacing: 8) {
                                                OptimizedAsyncImage(
                                                    urlString: movie.posterUrl,
                                                    width: UIScreen.main.bounds.width/2 - 24,
                                                    height: (UIScreen.main.bounds.width/2 - 24) * 1.5
                                                )
                                                .cornerRadius(8)
                                                .clipped()

                                                Text(movie.name)
                                                    .font(.headline)
                                                    .fontWeight(.semibold)
                                                    .multilineTextAlignment(.center)
                                                    .lineLimit(2)
                                                    .frame(height: 44)

                                                VStack(spacing: 4) {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: "ticket.fill")
                                                            .font(.subheadline)
                                                        Text("\(movie.showtimeCount) showings")
                                                            .font(.subheadline)
                                                    }
                                                    .foregroundColor(.secondary)
                                                    
                                                    if let next = movie.nextShowing {
                                                        HStack(spacing: 4) {
                                                            Image(systemName: "clock.fill")
                                                                .font(.subheadline)
                                                            Text(formatNextShowing(next))
                                                                .font(.subheadline)
                                                        }
                                                        .foregroundColor(.secondary)
                                                    }
                                                }
                                                .frame(height: 44)
                                            }
                                            .padding(8)
                                            .frame(maxHeight: .infinity)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.bottom, 24)
                            } header: {
                                HStack {
                                    Text(sectionTitle(for: section.type))
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                    
                                    Text("\(section.movies.count)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemBackground).opacity(0.95))
                            }
                        }
                    }
                }
                .refreshable {
                    vm.fetchLimitedMovies(theatreIds: Array(settings.selectedIds))
                }
            }
        }
        .task(id: settings.selectedIds) {
            vm.fetchLimitedMovies(theatreIds: Array(settings.selectedIds))
        }
    }
}

struct LimitedRunListView_Previews: PreviewProvider {
    static var previews: some View {
        LimitedRunListView()
            .environmentObject(SettingsViewModel())
            .environmentObject(UserDataStore.shared)
    }
}
