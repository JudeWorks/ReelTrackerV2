//
//  AMCMovieFetchService.swift
//  ReelTracker
//
//  Created on 5/9/25
//  Updated on 5/10/25 to unify fetch logic
//

import Foundation

/// Intermediate aggregation of showtimes per movie
struct LimitedRunAggregate {
    let movieId: Int
    let showtimeCount: Int
    let nextShowing: Date?
    let purchaseUrl: String
    let theatreIds: Set<Int>
}

actor AMCMovieFetchService {
    public static let shared = AMCMovieFetchService()

    private let threshold: Int
    private let isoFormatter: ISO8601DateFormatter

    init(threshold: Int = 10) {
        self.threshold = threshold
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = iso
    }

    /// Fetch all showtimes across the given theatres
    func fetchShowtimes(for theatreIds: [Int]) async throws -> [(theatreId: Int, showtime: Showtime)] {
        try await withThrowingTaskGroup(of: [(theatreId: Int, showtime: Showtime)].self) { group in
            for id in theatreIds {
                group.addTask {
                    let sts = try await self.fetchShowtimesOnce(theatreId: id)
                    return sts.map { (theatreId: id, showtime: $0) }
                }
            }
            var allTagged: [(theatreId: Int, showtime: Showtime)] = []
            for try await chunk in group {
                allTagged.append(contentsOf: chunk)
            }
            return allTagged
        }
    }

    /// Single-page fetch of showtimes for one theatre
    private func fetchShowtimesOnce(theatreId: Int) async throws -> [Showtime] {
        try await withCheckedThrowingContinuation { cont in
            AMCAPIClient.shared.fetchShowtimes(
                theatreId: theatreId,
                movieId: nil,
                date: nil,
                pageNumber: 1,
                pageSize: 1_000
            ) { result in
                switch result {
                case .success(let resp):
                    cont.resume(returning: resp._embedded.showtimes)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Aggregate raw showtimes into per-movie stats
    func aggregateShowtimes(_ tagged: [(theatreId: Int, showtime: Showtime)]) -> [LimitedRunAggregate] {
        let now = Date()
        let byMovie = Dictionary(grouping: tagged, by: { $0.showtime.movieId })

        return byMovie.compactMap { movieId, entries in
            let count = entries.count
            // Find the next future showing
            let future = entries.compactMap { (theatreId, showtime) -> (Date, String)? in
                guard
                    let dt = isoFormatter.date(from: showtime.showDateTimeLocal),
                    dt >= now
                else { return nil }
                return (dt, showtime.purchaseUrl)
            }
            let (nextDate, nextURL) = future.min(by: { $0.0 < $1.0 }) ?? (nil, "")
            let theatreSet = Set(entries.map { $0.theatreId })

            return LimitedRunAggregate(
                movieId: movieId,
                showtimeCount: count,
                nextShowing: nextDate,
                purchaseUrl: nextURL,
                theatreIds: theatreSet
            )
        }
    }

    /// Fetch detailed Movie objects for the given IDs
    func fetchMovies(ids: [Int]) async throws -> [Movie] {
        guard !ids.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { cont in
            AMCAPIClient.shared.fetchMoviesByIds(
                ids: ids,
                pageNumber: 1,
                pageSize: ids.count
            ) { result in
                switch result {
                case .success(let resp):
                    cont.resume(returning: resp._embedded.movies)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Combine aggregates and movies into final LimitedMovie items
    func classify(movies: [Movie], aggregates: [LimitedRunAggregate]) -> [LimitedMovie] {
        let aggById = Dictionary(uniqueKeysWithValues: aggregates.map { ($0.movieId, $0) })
        let now = Date()

        return movies.compactMap { movie in
            guard let agg = aggById[movie.id] else { return nil }

            let isLive = movie.attributes?.contains { $0.code.lowercased().contains("live") } ?? false
            let isSensory = movie.attributes?.contains { $0.code.lowercased().contains("sensory") } ?? false

            let daysSinceRelease: Int? = {
                guard
                    let rd = movie.releaseDateUtc,
                    let date = isoFormatter.date(from: rd)
                else { return nil }
                return Calendar.current.dateComponents([.day], from: date, to: now).day
            }()

            let type: ReleaseType
            if isLive {
                type = .live
            } else if isSensory {
                type = .sensoryFriendly
            } else if let age = daysSinceRelease, age > 14 && agg.showtimeCount <= threshold {
                type = .leavingSoon
            } else if let age = daysSinceRelease, age <= 14 && agg.showtimeCount < threshold {
                type = .trueLimitedRun
            } else {
                return nil
            }

            let posterUrl = movie.media?.posterDynamic ?? ""

            return LimitedMovie(
                id: movie.id,
                name: movie.name,
                showtimeCount: agg.showtimeCount,
                nextShowing: agg.nextShowing,
                nextShowingUrl: agg.purchaseUrl,
                posterUrl: posterUrl,
                limitedRun: (type == .trueLimitedRun),
                theatreIds: agg.theatreIds,
                releaseType: type
            )
        }
        .sorted {
            let a = $0.nextShowing ?? Date.distantFuture
            let b = $1.nextShowing ?? Date.distantFuture
            return a < b
        }
    }

    /// High-level API: fetch, aggregate, classify — all in one call
    func fetchLimitedMovies(for theatreIds: [Int]) async throws -> [LimitedMovie] {
        let tagged      = try await fetchShowtimes(for: theatreIds)
        let aggregates  = aggregateShowtimes(tagged)
        let movies      = try await fetchMovies(ids: aggregates.map { $0.movieId })
        return classify(movies: movies, aggregates: aggregates)
    }
}
