//
//  LimitedRunListView.swift
//  ReelTracker
//
//  Updated on 5/9/25 to move filtering into Settings and clean up the main view.

import SwiftUI
import UIKit

/// Types of release classifications
enum ReleaseType: String, CaseIterable {
    case live             = "Live"
    case sensoryFriendly  = "Sensory-Friendly"
    case leavingSoon      = "Leaving Soon"
    case trueLimitedRun   = "Limited Run"
}

/// Model for a limited‐run movie item
struct LimitedMovie: Identifiable {
    let id: Int
    let name: String
    let showtimeCount: Int
    let nextShowing: Date?
    let nextShowingUrl: String
    let posterUrl: String
    let limitedRun: Bool
    let theatreIds: Set<Int>
    let releaseType: ReleaseType
}

/// ViewModel for fetching, filtering, and classifying limited‐run movies
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

        // 1) Fetch showtimes
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

        // 2) Aggregate and determine next showtime
        showtimeGroup.notify(queue: .main) {
            let now = Date()
            var counts: [Int: Int] = [:]
            var nextDates: [Int: Date] = [:]
            var nextUrls: [Int: String] = [:]
            let movieToTheatres = Dictionary(
                grouping: allTagged,
                by: { $0.showtime.movieId }
            ).mapValues { Set($0.map { $0.theatreId }) }

            for tagged in allTagged {
                let mid = tagged.showtime.movieId
                counts[mid, default: 0] += 1
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
            for mid in counts.keys {
                movieGroup.enter()
                AMCAPIClient.shared.fetchMoviesByIds(ids: [mid]) { result in
                    if case .success(let resp) = result {
                        movies.append(contentsOf: resp._embedded.movies)
                    }
                    movieGroup.leave()
                }
            }

            // 4) Classify each movie
            movieGroup.notify(queue: .main) {
                let classified: [LimitedMovie] = movies.compactMap { m in
                    let count = counts[m.id] ?? 0
                    let next = nextDates[m.id]
                    let url = nextUrls[m.id] ?? ""
                    let theatres = movieToTheatres[m.id] ?? []

                    let isLive = m.attributes?.contains {
                        $0.code.lowercased().contains("live")
                    } ?? false
                    let isSensory = m.attributes?.contains {
                        $0.code.lowercased().contains("sensory")
                    } ?? false

                    let daysSinceRelease: Int? = {
                        guard let rdStr = m.releaseDateUtc,
                              let rd = self.isoFormatter.date(from: rdStr)
                        else { return nil }
                        return Calendar.current.dateComponents([.day], from: rd, to: now).day
                    }()

                    let releaseType: ReleaseType
                    if isLive {
                        releaseType = .live
                    } else if isSensory {
                        releaseType = .sensoryFriendly
                    } else if let age = daysSinceRelease,
                              age > 14 && count <= self.threshold {
                        releaseType = .leavingSoon
                    } else if let age = daysSinceRelease,
                              age <= 14 && count < self.threshold {
                        releaseType = .trueLimitedRun
                    } else {
                        return nil
                    }

                    let posterUrl: String = {
                        if let thumb = m.media?.posterDynamic180X74, !thumb.isEmpty {
                            return thumb
                        }
                        return m.media?.posterDynamic ?? ""
                    }()

                    return LimitedMovie(
                        id: m.id,
                        name: m.name,
                        showtimeCount: count,
                        nextShowing: next,
                        nextShowingUrl: url,
                        posterUrl: posterUrl,
                        limitedRun: releaseType == .trueLimitedRun,
                        theatreIds: theatres,
                        releaseType: releaseType
                    )
                }

                // sort by next showing date
                self.limitedMovies = classified.sorted {
                    let a = $0.nextShowing ?? Date.distantFuture
                    let b = $1.nextShowing ?? Date.distantFuture
                    return a < b
                }
                self.isLoading = false
            }
        }
    }
}

/// SwiftUI view displaying limited‐run movies (filtering now lives in Settings)
struct LimitedRunListView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @StateObject private var vm = LimitedRunViewModel()

    /// Apply the user’s selected release‐type filters (default = all)
    private var filteredMovies: [LimitedMovie] {
        let filters = settings.selectedReleaseTypes
        if filters.count == ReleaseType.allCases.count {
            return vm.limitedMovies
        }
        return vm.limitedMovies.filter { filters.contains($0.releaseType) }
    }

    /// Formatter for “Next Showing”
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
                List(filteredMovies) { movie in
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
        case loading
        case success(UIImage)
        case failure
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
            VStack {
                Image(systemName: "photo")
                Button("Retry") {
                    retryCount += 1
                    loadImage()
                }
            }
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
    }
}
