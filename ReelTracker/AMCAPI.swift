//
//  AMCAPI.swift
//  ReelTracker
//
//  Updated on 5/9/25 to include thumbnail URL decoding
//
import Foundation

// MARK: - Errors
public enum APIError: Error {
    case network(Error)
    case decoding(Error)
    case badResponse(statusCode: Int)
    case unknown
}

// MARK: - Domain Models
public struct Attribute: Codable {
    public let code: String
    public let name: String
    public let description: String?
}

public struct MediaContainer: Codable {
    public let posterDynamic: String?
    public let heroDesktopDynamic: String?
    public let trailerTeaserDynamic: String?
    /// Small thumbnail variant for list display
    public let posterDynamic180X74: String?

    enum CodingKeys: String, CodingKey {
        case posterDynamic
        case heroDesktopDynamic
        case trailerTeaserDynamic
        case posterDynamic180X74 = "posterDynamic180X74"
    }
}

public struct Movie: Identifiable, Codable {
    public var id: Int
    public var name: String
    public var slug: String?
    public var synopsis: String?
    public var runTime: Int?
    public var mpaaRating: String?
    public var releaseDateUtc: String?
    public var attributes: [Attribute]?
    public var media: MediaContainer?
}

public struct Showtime: Identifiable, Codable {
    public let id: Int
    public let theatreId: Int
    public let movieId: Int
    public let showDateTimeUtc: String
    public let showDateTimeLocal: String
    public let purchaseUrl: String
}

public struct Location: Codable {
    public let latitude: Double?
    public let longitude: Double?
    public let postalCode: String?
}

public struct Theatre: Identifiable, Codable {
    public let id: Int
    public let name: String
    public let timeZone: String?
    public let location: Location?
}

// MARK: - Pagination & Embedded Responses
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
}
public struct EmbeddedShowtimes: Codable { public let showtimes: [Showtime] }

public struct TheatresResponse: Codable {
    public let pageSize: Int
    public let pageNumber: Int
    public let _embedded: EmbeddedTheatres
    public let _links: Links?
}
public struct EmbeddedTheatres: Codable { public let theatres: [Theatre] }

// MARK: - AMC API Client
public class AMCAPIClient {
    public static let shared = AMCAPIClient()
    private let apiKey = "ABE142C9-AC7A-4947-94A3-5094CC0FBDBF"
    private let baseURL = URL(string: "https://api.amctheatres.com/v2")!
    private let jsonDecoder: JSONDecoder

    private init() {
        jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    private func request<T: Decodable>(_ url: URL,
                                       completion: @escaping (Result<T, APIError>) -> Void) {
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-AMC-Vendor-Key")
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(.network(error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.unknown))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(.badResponse(statusCode: http.statusCode)))
                return
            }
            guard let data = data else {
                completion(.failure(.unknown))
                return
            }
            do {
                let decoded = try self.jsonDecoder.decode(T.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(.decoding(error)))
            }
        }.resume()
    }

    // MARK: - Movies

    public func fetchMovies(startDate: String,
                            endDate: String,
                            pageNumber: Int = 1,
                            pageSize: Int = 20,
                            completion: @escaping (Result<MoviesResponse, APIError>) -> Void) {
        let url = baseURL.appendingPathComponent("movies")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "start-date", value: startDate),
            URLQueryItem(name: "end-date", value: endDate),
            URLQueryItem(name: "page-number", value: "\(pageNumber)"),
            URLQueryItem(name: "page-size", value: "\(pageSize)")
        ]
        request(comps.url!, completion: completion)
    }

    public func fetchAdvanceTicketMovies(startDate: String,
                                         endDate: String,
                                         pageNumber: Int = 1,
                                         pageSize: Int = 20,
                                         completion: @escaping (Result<MoviesResponse, APIError>) -> Void) {
        let url = baseURL.appendingPathComponent("movies/views/advance")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "start-date", value: startDate),
            URLQueryItem(name: "end-date", value: endDate),
            URLQueryItem(name: "page-number", value: "\(pageNumber)"),
            URLQueryItem(name: "page-size", value: "\(pageSize)")
        ]
        request(comps.url!, completion: completion)
    }

    public func fetchMoviesByIds(ids: [Int],
                                 pageNumber: Int = 1,
                                 pageSize: Int = 20,
                                 completion: @escaping (Result<MoviesResponse, APIError>) -> Void) {
        let url = baseURL.appendingPathComponent("movies")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "page-number", value: "\(pageNumber)"),
            URLQueryItem(name: "page-size", value: "\(pageSize)")
        ]
        request(comps.url!, completion: completion)
    }

    // MARK: - Theatres

    public func fetchTheatres(pageNumber: Int = 1,
                              pageSize: Int = 20,
                              postalCode: String? = nil,
                              completion: @escaping (Result<TheatresResponse, APIError>) -> Void) {
        let url = baseURL.appendingPathComponent("theatres")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "page-number", value: "\(pageNumber)"),
            URLQueryItem(name: "page-size", value: "\(pageSize)")
        ]
        if let postal = postalCode, postal.count == 5 {
            items.append(URLQueryItem(name: "postal-code", value: postal))
        }
        comps.queryItems = items
        request(comps.url!, completion: completion)
    }

    public func fetchTheatreDetails(id: Int,
                                    completion: @escaping (Result<Theatre, APIError>) -> Void) {
        let url = baseURL.appendingPathComponent("theatres/\(id)")
        request(url, completion: completion)
    }

    // MARK: - Showtimes

    public func fetchShowtimes(theatreId: Int,
                               movieId: Int? = nil,
                               date: String? = nil,
                               pageNumber: Int = 1,
                               pageSize: Int = 20,
                               completion: @escaping (Result<ShowtimesResponse, APIError>) -> Void) {
        var path = "theatres/\(theatreId)/showtimes"
        if let date = date {
            path += "/\(date)"
        }
        let url = baseURL.appendingPathComponent(path)
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "page-number", value: "\(pageNumber)"),
            URLQueryItem(name: "page-size", value: "\(pageSize)")
        ]
        if let mid = movieId {
            items.append(URLQueryItem(name: "movie-id", value: "\(mid)"))
        }
        comps.queryItems = items
        request(comps.url!, completion: completion)
    }
}
