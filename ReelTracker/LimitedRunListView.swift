    //
    //  LimitedRunListView.swift
    //  ReelTracker
    //
    //  Updated on 5/9/25 to support LIVE attribute overriding all others

    import SwiftUI
    import UIKit

    /// Types of release classifications
    enum ReleaseType: String {
        case live             = "Live"
        case sensoryFriendly  = "Sensory-Friendly"
        case leavingSoon      = "Leaving Soon"
        case trueLimitedRun   = "Limited Run"
    }

    /// Model for a limited-run movie item
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

            // 2) After showtimes are fetched
            showtimeGroup.notify(queue: .main) {
                let now = Date()
                var counts: [Int: Int] = [:]
                var nextDates: [Int: Date] = [:]
                var nextUrls: [Int: String] = [:]
                let movieToTheatres = Dictionary(
                    grouping: allTagged,
                    by: { $0.showtime.movieId }
                ).mapValues { Set($0.map { $0.theatreId }) }

                // Count showings and determine next showtime
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

                // 3) Fetch movie details
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

                // 4) Classify and filter
                movieGroup.notify(queue: .main) {
                    let classified: [LimitedMovie] = movies.compactMap { m in
                        let count = counts[m.id] ?? 0
                        let next = nextDates[m.id]
                        let url = nextUrls[m.id] ?? ""
                        let theatres = movieToTheatres[m.id] ?? []

                        // Check for LIVE attribute first
                        let isLive = m.attributes?.contains {
                            $0.code.lowercased().contains("live")
                        } ?? false
                        // Sensory-Friendly flag
                        let isSensoryFriendly = m.attributes?.contains {
                            $0.code.lowercased().contains("sensory")
                        } ?? false

                        // Days since global release
                        let daysSinceRelease: Int? = {
                            guard let rdStr = m.releaseDateUtc,
                                  let rd = self.isoFormatter.date(from: rdStr) else { return nil }
                            return Calendar.current.dateComponents([.day], from: rd, to: now).day
                        }()

                        // Determine release type by priority: Live > Sensory > Leaving Soon > Limited Run
                        let releaseType: ReleaseType
                        if isLive {
                            releaseType = .live
                        } else if isSensoryFriendly {
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

                        // Pick thumbnail if available
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

                    self.limitedMovies = classified.sorted { a, b in
                        let aDate = a.nextShowing ?? Date.distantFuture
                        let bDate = b.nextShowing ?? Date.distantFuture
                        return aDate < bDate
                    }
                    self.isLoading = false
                }
            }
        }
    }

    /// SwiftUI view displaying limited-run movies with classification
    struct LimitedRunListView: View {
        @EnvironmentObject var settings: SettingsViewModel
        @StateObject private var vm = LimitedRunViewModel()

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
                                // Classification badge
                                Text(movie.releaseType.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.blue)

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

    /// A SwiftUI view that caches and displays images from a URL string, with retry and failure placeholder
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

            case .success(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)

            case .failure:
                VStack {
                    Image(systemName: "photo")
                        .font(.title)
                    Text("No Poster Available")
                        .font(.caption)
                }
                .frame(width: width, height: height)
            }
        }

        private func loadImage() {
            guard let url = encodedURL else {
                state = .failure
                return
            }
            let key = url.absoluteString
            // Cache first
            if let data = DataCache.shared.data(forKey: key), let image = UIImage(data: data) {
                state = .success(image)
                return
            }
            // Network
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data = data, let image = UIImage(data: data) {
                    DataCache.shared.store(data, forKey: key)
                    DispatchQueue.main.async { state = .success(image) }
                } else if retryCount < 1 {
                    retryCount += 1
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
