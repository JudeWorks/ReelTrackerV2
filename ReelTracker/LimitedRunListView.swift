import SwiftUI
import UIKit

/// Types of release classifications
enum ReleaseType: String, CaseIterable {
    case live             = "Live"
    case sensoryFriendly  = "Sensory-Friendly"
    case specialEvent     = "Special Event"
    case leavingSoon      = "Leaving Soon"
    case trueLimitedRun   = "Limited Run"
}

/// Model for a limited-run movie item
struct LimitedMovie: Identifiable {
    let id: Int
    let name: String
    let showtimeCount: Int      // total across theatres
    let nextShowing: Date?
    let nextShowingUrl: String
    let posterUrl: String
    let limitedRun: Bool
    let theatreIds: Set<Int>
    let availableForAList: Bool
    let releaseType: ReleaseType
}

/// ViewModel for fetching, filtering, and classifying limited-run movies
@MainActor
final class LimitedRunViewModel: ObservableObject {
    @Published var limitedMovies: [LimitedMovie] = []
    @Published var isLoading: Bool = false

    /// Token to identify the current fetch session and ignore stale callbacks
    private var fetchToken: UUID?

    private let threshold = 10
    private let specialThreshold = 5
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Fetch and classify movies based on selected theatre IDs, using correct time zones
    func fetchLimitedMovies(theatreIds: [Int]) {
        // Generate a new token and assign
        let callID = UUID()
        fetchToken = callID

        // If no theatres, clear and stop
        guard !theatreIds.isEmpty else {
            DispatchQueue.main.async {
                self.limitedMovies = []
                self.isLoading = false
            }
            return
        }

        DispatchQueue.main.async {
            self.isLoading = true
        }

        // 1) Fetch theatre time zones
        AMCAPIClient.shared.fetchTheatreTimeZones(for: theatreIds) { [weak self] tzResult in
            guard let self = self, self.fetchToken == callID else { return }
            switch tzResult {
            case .failure:
                // On error, bail
                DispatchQueue.main.async {
                    self.limitedMovies = []
                    self.isLoading = false
                }

            case .success(let zoneMap):
                // 2) Fetch showtimes for each theatre in parallel
                let theatreCount = theatreIds.count
                var taggedChunks: [[(theatreId: Int, showtime: Showtime)]] = Array(repeating: [], count: theatreCount)
                let showtimeGroup = DispatchGroup()

                for (index, theatreId) in theatreIds.enumerated() {
                    showtimeGroup.enter()
                    AMCAPIClient.shared.fetchShowtimes(
                        theatreId: theatreId,
                        movieId: nil,
                        date: nil,
                        pageNumber: 1,
                        pageSize: 1000
                    ) { [weak self] result in
                        defer { showtimeGroup.leave() }
                        guard let self = self, self.fetchToken == callID else { return }
                        if case .success(let resp) = result {
                            taggedChunks[index] = resp._embedded.showtimes.map { (theatreId: theatreId, showtime: $0) }
                        }
                    }
                }

                // 3) Once all showtime fetches complete, flatten and process
                showtimeGroup.notify(queue: .main) { [weak self] in
                    guard let self = self, self.fetchToken == callID else { return }

                    let allTagged = taggedChunks.flatMap { $0 }
                    let now = Date()
                    var totalCounts: [Int: Int] = [:]
                    var nextDates: [Int: Date] = [:]
                    var nextUrls: [Int: String] = [:]
                    let movieToTheatres = Dictionary(
                        grouping: allTagged,
                        by: { $0.showtime.movieId }
                    ).mapValues { Set($0.map { $0.theatreId }) }

                    // Aggregate counts and next showtime
                    for tagged in allTagged {
                        let mid = tagged.showtime.movieId
                        totalCounts[mid, default: 0] += 1

                        // Parse with theatre-specific time zone
                        let zone = zoneMap[tagged.theatreId] ?? TimeZone.current
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                        formatter.timeZone = zone
                        if let dt = formatter.date(from: tagged.showtime.showDateTimeLocal), dt >= now {
                            if let existing = nextDates[mid], dt < existing {
                                nextDates[mid] = dt
                                nextUrls[mid] = tagged.showtime.purchaseUrl
                            } else if nextDates[mid] == nil {
                                nextDates[mid] = dt
                                nextUrls[mid] = tagged.showtime.purchaseUrl
                            }
                        }
                    }

                    // 4) Batch-fetch movie details
                    let movieIds = Array(totalCounts.keys)
                    AMCAPIClient.shared.fetchMoviesByIds(ids: movieIds) { [weak self] result in
                        guard let self = self, self.fetchToken == callID else { return }

                        var movies: [Movie] = []
                        if case .success(let resp) = result {
                            movies = resp._embedded.movies
                        }

                        // Classify each movie
                        let classified: [LimitedMovie] = movies.compactMap { m in
                            guard let theatres = movieToTheatres[m.id] else { return nil }

                            // Per-theatre counts
                            var countsByTheatre: [Int: Int] = [:]
                            allTagged
                                .filter { $0.showtime.movieId == m.id }
                                .forEach { entry in
                                    countsByTheatre[entry.theatreId, default: 0] += 1
                                }
                            let minCount = countsByTheatre.values.min() ?? 0
                            let maxCount = countsByTheatre.values.max() ?? 0
                            let totalCount = totalCounts[m.id] ?? 0
                            let next = nextDates[m.id]
                            let url = nextUrls[m.id] ?? ""
                            let aList = m.availableForAList ?? false

                            // Flags
                            let isLive    = m.attributes?.contains { $0.code.lowercased().contains("live") } ?? false
                            let isSensory = m.attributes?.contains { $0.code.lowercased().contains("sensory") } ?? false

                            // Days since release
                            let daysSinceRelease: Int? = {
                                guard let rdStr = m.releaseDateUtc,
                                      let rd    = self.isoFormatter.date(from: rdStr)
                                else { return nil }
                                return Calendar.current.dateComponents([.day], from: rd, to: now).day
                            }()

                            // Determine releaseType
                            let releaseType: ReleaseType
                            if isLive {
                                releaseType = .live
                            } else if isSensory {
                                releaseType = .sensoryFriendly
                            } else if let age = daysSinceRelease, age <= 1 && maxCount <= self.specialThreshold {
                                releaseType = .specialEvent
                            } else if let age = daysSinceRelease, age > self.threshold && minCount <= self.threshold {
                                releaseType = .leavingSoon
                            } else if let age = daysSinceRelease, age <= self.threshold && minCount <= self.threshold {
                                releaseType = .trueLimitedRun
                            } else {
                                return nil
                            }

                            // Poster URL fallback
                            let posterUrl: String = {
                                if let thumb = m.media?.posterDynamic180X74, !thumb.isEmpty {
                                    return thumb
                                }
                                return m.media?.posterDynamic ?? ""
                            }()

                            return LimitedMovie(
                                id:                m.id,
                                name:              m.name,
                                showtimeCount:     totalCount,
                                nextShowing:       next,
                                nextShowingUrl:    url,
                                posterUrl:         posterUrl,
                                limitedRun:        minCount <= self.threshold,
                                theatreIds:        theatres,
                                availableForAList: aList,
                                releaseType:       releaseType
                            )
                        }

                        // Publish results once and reset loading state
                        DispatchQueue.main.async {
                            self.limitedMovies = classified.sorted {
                                ($0.nextShowing ?? Date.distantFuture) < ($1.nextShowing ?? Date.distantFuture)
                            }
                            self.isLoading = false
                        }
                    }
                }
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

    /// Formatter for “Next Showing”
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
                                VStack(spacing: 8) {
                                    CachedAsyncImage(
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

                                    Text("\(movie.showtimeCount) shows remaining")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)

                                    if let next = movie.nextShowing {
                                        Text("Next: \(Self.displayFormatter.string(from: next))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(8)
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

// Simple image loader with caching
struct CachedAsyncImage: View {
    let urlString: String
    let width: CGFloat
    let height: CGFloat

    private enum LoadState {
        case loading, success(UIImage), failure
    }

    @State private var state: LoadState = .loading
    @State private var retryCount = 0

    private var encodedURL: URL? {
        guard !urlString.isEmpty,
              let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: encoded)
    }

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(width: width, height: height)
                .onAppear { loadImage() }
        case .success(let img):
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
        case .failure:
            Image(systemName: "photo")
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
        }
    }

    private func loadImage() {
        guard let url = encodedURL else {
            state = .failure
            return
        }
        if let data = DataCache.shared.data(forKey: url.absoluteString),
           let img = UIImage(data: data) {
            state = .success(img)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let d = data, let img = UIImage(data: d) {
                DataCache.shared.store(d, forKey: url.absoluteString)
                DispatchQueue.main.async { state = .success(img) }
            } else if retryCount < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { loadImage() }
            } else {
                DispatchQueue.main.async { state = .failure }
            }
        }.resume()
    }
}

struct LimitedRunListView_Previews: PreviewProvider {
    static var previews: some View {
        LimitedRunListView()
            .environmentObject(SettingsViewModel())
            .environmentObject(UserDataStore.shared)
    }
}
