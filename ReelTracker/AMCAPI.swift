//
//  AMCAPI.swift
//  ReelTracker
//
//  Updated on 2025-05-15 to include A-List eligibility, trailer support, and theatre amenities
//

import Foundation

// MARK: - Errors

public enum APIError: Error {
    case network(Error)
    case decoding(Error)
    case badResponse(statusCode: Int)
    case invalidURL
    case unknown
}

// MARK: - Domain Models

/// Attribute represents special formats or features for movies/theatres
public struct Attribute: Codable {
    public let code: String
    public let name: String
    public let description: String?
}

/// Media assets available for a movie
public struct MediaContainer: Codable {
    public let posterDynamic: String?
    public let heroDesktopDynamic: String?
    public let trailerTeaserDynamic: String? // URL for the movie trailer teaser
    public let posterDynamic180X74: String?
}

/// Movie model representing a film
public struct Movie: Identifiable, Codable {
    public let id: Int
    public let name: String
    public let slug: String?
    public let synopsis: String?
    public let runTime: Int? // Duration in minutes
    public let mpaaRating: String? // e.g. "PG-13"
    public let releaseDateUtc: String?
    public let attributes: [Attribute]? // e.g. formats like "3D", "IMAX"
    public let media: MediaContainer?
    public let availableForAList: Bool? // AMC A‑List eligibility flag
}

/// Showtime information for a movie at a theatre
public struct Showtime: Identifiable, Codable {
    public let id: Int
    public let theatreId: Int
    public let movieId: Int
    public let showDateTimeUtc: String
    public let showDateTimeLocal: String
    public let purchaseUrl: String
}

/// Geographic location data
public struct Location: Codable {
    public let latitude: Double?
    public let longitude: Double?
    public let postalCode: String?
}

/// Theatre model representing an AMC location
public struct Theatre: Identifiable, Codable {
    public let id: Int
    public let name: String
    public let timeZone: String?
    public let location: Location?
    public let attributes: [Attribute]? // Theatre amenities (e.g. "Dolby Cinema", "Recliners")
}

// MARK: - Pagination Wrappers

public struct Link: Codable { public let href: String }
public struct Links: Codable { public let next: Link?; public let previous: Link? }

public struct MoviesResponse: Codable {
    public let pageSize: Int
    public let pageNumber: Int
    public let count: Int
    public let _embedded: EmbeddedMovies
    public let _links: Links?
}
public struct EmbeddedMovies: Codable { public let movies: [Movie] }

public struct ShowtimesResponse: Codable {
    public let pageSize: Int
    public let pageNumber: Int
    public let count: Int
    public let _embedded: EmbeddedShowtimes
    public let _links: Links?
}
public struct EmbeddedShowtimes: Codable { public let showtimes: [Showtime] }

public struct TheatresResponse: Codable {
    public let pageSize: Int
    public let pageNumber: Int
    public let count: Int
    public let _embedded: EmbeddedTheatres
    public let _links: Links?
}
public struct EmbeddedTheatres: Codable { public let theatres: [Theatre] }

// MARK: - AMC API Client with Full Pagination

public class AMCAPIClient {
    public static let shared = AMCAPIClient()
    private let apiKey: String = "ABE142C9-AC7A-4947-94A3-5094CC0FBDBF"
    private let baseURL: URL
    private let jsonDecoder: JSONDecoder

    private init() {
        guard let url = URL(string: "https://api.amctheatres.com/v2") else {
            preconditionFailure("Invalid base URL for AMC API")
        }
        self.baseURL = url
        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    /// Basic request executor that injects the vendor key
    private func request<T: Decodable>(
        _ url: URL,
        completion: @escaping (Result<T, APIError>) -> Void
    ) {
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-AMC-Vendor-Key")

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(.network(error))); return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.unknown)); return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(.badResponse(statusCode: http.statusCode))); return
            }
            guard let data = data else {
                completion(.failure(.unknown)); return
            }
            do {
                let decoded = try self.jsonDecoder.decode(T.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(.decoding(error)))
            }
        }.resume()
    }

    // MARK: - Pagination Helper

    private func fetchAllPages<Response: Codable, Item>(
        initialURL: URL,
        extractItems: @escaping (Response) -> [Item],
        extractNextURL: @escaping (Response) -> URL?,
        combineMeta: @escaping (Response, [Item]) -> Response,
        completion: @escaping (Result<Response, APIError>) -> Void
    ) {
        var accumulated: [Item] = []

        func fetch(_ url: URL) {
            request(url) { (result: Result<Response, APIError>) in
                switch result {
                case .failure(let err):
                    completion(.failure(err))
                case .success(let resp):
                    let items = extractItems(resp)
                    accumulated.append(contentsOf: items)
                    if let next = extractNextURL(resp) {
                        fetch(next)
                    } else {
                        let combined = combineMeta(resp, accumulated)
                        completion(.success(combined))
                    }
                }
            }
        }

        fetch(initialURL)
    }

    // MARK: - Movies

    /// Fetch movies playing in a date range (all pages)
    public func fetchMovies(
        startDate: String,
        endDate: String,
        pageNumber: Int = 1,
        pageSize: Int = 20,
        completion: @escaping (Result<MoviesResponse, APIError>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("movies")
        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            completion(.failure(.invalidURL)); return
        }
        comps.queryItems = [
            .init(name: "start-date", value: startDate),
            .init(name: "end-date",   value: endDate),
            .init(name: "page-number", value: "\(pageNumber)"),
            .init(name: "page-size",   value: "\(pageSize)")
        ]
        guard let initialURL = comps.url else { completion(.failure(.invalidURL)); return }

        fetchAllPages(
            initialURL: initialURL,
            extractItems:   { $0._embedded.movies },
            extractNextURL: { $0._links?.next.flatMap { URL(string: $0.href) } },
            combineMeta:    { last, all in
                MoviesResponse(
                    pageSize:   last.pageSize,
                    pageNumber: 1,
                    count:      last.count,
                    _embedded:  EmbeddedMovies(movies: all),
                    _links:     nil
                )
            },
            completion: completion
        )
    }

    /// Fetch advance-ticket (pre-release) movies in a date range
    public func fetchAdvanceTicketMovies(
        startDate: String,
        endDate: String,
        pageNumber: Int = 1,
        pageSize: Int = 20,
        completion: @escaping (Result<MoviesResponse, APIError>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("movies/views/advance")
        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            completion(.failure(.invalidURL)); return
        }
        comps.queryItems = [
            .init(name: "start-date", value: startDate),
            .init(name: "end-date",   value: endDate),
            .init(name: "page-number", value: "\(pageNumber)"),
            .init(name: "page-size",   value: "\(pageSize)")
        ]
        guard let initialURL = comps.url else { completion(.failure(.invalidURL)); return }

        fetchAllPages(
            initialURL: initialURL,
            extractItems:   { $0._embedded.movies },
            extractNextURL: { $0._links?.next.flatMap { URL(string: $0.href) } },
            combineMeta:    { last, all in
                MoviesResponse(
                    pageSize:   last.pageSize,
                    pageNumber: 1,
                    count:      last.count,
                    _embedded:  EmbeddedMovies(movies: all),
                    _links:     nil
                )
            },
            completion: completion
        )
    }

    /// Fetch movies by a list of IDs
    public func fetchMoviesByIds(
        ids: [Int],
        pageNumber: Int = 1,
        pageSize: Int = 20,
        completion: @escaping (Result<MoviesResponse, APIError>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("movies")
        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            completion(.failure(.invalidURL)); return
        }
        comps.queryItems = [
            .init(name: "ids", value: ids.map(String.init).joined(separator: ",")),
            .init(name: "page-number", value: "\(pageNumber)"),
            .init(name: "page-size",   value: "\(pageSize)")
        ]
        guard let initialURL = comps.url else { completion(.failure(.invalidURL)); return }

        fetchAllPages(
            initialURL: initialURL,
            extractItems:   { $0._embedded.movies },
            extractNextURL: { $0._links?.next.flatMap { URL(string: $0.href) } },
            combineMeta:    { last, all in
                MoviesResponse(
                    pageSize:   last.pageSize,
                    pageNumber: 1,
                    count:      last.count,
                    _embedded:  EmbeddedMovies(movies: all),
                    _links:     nil
                )
            },
            completion: completion
        )
    }

    /// Fetch detailed info for a single movie by ID
    public func fetchMovieDetails(
        id: Int,
        completion: @escaping (Result<Movie, APIError>) -> Void
    ) {
        let url = baseURL.appendingPathComponent("movies/\(id)")
        request(url, completion: completion)
    }

    // MARK: - Theatres

    /// Fetch list of theatres (all pages), optional postal code filter
    public func fetchTheatres(
        pageNumber: Int = 1,
        pageSize: Int = 20,
        postalCode: String? = nil,
        completion: @escaping (Result<TheatresResponse, APIError>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("theatres")
        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            completion(.failure(.invalidURL)); return
        }
        var items: [URLQueryItem] = [
            .init(name: "page-number", value: "\(pageNumber)"),
            .init(name: "page-size",   value: "\(pageSize)")
        ]
        if let postal = postalCode {
            items.append(.init(name: "postal-code", value: postal))
        }
        comps.queryItems = items
        guard let initialURL = comps.url else { completion(.failure(.invalidURL)); return }

        fetchAllPages(
            initialURL: initialURL,
            extractItems:   { $0._embedded.theatres },
            extractNextURL: { $0._links?.next.flatMap { URL(string: $0.href) } },
            combineMeta:    { last, all in
                TheatresResponse(
                    pageSize:   last.pageSize,
                    pageNumber: 1,
                    count:      last.count,
                    _embedded:  EmbeddedTheatres(theatres: all),
                    _links:     nil
                )
            },
            completion: completion
        )
    }

    /// Fetch detailed info for a single theatre by ID
    public func fetchTheatreDetails(
        id: Int,
        completion: @escaping (Result<Theatre, APIError>) -> Void
    ) {
        let url = baseURL.appendingPathComponent("theatres/\(id)")
        request(url, completion: completion)
    }

    // MARK: - Showtimes

    /// Fetch showtimes for a theatre, optional movie filter and date
    public func fetchShowtimes(
        theatreId: Int,
        movieId: Int? = nil,
        date: String? = nil,
        pageNumber: Int = 1,
        pageSize: Int = 20,
        completion: @escaping (Result<ShowtimesResponse, APIError>) -> Void
    ) {
        var path = "theatres/\(theatreId)/showtimes"
        if let date = date {
            path += "/\(date)"
        }
        let endpoint = baseURL.appendingPathComponent(path)
        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            completion(.failure(.invalidURL)); return
        }
        var items: [URLQueryItem] = [
            .init(name: "page-number", value: "\(pageNumber)"),
            .init(name: "page-size",   value: "\(pageSize)")
        ]
        if let mid = movieId {
            items.append(.init(name: "movie-id", value: "\(mid)"))
        }
        comps.queryItems = items
        guard let finalURL = comps.url else { completion(.failure(.invalidURL)); return }

        fetchAllPages(
            initialURL: finalURL,
            extractItems:   { $0._embedded.showtimes },
            extractNextURL: { $0._links?.next.flatMap { URL(string: $0.href) } },
            combineMeta:    { last, all in
                ShowtimesResponse(
                    pageSize:   last.pageSize,
                    pageNumber: 1,
                    count:      last.count,
                    _embedded:  EmbeddedShowtimes(showtimes: all),
                    _links:     nil
                )
            },
            completion: completion
        )
    }
}
