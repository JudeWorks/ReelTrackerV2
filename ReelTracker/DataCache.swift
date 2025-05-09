import Foundation
import CryptoKit

/// A generic disk-based cache for raw Data, with automatic expiration.
public final class DataCache {
    /// Shared singleton instance
    public static let shared = DataCache()

    /// Directory on disk where cached files are stored
    private let cacheDirectory: URL
    private let fileManager: FileManager
    private let ioQueue: DispatchQueue
    private let expirationInterval: TimeInterval

    /// Initialize with optional custom directory name and expiration interval
    /// - Parameters:
    ///   - cacheDirectoryName: Subfolder under the app's Caches directory
    ///   - expirationInterval: TimeInterval after which cached items expire (default: 90 days)
    public init(cacheDirectoryName: String = "DataCache",
                expirationInterval: TimeInterval = 60 * 60 * 24 * 90) {
        self.fileManager = .default
        self.ioQueue = DispatchQueue(label: "com.reeltracker.DataCache.ioQueue")
        self.expirationInterval = expirationInterval

        // Determine base Caches directory
        let baseURL: URL
        do {
            baseURL = try fileManager.url(for: .cachesDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true)
        } catch {
            fatalError("DataCache: Could not locate caches directory: \(error)")
        }
        self.cacheDirectory = baseURL.appendingPathComponent(cacheDirectoryName, isDirectory: true)
        createCacheDirectory()
    }

    /// Create the cache folder if it doesn't exist
    private func createCacheDirectory() {
        ioQueue.async {
            do {
                try self.fileManager.createDirectory(at: self.cacheDirectory,
                                                     withIntermediateDirectories: true,
                                                     attributes: nil)
            } catch {
                print("DataCache: Failed to create cache directory: \(error)")
            }
        }
    }

    /// Compute file URL for a given key by hashing it
    private func cacheFileURL(forKey key: String) -> URL {
        let filename = key.sha256()
        return cacheDirectory.appendingPathComponent(filename)
    }

    /// Retrieve data for a given key, returning nil if not found or expired
    public func data(forKey key: String) -> Data? {
        let fileURL = cacheFileURL(forKey: key)
        var result: Data?
        ioQueue.sync {
            guard self.fileManager.fileExists(atPath: fileURL.path) else { return }
            do {
                let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                if let date = values.contentModificationDate,
                   Date().timeIntervalSince(date) < self.expirationInterval {
                    result = try Data(contentsOf: fileURL)
                } else {
                    // Expired
                    try self.fileManager.removeItem(at: fileURL)
                }
            } catch {
                print("DataCache: Error loading data for key \(key): \(error)")
            }
        }
        return result
    }

    /// Store data disk-backed for a given key
    public func store(_ data: Data, forKey key: String) {
        let fileURL = cacheFileURL(forKey: key)
        ioQueue.async {
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("DataCache: Failed to write data for key \(key): \(error)")
            }
        }
    }

    /// Remove all entries older than the expiration interval
    public func purgeExpiredEntries() {
        ioQueue.async {
            do {
                let fileURLs = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory,
                                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                                        options: .skipsHiddenFiles)
                let now = Date()
                for url in fileURLs {
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                    if let date = values.contentModificationDate,
                       now.timeIntervalSince(date) > self.expirationInterval {
                        try self.fileManager.removeItem(at: url)
                    }
                }
            } catch {
                print("DataCache: Failed to purge expired entries: \(error)")
            }
        }
    }

    /// Completely clear the cache directory
    public func clearAll() {
        ioQueue.async {
            do {
                try self.fileManager.removeItem(at: self.cacheDirectory)
                try self.fileManager.createDirectory(at: self.cacheDirectory,
                                                     withIntermediateDirectories: true,
                                                     attributes: nil)
            } catch {
                print("DataCache: Failed to clear cache: \(error)")
            }
        }
    }
}

// MARK: - String SHA256 Extension
private extension String {
    /// Compute SHA256 hash of this string
    func sha256() -> String {
        let data = Data(self.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
