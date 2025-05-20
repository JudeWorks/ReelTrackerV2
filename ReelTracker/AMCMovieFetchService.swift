//
//  AMCMovieFetchService.swift
//  ReelTracker
//
//  Created on 5/9/25
//  Updated on 5/16/25 to fix concurrency, unused variables, and A-List flag
//  Updated on 5/20/25 to support theatre-specific time-zone parsing
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
    /// Shared singleton for easy access
    static let shared = AMCMovieFetchService()

    private let threshold: Int
    private let isoFormatter: ISO8601DateFormatter

    init(threshold: Int = 10) {
        self.threshold = threshold
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = iso
    }

    // MARK: - Fetching Showtimes

    /// Fetch a single page of showtimes for one theatre
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

    /// Concurrently fetch all showtimes across the given theatre IDs
    func fetchShowtimes(for theatreIds: [Int]) async throws -> [(theatreId: Int, showtime: Showtime)] {
        try await withThrowingTaskGroup(of: [(Int, Showtime)].self) { group in
            for id in theatreIds {
                group.addTask {
                    let sts = try await self.fetchShowtimesOnce(theatreId: id)
                    return sts.map { (id, $0) }
                }
            }
            var allTagged: [(Int, Showtime)] = []
            for try await chunk in group {
                allTagged.append(contentsOf: chunk)
            }
            return allTagged
        }
    }

    // MARK: - Time Zone Helper

    /// Async wrapper to fetch theatre time zones
    private func fetchTimeZones(for theatreIds: [Int]) async throws -> [Int: TimeZone] {
        try await withCheckedThrowingContinuation { cont in
            AMCAPIClient.shared.fetchTheatreTimeZones(for: theatreIds) { result in
                switch result {
                case .success(let map): cont.resume(returning: map)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }
    }

    // MARK: - Aggregation

    /// Turn raw showtime tuples into per-movie aggregates, respecting theatre time zones
    func aggregateShowtimes(
        _ tagged: [(theatreId: Int, showtime: Showtime)],
        timeZones: [Int: TimeZone]
    ) -> [LimitedRunAggregate] {
        let now = Date()
        let byMovie = Dictionary(
            grouping: tagged,
            by: { $0.showtime.movieId }
        )

        return byMovie.compactMap { movieId, entries in
            let count = entries.count
            
            // Find the next future showing across all theatres
            let future = entries.compactMap { entry -> (Date, String)? in
                // Parse with theatre-specific time zone
                let tz = timeZones[entry.theatreId] ?? TimeZone.current
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                formatter.timeZone = tz
                
                guard
                    let dt = formatter.date(from: entry.showtime.showDateTimeLocal),
                    dt >= now
                else { return nil }
                return (dt, entry.showtime.purchaseUrl)
            }
            let (nextDate, nextURL) = future.min(by: { $0.0 < $1.0 }) ?? (nil, "")

            let theatreSet = Set(entries.map { $0.theatreId })
            return LimitedRunAggregate(
                movieId:      movieId,
                showtimeCount: count,
                nextShowing:   nextDate,
                purchaseUrl:   nextURL,
                theatreIds:    theatreSet
            )
        }
    }

    // MARK: - Movie Details

    /// Batch‐fetch Movie objects given their IDs
    func fetchMovies(ids: [Int]) async throws -> [Movie] {
        guard !ids.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { cont in
            AMCAPIClient.shared.fetchMoviesByIds(ids: ids) { result in
                switch result {
                case .success(let resp): cont.resume(returning: resp._embedded.movies)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }
    }

    // MARK: - Classification

    /// Combine Movie + Aggregate data into UI models
    func classify(
        movies: [Movie],
        aggregates: [LimitedRunAggregate]
    ) -> [LimitedMovie] {
        let aggById = Dictionary(
            uniqueKeysWithValues: aggregates.map { ($0.movieId, $0) }
        )
        let now = Date()

        return movies.compactMap { movie in
            guard let agg = aggById[movie.id] else { return nil }

            let isLive    = movie.attributes?.contains { $0.code.lowercased().contains("live") } ?? false
            let isSensory = movie.attributes?.contains { $0.code.lowercased().contains("sensory") } ?? false

            let daysSinceRelease: Int? = {
                guard
                    let rdStr = movie.releaseDateUtc,
                    let rd    = isoFormatter.date(from: rdStr)
                else { return nil }
                return Calendar.current.dateComponents([.day], from: rd, to: now).day
            }()

            let type: ReleaseType
            if isLive {
                type = .live
            } else if isSensory {
                type = .sensoryFriendly
            } else if let age = daysSinceRelease, age <= 1 && agg.showtimeCount <= threshold {
                type = .specialEvent
            } else if let age = daysSinceRelease, age > threshold && agg.showtimeCount <= threshold {
                type = .leavingSoon
            } else if let age = daysSinceRelease, age <= threshold && agg.showtimeCount < threshold {
                type = .trueLimitedRun
            } else {
                return nil
            }

            let posterUrl = movie.media?.posterDynamic180X74
                         ?? movie.media?.posterDynamic
                         ?? ""

            let aList = movie.availableForAList ?? false

            return LimitedMovie(
                id:                movie.id,
                name:              movie.name,
                showtimeCount:     agg.showtimeCount,
                nextShowing:       agg.nextShowing,
                nextShowingUrl:    agg.purchaseUrl,
                posterUrl:         posterUrl,
                limitedRun:        (type == .trueLimitedRun),
                theatreIds:        agg.theatreIds,
                availableForAList: aList,
                releaseType:       type
            )
        }
        .sorted {
            ($0.nextShowing ?? .distantFuture) < ($1.nextShowing ?? .distantFuture)
        }
    }

    // MARK: - One-Stop Fetch

    /// Fetch → TimeZones → Aggregate → Classify in one call
    func fetchLimitedMovies(
        for theatreIds: [Int]
    ) async throws -> [LimitedMovie] {
        // 1) Parallel showtime fetch
        let tagged      = try await fetchShowtimes(for: theatreIds)
        // 2) Fetch time zones
        let zones       = try await fetchTimeZones(for: theatreIds)
        // 3) Aggregate with correct parsing
        let aggregates  = aggregateShowtimes(tagged, timeZones: zones)
        // 4) Fetch movie details
        let movies      = try await fetchMovies(ids: aggregates.map { $0.movieId })
        // 5) Classify
        return classify(movies: movies, aggregates: aggregates)
    }
}
