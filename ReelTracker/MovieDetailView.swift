//
//  MovieDetailView.swift
//  ReelTracker
//
//  Created on 2025-05-19.
//  A more polished, modern detail screen for a single movie,
//  now always listing every selected theatre—even those with no showtimes.
//

import SwiftUI
import AVKit

struct MovieDetailView: View {
    let movieId: Int

    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var userData: UserDataStore
    @Environment(\.openURL) private var openURL

    @StateObject private var viewModel = MovieDetailViewModel()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = .current
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // MARK: Hero Poster with Title Overlay
                if let urlString = viewModel.movie?.media?.heroDesktopDynamic ?? viewModel.movie?.media?.posterDynamic,
                   let url = URL(string: urlString) {
                    ZStack(alignment: .bottom) {
                        CachedAsyncImage(
                            urlString: url.absoluteString,
                            width: UIScreen.main.bounds.width,
                            height: 240
                        )
                        .clipped()

                        LinearGradient(
                            gradient: Gradient(colors: [.clear, .black.opacity(0.7)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 100)

                        VStack(spacing: 4) {
                            Text(viewModel.movie?.name ?? "")
                                .font(.title)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)

                            if let rd = viewModel.movie?.releaseDateUtc,
                               let date = Self.isoFormatter.date(from: rd) {
                                Text(Self.displayFormatter.string(from: date))
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .frame(maxWidth: .infinity)
                    .shadow(radius: 8)
                }

                // MARK: At-a-Glance Metadata
                HStack(spacing: 16) {
                    if let rating = viewModel.movie?.mpaaRating {
                        Text(rating)
                            .font(.subheadline.bold())
                            .padding(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke())
                    }
                    if let runtime = viewModel.movie?.runTime {
                        Label("\(runtime) min", systemImage: "clock")
                            .font(.subheadline)
                    }
                    if viewModel.movie?.availableForAList == true {
                        Text("A-List")
                            .font(.subheadline.bold())
                            .padding(6)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)

                // MARK: Synopsis Card
                if let synopsis = viewModel.movie?.synopsis {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Synopsis")
                            .font(.headline)
                        Text(synopsis)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                    .padding(.horizontal)
                }

                // MARK: Trailer Teaser
                if let trailerURL = viewModel.movie?.media?.trailerTeaserDynamic,
                   let url = URL(string: trailerURL) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trailer")
                            .font(.headline)
                        VideoPlayer(player: AVPlayer(url: url))
                            .aspectRatio(16/9, contentMode: .fit)
                            .cornerRadius(12)
                            .shadow(radius: 4)
                    }
                    .padding(.horizontal)
                }

                // MARK: Showtimes by Theatre
                VStack(alignment: .leading, spacing: 12) {
                    Text("Showtimes")
                        .font(.headline)
                    ForEach(settings.selectedTheatres) { theatre in
                        // Always list each theatre, even if times is empty
                        let times = viewModel.showtimesByTheatre[theatre.id] ?? []
                        VStack(alignment: .leading, spacing: 6) {
                            Text(theatre.name)
                                .font(.subheadline.bold())
                            if times.isEmpty {
                                Text("No showtimes")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(times, id: \.id) { st in
                                            if let dt = Self.localFormatter.date(from: st.showDateTimeLocal) {
                                                Button {
                                                    openURL(URL(string: st.purchaseUrl)!)
                                                } label: {
                                                    Text(Self.displayFormatter.string(from: dt))
                                                        .font(.caption)
                                                        .padding(.vertical, 6)
                                                        .padding(.horizontal, 12)
                                                        .background(Color.accentColor.opacity(0.1))
                                                        .cornerRadius(8)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.03), radius: 3, x: 0, y: 2)
                    }
                }
                .padding(.horizontal)

                // MARK: Action Buttons
                HStack(spacing: 20) {
                    Button {
                        if userData.isInWatchlist(movie: movieId) {
                            userData.removeFromWatchlist(movie: movieId)
                        } else {
                            userData.addToWatchlist(movie: movieId)
                        }
                    } label: {
                        Label(
                            userData.isInWatchlist(movie: movieId) ? "In Watchlist" : "Add to Watchlist",
                            systemImage: userData.isInWatchlist(movie: movieId) ? "bookmark.fill" : "bookmark"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        if userData.isSeen(movie: movieId) {
                            userData.unmarkSeen(movie: movieId)
                        } else {
                            userData.markSeen(movie: movieId)
                        }
                    } label: {
                        Label(
                            userData.isSeen(movie: movieId) ? "Seen" : "Mark as Seen",
                            systemImage: userData.isSeen(movie: movieId) ? "eye.fill" : "eye"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.top, 12)

            } // VStack
            .padding(.vertical)
        } // ScrollView
        .navigationTitle(viewModel.movie?.name ?? "Details")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
        .onAppear {
            viewModel.load(
                movieId: movieId,
                theatreIds: Array(settings.selectedIds)
            )
        }
    }
}

// MARK: – ViewModel

final class MovieDetailViewModel: ObservableObject {
    @Published var movie: Movie?
    @Published var showtimesByTheatre: [Int: [Showtime]] = [:]
    @Published var isLoading = false

    private let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    func load(movieId: Int, theatreIds: [Int]) {
        isLoading = true
        showtimesByTheatre = [:]

        // 1) Movie details
        AMCAPIClient.shared.fetchMovieDetails(id: movieId) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let m) = result {
                    self?.movie = m
                }
            }
        }

        // 2) Showtimes per theatre
        let group = DispatchGroup()
        var grouped: [Int: [Showtime]] = [:]

        for tid in theatreIds {
            group.enter()
            AMCAPIClient.shared.fetchShowtimes(
                theatreId: tid,
                movieId: movieId,
                date: nil,
                pageNumber: 1,
                pageSize: 1000
            ) { [weak self] result in
                if case .success(let resp) = result,
                   let self = self {
                    let valid = resp._embedded.showtimes
                    DispatchQueue.main.async {
                        // Sort and assign even if empty
                        grouped[tid] = valid.sorted {
                            guard
                                let d1 = self.localFormatter.date(from: $0.showDateTimeLocal),
                                let d2 = self.localFormatter.date(from: $1.showDateTimeLocal)
                            else { return false }
                            return d1 < d2
                        }
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.showtimesByTheatre = grouped
            self.isLoading = false
        }
    }
}

// MARK: – Preview

struct MovieDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            MovieDetailView(movieId: 123)
                .environmentObject(SettingsViewModel())
                .environmentObject(UserDataStore.shared)
        }
    }
}
