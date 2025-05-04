import SwiftUI

/// Model for limited-run items
struct LimitedMovie: Identifiable {
    let id: Int
    let name: String
    let showtimeCount: Int
    let nextShowing: Date?
    let nextShowingUrl: String
    let posterUrl: String
    let limitedRun: Bool
}

/// ViewModel for fetching and filtering limited-run movies
final class LimitedRunViewModel: ObservableObject {
    @Published var limitedMovies: [LimitedMovie] = []
    @Published var isLoading: Bool = false

    private let threshold = 10
    private let daysWindow = 60

    // Formatter to parse local showtime strings (e.g., "2025-05-03T19:30:00")
    private let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    // ISO formatter for releaseDateUtc if needed
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Fetch limited-run movies based on selected theatre IDs
    func fetchLimitedMovies(theatreIds: [Int]) {
        guard !theatreIds.isEmpty else {
            limitedMovies = []
            return
        }

        isLoading = true
        var allShowtimes: [Showtime] = []
        let showtimeGroup = DispatchGroup()

        // 1) Fetch showtimes for each theatre
        for theatreId in theatreIds {
            showtimeGroup.enter()
            AMCAPIClient.shared.fetchShowtimes(
                theatreId: theatreId,
                movieId: nil,
                date: nil,
                pageNumber: 1,
                pageSize: 1000
            ) { result in
                if case .success(let resp) = result {
                    allShowtimes.append(contentsOf: resp._embedded.showtimes)
                }
                showtimeGroup.leave()
            }
        }

        // 2) Aggregate and fetch movie details
        showtimeGroup.notify(queue: .main, execute: {
            let now = Date()
            var counts: [Int: Int] = [:]
            var nextDates: [Int: Date] = [:]
            var nextUrls: [Int: String] = [:]

            // Aggregate showtime counts and earliest next showing
            for st in allShowtimes {
                counts[st.movieId, default: 0] += 1
                // Parse local showtime
                if let dt = self.localFormatter.date(from: st.showDateTimeLocal), dt >= now {
                    if let existing = nextDates[st.movieId], dt < existing {
                        nextDates[st.movieId] = dt
                        nextUrls[st.movieId] = st.purchaseUrl
                    } else if nextDates[st.movieId] == nil {
                        nextDates[st.movieId] = dt
                        nextUrls[st.movieId] = st.purchaseUrl
                    }
                }
            }

            // 3) Fetch movie details by ID
            let movieGroup = DispatchGroup()
            var movies: [Movie] = []
            for mid in counts.keys {
                movieGroup.enter()
                AMCAPIClient.shared.fetchMoviesByIds(ids: [mid]) { result in
                    if case .success(let resp) = result {
                        movies.append(contentsOf: resp._embedded.movies)
                    }
                    movieGroup.leave()
                }
            }

            // 4) Build limited-run list, sort by nextShowing ascending
            movieGroup.notify(queue: .main, execute: {
                var limited: [LimitedMovie] = []
                for m in movies {
                    let count = counts[m.id] ?? 0
                    let next = nextDates[m.id]
                    let url = nextUrls[m.id] ?? ""
                    // Compute days since release
                    var daysOld: Int? = nil
                    if let rdStr = m.releaseDateUtc,
                       let rd = self.isoFormatter.date(from: rdStr) {
                        daysOld = Calendar.current.dateComponents([.day], from: rd, to: now).day
                    }
                    let isLimited = (daysOld ?? Int.max) <= self.daysWindow && count < self.threshold
                    limited.append(
                        LimitedMovie(
                            id: m.id,
                            name: m.name,
                            showtimeCount: count,
                            nextShowing: next,
                            nextShowingUrl: url,
                            posterUrl: m.media?.posterDynamic ?? "",
                            limitedRun: isLimited
                        )
                    )
                }
                // Filter and sort: movies with nearest nextShowing first
                self.limitedMovies = limited
                    .filter { $0.limitedRun }
                    .sorted { a, b in
                        let aDate = a.nextShowing ?? Date.distantFuture
                        let bDate = b.nextShowing ?? Date.distantFuture
                        return aDate < bDate
                    }
                self.isLoading = false
            })
        })
    }
}

/// SwiftUI view displaying limited-run movies
struct LimitedRunListView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @StateObject private var vm = LimitedRunViewModel()

    /// Formatter for displaying the next showing in a user-friendly style
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = .current
        return f
    }()

    var body: some View {
        Group {
            if settings.selectedIds.isEmpty {
                Text("Please select theatres in Settings.")
                    .foregroundColor(.secondary)
            } else if vm.isLoading {
                ProgressView("Loading…")
            } else {
                List(vm.limitedMovies) { movie in
                    HStack(alignment: .top) {
                        AsyncImage(url: URL(string: movie.posterUrl)) { image in
                            image.resizable()
                                 .scaledToFit()
                        } placeholder: {
                            Color.gray.opacity(0.3)
                        }
                        .frame(width: 60, height: 90)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(movie.name)
                                .font(.headline)
                            Text("Showings: \(movie.showtimeCount)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            if let next = movie.nextShowing {
                                Text("Next: \(Self.displayFormatter.string(from: next))")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            vm.fetchLimitedMovies(theatreIds: Array(settings.selectedIds))
        }
        .onChange(of: settings.selectedIds) {
            vm.fetchLimitedMovies(theatreIds: Array(settings.selectedIds))
        }
    }
}

struct LimitedRunListView_Previews: PreviewProvider {
    static var previews: some View {
        LimitedRunListView()
            .environmentObject(SettingsViewModel())
    }
}
