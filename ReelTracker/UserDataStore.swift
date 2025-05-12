//
//  UserDataStore.swift
//  ReelTracker
//
//  Created on 2025-05-12.
//  Centralized store for all per-user state: hidden movies, watchlist, seen history, future expansions.
//

import Foundation
import Combine

/// A single source of truth for user preferences and history.
/// Holds sets of movie IDs for various lists, persists via UserDefaults,
/// and publishes changes so SwiftUI views can react.
final class UserDataStore: ObservableObject {
    
    // MARK: – UserDefaults keys
    private enum Keys {
        static let hiddenMovies    = "hiddenMovieIDs"
        static let watchlistMovies = "watchlistMovieIDs"
        static let seenMovies      = "seenMovieIDs"
        // add new keys here as you add new features
    }
    
    // MARK: – Published properties
    
    /// IDs of movies the user has hidden
    @Published private(set) var hiddenMovieIDs: Set<Int>
    
    /// IDs of movies the user has added to their watchlist
    @Published private(set) var watchlistMovieIDs: Set<Int>
    
    /// IDs of movies the user has marked as seen
    @Published private(set) var seenMovieIDs: Set<Int>
    
    // MARK: – Singleton
    
    /// Shared instance for easy injection via @EnvironmentObject
    static let shared = UserDataStore()
    
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: – Initialization
    
    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        
        // Load saved arrays (or default to empty) and wrap in Sets
        let hidden = defaults.array(forKey: Keys.hiddenMovies) as? [Int] ?? []
        let watch  = defaults.array(forKey: Keys.watchlistMovies) as? [Int] ?? []
        let seen   = defaults.array(forKey: Keys.seenMovies) as? [Int] ?? []
        
        self.hiddenMovieIDs    = Set(hidden)
        self.watchlistMovieIDs = Set(watch)
        self.seenMovieIDs      = Set(seen)
        
        // Persist whenever these Sets change
        $hiddenMovieIDs
            .sink { [weak self] set in
                self?.defaults.set(Array(set), forKey: Keys.hiddenMovies)
            }
            .store(in: &cancellables)
        
        $watchlistMovieIDs
            .sink { [weak self] set in
                self?.defaults.set(Array(set), forKey: Keys.watchlistMovies)
            }
            .store(in: &cancellables)
        
        $seenMovieIDs
            .sink { [weak self] set in
                self?.defaults.set(Array(set), forKey: Keys.seenMovies)
            }
            .store(in: &cancellables)
    }
    
    // MARK: – Public API
    
    /// MARK: Hidden Movies
    
    /// Hide a movie (removes it from visible lists)
    func hide(movie id: Int) {
        hiddenMovieIDs.insert(id)
    }
    
    /// Unhide a movie
    func unhide(movie id: Int) {
        hiddenMovieIDs.remove(id)
    }
    
    /// Check whether a movie is hidden
    func isHidden(movie id: Int) -> Bool {
        hiddenMovieIDs.contains(id)
    }
    
    /// MARK: Watchlist
    
    /// Add a movie to the watchlist
    func addToWatchlist(movie id: Int) {
        watchlistMovieIDs.insert(id)
    }
    
    /// Remove a movie from the watchlist
    func removeFromWatchlist(movie id: Int) {
        watchlistMovieIDs.remove(id)
    }
    
    /// Check whether a movie is in the watchlist
    func isInWatchlist(movie id: Int) -> Bool {
        watchlistMovieIDs.contains(id)
    }
    
    /// MARK: Seen History
    
    /// Mark a movie as seen
    func markSeen(movie id: Int) {
        seenMovieIDs.insert(id)
    }
    
    /// Unmark a movie as seen
    func unmarkSeen(movie id: Int) {
        seenMovieIDs.remove(id)
    }
    
    /// Check whether a movie is marked as seen
    func isSeen(movie id: Int) -> Bool {
        seenMovieIDs.contains(id)
    }
    
    // ── Future expansions ──────────────────────────────────────────────────────────
    // You can add @Published sets for ratings, notes, favorites, etc., plus
    // corresponding Keys and public methods, all in this one file.
    // ───────────────────────────────────────────────────────────────────────────────
}
