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
    let theatreIds: Set<Int>
}

/// ViewModel for fetching and filtering limited-run movies
final class LimitedRunViewModel: ObservableObject {
    @Published var limitedMovies: [LimitedMovie] = []
    @Published var isLoading: Bool = false

    private let threshold = 10
    private let daysWindow = 60

    // Formatter to parse local showtime strings
    private let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    // ISO formatter for releaseDateUtc
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
        // Tag showtimes as tuples: (theatreId, showtime)
        var allTagged: [(theatreId: Int, showtime: Showtime)] = []
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
                    resp._embedded.showtimes.forEach { st in
                        allTagged.append((theatreId: theatreId, showtime: st))
                    }
                }
                showtimeGroup.leave()
            }
        }

        // 2) Once all showtimes are gathered
        showtimeGroup.notify(queue: .main, execute: {
            let now = Date()
            // Map movieId to counts, dates, urls, and theatre sets
            var counts: [Int: Int] = [:]
            var nextDates: [Int: Date] = [:]
            var nextUrls: [Int: String] = [:]
            let movieToTheatres: [Int: Set<Int>] = Dictionary(
                grouping: allTagged,
                by: { $0.showtime.movieId }
            ).mapValues { Set($0.map { $0.theatreId }) }

            for tagged in allTagged {
                let movieId = tagged.showtime.movieId
                counts[movieId, default: 0] += 1
                if let dt = self.localFormatter.date(from: tagged.showtime.showDateTimeLocal), dt >= now {
                    if let existing = nextDates[movieId], dt < existing {
                        nextDates[movieId] = dt
                        nextUrls[movieId] = tagged.showtime.purchaseUrl
                    } else if nextDates[movieId] == nil {
                        nextDates[movieId] = dt
                        nextUrls[movieId] = tagged.showtime.purchaseUrl
                    }
                }
            }

            // 3) Fetch movie details by ID
            let movieGroup = DispatchGroup()
            var movies: [Movie] = []
            for movieId in counts.keys {
                movieGroup.enter()
                AMCAPIClient.shared.fetchMoviesByIds(ids: [movieId]) { result in
                    if case .success(let resp) = result {
                        movies.append(contentsOf: resp._embedded.movies)
                    }
                    movieGroup.leave()
                }
            }

            // 4) Build limited-run list and sort by nextShowing
            movieGroup.notify(queue: .main, execute: {
                let limited = movies.compactMap { m -> LimitedMovie? in
                    let count = counts[m.id] ?? 0
                    let next = nextDates[m.id]
                    let url = nextUrls[m.id] ?? ""
                    var daysOld: Int? = nil
                    if let rdStr = m.releaseDateUtc,
                       let rd = self.isoFormatter.date(from: rdStr) {
                        daysOld = Calendar.current.dateComponents([.day], from: rd, to: now).day
                    }
                    let isLimited = (daysOld ?? Int.max) <= self.daysWindow && count < self.threshold
                    guard isLimited else { return nil }
                    let theatres = movieToTheatres[m.id] ?? []
                    return LimitedMovie(
                        id: m.id,
                        name: m.name,
                        showtimeCount: count,
                        nextShowing: next,
                        nextShowingUrl: url,
                        posterUrl: m.media?.posterDynamic ?? "",
                        limitedRun: isLimited,
                        theatreIds: theatres
                    )
                }
                self.limitedMovies = limited
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

    /// Formatter for displaying the next showing
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
                            Text("Showings Remaining: \(movie.showtimeCount)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            if let next = movie.nextShowing {
                                Text("Next Showing: \(Self.displayFormatter.string(from: next))")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            // theatre availability
                            let selCount = settings.selectedIds.count
                            let mvCount = movie.theatreIds.count
                            if mvCount == selCount {
                                Text("Playing at all selected theatres")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Playing at \(mvCount) of \(selCount) theatres")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
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
    }
}
