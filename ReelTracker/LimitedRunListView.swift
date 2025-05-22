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

    /// Apply hidden, release-type, and A-List filters, then sort
    private var sortedAndFiltered: [LimitedMovie] {
        let visible = vm.limitedMovies.filter { movie in
            if userData.isHidden(movie: movie.id) { return false }
            guard settings.selectedReleaseTypes.contains(movie.releaseType) else { return false }
            if settings.showAListOnly && !movie.availableForAList { return false }
            return true
        }

        switch settings.sortOption {
        case .alphabetical:
            return visible.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .remainingShowings:
            return visible.sorted { $0.showtimeCount > $1.showtimeCount }
        case .nextShowingDate:
            return visible.sorted {
                let a = $0.nextShowing ?? Date.distantFuture
                let b = $1.nextShowing ?? Date.distantFuture
                return a < b
            }
        }
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

    var body: some View {
        Group {
            if settings.selectedIds.isEmpty {
                Text("Please select theatres in Settings.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else if vm.isLoading {
                ProgressView("Loading…")
            } else if sortedAndFiltered.isEmpty {
                Text("No movies found for the selected filters.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(sortedAndFiltered) { movie in
                            NavigationLink(destination: MovieDetailView(movieId: movie.id)) {
                                VStack(alignment: .center, spacing: 8) {
                                    OptimizedAsyncImage(
                                        urlString: movie.posterUrl,
                                        width: UIScreen.main.bounds.width/2 - 24,
                                        height: (UIScreen.main.bounds.width/2 - 24) * 1.5
                                    )
                                    .cornerRadius(8)
                                    .clipped()

                                    Text(movie.releaseType.rawValue)
                                        .font(.caption).bold()
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 8)
                                        .background(Color.primary.opacity(0.1))
                                        .cornerRadius(8)

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
