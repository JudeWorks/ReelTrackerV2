//
//  AMCMovieFetchService.swift
//  ReelTracker
//
//  Created on 5/9/25
//  Updated on 5/16/25 to fix concurrency, unused variables, and A-List flag
//  Updated on 5/20/25 to support theatre-specific time-zone parsing
//  Updated on 5/22/25 to use MovieClassifier for all classification logic
//

import Foundation

actor AMCMovieFetchService {
    /// Shared singleton for easy access
    static let shared = AMCMovieFetchService()

    private let classifier = MovieClassifier()

    init() {}

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

    // MARK: - Movie Details

    /// Fetch all movies playing in date range
    private func fetchAllMovies(startDate: String, endDate: String) async throws -> [Movie] {
        try await withCheckedThrowingContinuation { cont in
            AMCAPIClient.shared.fetchMovies(
                startDate: startDate,
                endDate: endDate,
                pageNumber: 1,
                pageSize: 1000
            ) { result in
                switch result {
                case .success(let resp): cont.resume(returning: resp._embedded.movies)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }
    }

    /// Fetch advance ticket movies
    private func fetchAdvanceMovies(startDate: String, endDate: String) async throws -> [Movie] {
        try await withCheckedThrowingContinuation { cont in
            AMCAPIClient.shared.fetchAdvanceTicketMovies(
                startDate: startDate,
                endDate: endDate,
                pageNumber: 1,
                pageSize: 1000
            ) { result in
                switch result {
                case .success(let resp): cont.resume(returning: resp._embedded.movies)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }
    }

    // MARK: - Date Helpers
    
    private func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - One-Stop Fetch

    /// Fetch → TimeZones → Classify in one call
    func fetchLimitedMovies(
        for theatreIds: [Int]
    ) async throws -> [LimitedMovie] {
        // 1) Calculate date range (past 30 days to future 50 days)
        let today = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -30, to: today) ?? today
        let endDate = Calendar.current.date(byAdding: .day, value: 50, to: today) ?? today
        let startDateStr = dateString(from: startDate)
        let endDateStr = dateString(from: endDate)
        
        // 2) Fetch all data in parallel
        async let tagged = fetchShowtimes(for: theatreIds)
        async let zones = fetchTimeZones(for: theatreIds)
        async let regularMovies = fetchAllMovies(startDate: startDateStr, endDate: endDateStr)
        async let advanceMovies = fetchAdvanceMovies(startDate: startDateStr, endDate: endDateStr)
        
        // 3) Wait for all data
        let (showtimes, theatreZones, regular, advance) = try await (tagged, zones, regularMovies, advanceMovies)
        
        // 4) Combine all movies (removing duplicates)
        var allMovies = regular
        let regularIds = Set(regular.map { $0.id })
        for movie in advance where !regularIds.contains(movie.id) {
            allMovies.append(movie)
        }
        
        // 5) Use classifier to process everything
        return classifier.classifyMovies(
            from: showtimes,
            movies: allMovies,
            theatreTimeZones: theatreZones
        )
    }
}
