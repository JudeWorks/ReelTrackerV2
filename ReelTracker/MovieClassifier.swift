//
//  MovieClassifier.swift
//  ReelTracker
//
//  Created on 2025-05-22
//  Centralized movie classification logic
//

import Foundation

// MARK: - Types

/// Types of release classifications
enum ReleaseType: String, CaseIterable {
    case live             = "Live"
    case sensoryFriendly  = "Sensory-Friendly"
    case leavingSoon      = "Leaving Soon"
    case limitedRelease   = "Limited Release"
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

// MARK: - Classifier

/// Handles all movie classification logic
final class MovieClassifier {
    
    // MARK: - Configuration
    
    private let threshold = 10
    private let limitedReleaseMaxTotal = 25
    private let leavingSoonMaxTotal = 50
    
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    private let isoFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    
    // MARK: - Public Methods
    
    /// Classify movies based on showtimes and metadata
    func classifyMovies(
        from taggedShowtimes: [(theatreId: Int, showtime: Showtime)],
        movies: [Movie],
        theatreTimeZones: [Int: TimeZone]
    ) -> [LimitedMovie] {
        let now = Date()
        
        // Group showtimes by movie
        let showtimesByMovie = Dictionary(
            grouping: taggedShowtimes,
            by: { $0.showtime.movieId }
        )
        
        // Process each movie (not just those with showtimes)
        return movies.compactMap { movie in
            let entries = showtimesByMovie[movie.id] ?? []
            
            // If no showtimes at selected theaters, skip
            guard !entries.isEmpty else { return nil }
            
            // Calculate theatre-specific counts (only future showings)
            let futureCounts = calculateFutureTheatreCounts(entries: entries, theatreTimeZones: theatreTimeZones, now: now)
            let minCount = futureCounts.values.min() ?? 0
            let maxCount = futureCounts.values.max() ?? 0
            let totalCount = futureCounts.values.reduce(0, +)
            
            // Skip movies with no future showings
            guard totalCount > 0 else { return nil }
            
            // Find next showing
            let (nextDate, nextUrl) = findNextShowing(
                entries: entries,
                theatreTimeZones: theatreTimeZones,
                now: now
            )
            
            // Get theatre IDs
            let theatreIds = Set(entries.map { $0.theatreId })
            
            // Determine release type
            let releaseType = determineReleaseType(
                movie: movie,
                minCount: minCount,
                maxCount: maxCount,
                totalCount: totalCount,
                now: now
            )
            
            // Skip if no valid release type
            guard let type = releaseType else { return nil }
            
            // Create limited movie
            return LimitedMovie(
                id: movie.id,
                name: movie.name,
                showtimeCount: totalCount,  // This should be the total future showings
                nextShowing: nextDate,
                nextShowingUrl: nextUrl,
                posterUrl: extractPosterUrl(from: movie),
                limitedRun: minCount <= threshold,
                theatreIds: theatreIds,
                availableForAList: movie.availableForAList ?? false,
                releaseType: type
            )
        }
        .sorted { ($0.nextShowing ?? .distantFuture) < ($1.nextShowing ?? .distantFuture) }
    }
    
    // MARK: - Private Methods
    
    private func calculateTheatreCounts(
        entries: [(theatreId: Int, showtime: Showtime)]
    ) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for entry in entries {
            counts[entry.theatreId, default: 0] += 1
        }
        return counts
    }
    
    private func calculateFutureTheatreCounts(
        entries: [(theatreId: Int, showtime: Showtime)],
        theatreTimeZones: [Int: TimeZone],
        now: Date
    ) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        
        for entry in entries {
            // Use UTC time for reliable comparison
            if let date = isoFormatter.date(from: entry.showtime.showDateTimeUtc) ??
                          isoFormatterBasic.date(from: entry.showtime.showDateTimeUtc),
               date >= now {
                counts[entry.theatreId, default: 0] += 1
            }
        }
        
        return counts
    }
    
    private func findNextShowing(
        entries: [(theatreId: Int, showtime: Showtime)],
        theatreTimeZones: [Int: TimeZone],
        now: Date
    ) -> (date: Date?, url: String) {
        var nextDate: Date?
        var nextUrl = ""
        
        for entry in entries {
            // Use UTC time for reliable comparison
            if let date = isoFormatter.date(from: entry.showtime.showDateTimeUtc) ??
                          isoFormatterBasic.date(from: entry.showtime.showDateTimeUtc),
               date >= now {
                if let existing = nextDate {
                    if date < existing {
                        nextDate = date
                        nextUrl = entry.showtime.purchaseUrl
                    }
                } else {
                    nextDate = date
                    nextUrl = entry.showtime.purchaseUrl
                }
            }
        }
        
        return (nextDate, nextUrl)
    }
    
    private func determineReleaseType(
        movie: Movie,
        minCount: Int,
        maxCount: Int,
        totalCount: Int,
        now: Date
    ) -> ReleaseType? {
        // Check special attributes
        let isLive = movie.attributes?.contains {
            $0.code.lowercased().contains("live")
        } ?? false
        
        let isSensory = movie.attributes?.contains {
            $0.code.lowercased().contains("sensory")
        } ?? false
        
        // Calculate days since release
        let daysSinceRelease: Int? = {
            guard let rdStr = movie.releaseDateUtc else { return nil }
            
            // Try with fractional seconds first
            var rd = isoFormatter.date(from: rdStr)
            
            // If that fails, try without fractional seconds
            if rd == nil {
                rd = isoFormatterBasic.date(from: rdStr)
            }
            
            guard let releaseDate = rd else { return nil }
            
            return Calendar.current.dateComponents([.day], from: releaseDate, to: now).day
        }()
        
        // Determine type
        if isLive {
            return .live
        } else if isSensory {
            return .sensoryFriendly
        } else if let age = daysSinceRelease {
            // Leaving Soon: older movies (>10 days) with less than 25 total showings
            if age > threshold && totalCount < leavingSoonMaxTotal {
                return .leavingSoon
            }
            // Limited Release: recent movies (≤10 days) with limited showings AND total ≤25
            else if age <= threshold && minCount <= threshold && totalCount <= limitedReleaseMaxTotal {
                return .limitedRelease
            }
        } else {
            // No release date - check if it qualifies as limited release based on showings alone
            if minCount <= threshold && totalCount <= limitedReleaseMaxTotal {
                return .limitedRelease
            }
        }
        
        return nil
    }
    
    private func extractPosterUrl(from movie: Movie) -> String {
        if let thumb = movie.media?.posterDynamic180X74, !thumb.isEmpty {
            return thumb
        }
        return movie.media?.posterDynamic ?? ""
    }
}
