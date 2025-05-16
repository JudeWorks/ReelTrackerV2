//
//  LimitedRunListView.swift
//  ReelTracker
//
//  Updated on 2025-05-17 to use per-theatre threshold for limited-run logic.
//

import SwiftUI
import UIKit

/// Types of release classifications
enum ReleaseType: String, CaseIterable {
    case live             = "Live"
    case sensoryFriendly  = "Sensory-Friendly"
    case leavingSoon      = "Leaving Soon"
    case trueLimitedRun   = "Limited Run"
}

/// Model for a limited-run movie item
struct LimitedMovie: Identifiable {
    let id: Int
    let name: String
    let showtimeCount: Int      // total across theatres, still useful for display
    let nextShowing: Date?
    let nextShowingUrl: String
    let posterUrl: String
    let limitedRun: Bool        // now based on per-theatre minimum
    let theatreIds: Set<Int>
    let availableForAList: Bool
    let releaseType: ReleaseType
}

/// ViewModel for fetching, filtering, and classifying limited-run movies
final class LimitedRunViewModel: ObservableObject {
    @Published var limitedMovies: [LimitedMovie] = []
    @Published var isLoading: Bool = false

    private let threshold = 10
    private let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Fetch and classify movies based on selected theatre IDs
    func fetchLimitedMovies(theatreIds: [Int]) {
        guard !theatreIds.isEmpty else {
            limitedMovies = []
            return
        }

        isLoading = true
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

        // 2) Aggregate counts and next showtime
        showtimeGroup.notify(queue: .main) {
            let now = Date()
            // total showtime counts per movie
            var totalCounts: [Int: Int] = [:]
            // next showing per movie
            var nextDates: [Int: Date] = [:]
            var nextUrls: [Int: String] = [:]
            // theatres set per movie
            let movieToTheatres = Dictionary(
                grouping: allTagged,
                by: { $0.showtime.movieId }
            ).mapValues { Set($0.map { $0.theatreId }) }

            for tagged in allTagged {
                let mid = tagged.showtime.movieId
                totalCounts[mid, default: 0] += 1
                if let dt = self.localFormatter.date(from: tagged.showtime.showDateTimeLocal),
                   dt >= now {
                    if let existing = nextDates[mid], dt < existing {
                        nextDates[mid] = dt
                        nextUrls[mid] = tagged.showtime.purchaseUrl
                    } else if nextDates[mid] == nil {
                        nextDates[mid] = dt
                        nextUrls[mid] = tagged.showtime.purchaseUrl
                    }
                }
            }

            // 3) Fetch movie details
            let movieGroup = DispatchGroup()
            var movies: [Movie] = []

            for mid in totalCounts.keys {
                movieGroup.enter()
                AMCAPIClient.shared.fetchMoviesByIds(ids: [mid]) { result in
                    if case .success(let resp) = result {
                        movies.append(contentsOf: resp._embedded.movies)
                    }
                    movieGroup.leave()
                }
            }

            // 4) Classify each movie, now using per-theatre threshold
            movieGroup.notify(queue: .main) {
                let classified: [LimitedMovie] = movies.compactMap { m in
                    guard let theatres = movieToTheatres[m.id] else { return nil }

                    // build per-theatre showtime counts for this movie
                    var countsByTheatre: [Int: Int] = [:]
                    allTagged
                        .filter { $0.showtime.movieId == m.id }
                        .forEach { entry in
                            countsByTheatre[entry.theatreId, default: 0] += 1
                        }
                    // the smallest count across your chosen theatres
                    let minCount = countsByTheatre.values.min() ?? 0

                    // still keep total count for display
                    let totalCount = totalCounts[m.id] ?? 0
                    let next = nextDates[m.id]
                    let url = nextUrls[m.id] ?? ""

                    // A-List eligibility
                    let aList = m.availableForAList ?? false

                    // attribute checks
                    let isLive    = m.attributes?.contains { $0.code.lowercased().contains("live") } ?? false
                    let isSensory = m.attributes?.contains { $0.code.lowercased().contains("sensory") } ?? false

                    // days since release
                    let daysSinceRelease: Int? = {
                        guard let rdStr = m.releaseDateUtc,
                              let rd    = self.isoFormatter.date(from: rdStr)
                        else { return nil }
                        return Calendar.current.dateComponents([.day], from: rd, to: now).day
                    }()

                    // decide releaseType
                    let releaseType: ReleaseType
                    if isLive {
                        releaseType = .live
                    } else if isSensory {
                        releaseType = .sensoryFriendly
                    } else if let age = daysSinceRelease, age > 14 && minCount <= self.threshold {
                        releaseType = .leavingSoon
                    } else if let age = daysSinceRelease, age <= 14 && minCount < self.threshold {
                        releaseType = .trueLimitedRun
                    } else {
                        return nil
                    }

                    // pick a poster
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
                        limitedRun:        minCount < self.threshold,
                        theatreIds:        theatres,
                        availableForAList: aList,
                        releaseType:       releaseType
                    )
                }

                // sort by next showing date
                self.limitedMovies = classified.sorted {
                    let a = $0.nextShowing ?? .distantFuture
                    let b = $1.nextShowing ?? .distantFuture
                    return a < b
                }
                self.isLoading = false
            }
        }
    }
}

struct LimitedRunListView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var userData: UserDataStore
    @StateObject private var vm = LimitedRunViewModel()

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
            // 1) Hidden vs. release-type
            if userData.isHidden(movie: movie.id) {
                guard settings.showHiddenMovies else { return false }
            } else {
                guard settings.selectedReleaseTypes.contains(movie.releaseType) else { return false }
            }
            // 2) A-List toggle
            if settings.showAListOnly && !movie.availableForAList {
                return false
            }
            return true
        }

        // 3) Sort per user choice
        switch settings.sortOption {
        case .alphabetical:
            return visible.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .remainingShowings:
            return visible.sorted { $0.showtimeCount > $1.showtimeCount }
        case .nextShowingDate:
            return visible.sorted {
                let a = $0.nextShowing ?? .distantFuture
                let b = $1.nextShowing ?? .distantFuture
                return a < b
            }
        }
    }

    var body: some View {
        Group {
            if settings.selectedIds.isEmpty {
                Text("Please select theatres in Settings.")
                    .foregroundColor(.secondary)
            } else if vm.isLoading {
                ProgressView("Loading…")
            } else if sortedAndFiltered.isEmpty {
                Text("No movies found for the selected filters.")
                    .foregroundColor(.secondary)
            } else {
                List(sortedAndFiltered) { movie in
                    HStack(alignment: .top) {
                        CachedAsyncImage(
                            urlString: movie.posterUrl,
                            width: 60,
                            height: 90
                        )
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
                            Text(movie.releaseType.rawValue)
                                .font(.caption)
                                .foregroundColor(.primary)

                            let total = settings.selectedIds.count
                            let playing = movie.theatreIds.count
                            Text(
                                playing == total
                                    ? "Playing at all selected theatres"
                                    : "Playing at \(playing) of \(total) theatres"
                            )
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if userData.isHidden(movie: movie.id) {
                            Button {
                                userData.unhide(movie: movie.id)
                            } label: {
                                Label("Unhide", systemImage: "eye")
                            }
                        } else {
                            Button(role: .destructive) {
                                userData.hide(movie: movie.id)
                            } label: {
                                Label("Hide", systemImage: "eye.slash")
                            }
                        }
                    }
                }
                .refreshable {
                    vm.fetchLimitedMovies(theatreIds: Array(settings.selectedIds))
                    DataCache.shared.purgeExpiredEntries()
                }
            }
        }
        .task(id: settings.selectedIds) {
            vm.fetchLimitedMovies(theatreIds: Array(settings.selectedIds))
            DataCache.shared.purgeExpiredEntries()
        }
    }
}

/// A SwiftUI view that caches and displays images from a URL, with retry and placeholder
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
                .scaledToFit()
                .frame(width: width, height: height)

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
