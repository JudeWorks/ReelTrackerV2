import Foundation
import CryptoKit

/// A disk-backed and in-memory fallback cache with automatic expiration and size-based eviction.
public final class DataCache {
    public static let shared = DataCache()

    private let fileManager: FileManager
    private let ioQueue: DispatchQueue
    private let memoryQueue: DispatchQueue
    private let expirationInterval: TimeInterval
    private let maxDiskCacheSize: UInt64
    private let cacheDirectory: URL?
    private let isDiskCacheEnabled: Bool

    /// In-memory fallback storage
    private var memoryCache: [String: MemoryCacheEntry] = [:]

    /// Wrapper for in-memory entries
    private class MemoryCacheEntry {
        let data: Data
        let date: Date
        init(data: Data, date: Date = Date()) {
            self.data = data
            self.date = date
        }
    }

    /// Initialize with optional custom directory name, expiration interval, and disk size limit
    public init(cacheDirectoryName: String = "DataCache",
                expirationInterval: TimeInterval = 60 * 60 * 24 * 90,
                maxDiskCacheSize: UInt64 = 1024 * 1024 * 100) {
        self.fileManager = .default
        self.ioQueue = DispatchQueue(label: "com.reeltracker.DataCache.ioQueue")
        self.memoryQueue = DispatchQueue(label: "com.reeltracker.DataCache.memoryQueue")
        self.expirationInterval = expirationInterval
        self.maxDiskCacheSize = maxDiskCacheSize

        // Attempt to locate the app’s Caches directory
        var diskEnabled = true
        var baseURL: URL?
        do {
            baseURL = try fileManager.url(for: .cachesDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true)
        } catch {
            print("DataCache: Could not locate caches directory, falling back to in-memory cache: \(error)")
            diskEnabled = false
        }
        self.isDiskCacheEnabled = diskEnabled

        if let base = baseURL, diskEnabled {
            let dir = base.appendingPathComponent(cacheDirectoryName, isDirectory: true)
            self.cacheDirectory = dir
            createCacheDirectory()
        } else {
            self.cacheDirectory = nil
        }
    }

    /// Create the cache folder if it doesn't exist
    private func createCacheDirectory() {
        guard let dir = cacheDirectory else { return }
        ioQueue.async {
            do {
                try self.fileManager.createDirectory(at: dir,
                                                     withIntermediateDirectories: true,
                                                     attributes: nil)
            } catch {
                print("DataCache: Failed to create cache directory: \(error)")
            }
        }
    }

    /// Compute file URL for a given key by hashing it
    private func cacheFileURL(forKey key: String) -> URL? {
        guard isDiskCacheEnabled, let dir = cacheDirectory else { return nil }
        let filename = key.sha256()
        return dir.appendingPathComponent(filename)
    }

    /// Retrieve data for a given key, returning nil if not found or expired
    public func data(forKey key: String) -> Data? {
        // Try disk first
        if let fileURL = cacheFileURL(forKey: key) {
            var result: Data?
            ioQueue.sync {
                guard fileManager.fileExists(atPath: fileURL.path) else { return }
                do {
                    let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    if let date = values.contentModificationDate,
                       Date().timeIntervalSince(date) < expirationInterval {
                        result = try Data(contentsOf: fileURL)
                        // Touch file so that LRU eviction sees this as recent
                        try fileManager.setAttributes([.modificationDate: Date()],
                                                      ofItemAtPath: fileURL.path)
                    } else {
                        try fileManager.removeItem(at: fileURL)
                    }
                } catch {
                    print("DataCache: Error loading data for key \(key): \(error)")
                }
            }
            if let d = result { return d }
        }

        // Fallback to in-memory
        var memData: Data?
        memoryQueue.sync {
            if let entry = memoryCache[key],
               Date().timeIntervalSince(entry.date) < expirationInterval {
                memData = entry.data
            } else {
                memoryCache.removeValue(forKey: key)
            }
        }
        return memData
    }

    /// Store data for a given key (disk-backed or in-memory fallback)
    public func store(_ data: Data, forKey key: String) {
        if let fileURL = cacheFileURL(forKey: key) {
            ioQueue.async {
                do {
                    try data.write(to: fileURL, options: .atomic)
                    self.purgeExpiredEntries()
                    self.purgeDiskSizeIfNeeded()
                } catch {
                    print("DataCache: Failed to write data for key \(key): \(error)")
                }
            }
        } else {
            memoryQueue.async {
                self.memoryCache[key] = MemoryCacheEntry(data: data)
            }
        }
    }

    /// Remove all entries older than the expiration interval
    public func purgeExpiredEntries() {
        // Disk-based entries
        if let dir = cacheDirectory {
            ioQueue.async {
                do {
                    let urls = try self.fileManager.contentsOfDirectory(at: dir,
                                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                                        options: .skipsHiddenFiles)
                    let now = Date()
                    for url in urls {
                        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                        if let date = values.contentModificationDate,
                           now.timeIntervalSince(date) > self.expirationInterval {
                            try self.fileManager.removeItem(at: url)
                        }
                    }
                } catch {
                    print("DataCache: Failed to purge expired disk entries: \(error)")
                }
            }
        }
        // In-memory entries
        memoryQueue.async {
            let now = Date()
            self.memoryCache = self.memoryCache.filter { _, entry in
                now.timeIntervalSince(entry.date) < self.expirationInterval
            }
        }
    }

    /// Evict least-recently-used files when total disk cache exceeds the size limit
    private func purgeDiskSizeIfNeeded() {
        guard let dir = cacheDirectory else { return }
        ioQueue.async {
            do {
                let urls = try self.fileManager.contentsOfDirectory(at: dir,
                                                                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                                    options: .skipsHiddenFiles)
                var infos: [(url: URL, size: UInt64, date: Date)] = []
                var total: UInt64 = 0
                for url in urls {
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    if let size = values.fileSize.map(UInt64.init),
                       let date = values.contentModificationDate {
                        infos.append((url, size, date))
                        total += size
                    }
                }
                guard total > self.maxDiskCacheSize else { return }
                // Remove oldest first until under limit
                let sorted = infos.sorted { $0.date < $1.date }
                var toFree = total - self.maxDiskCacheSize
                for info in sorted {
                    if toFree == 0 { break }
                    try self.fileManager.removeItem(at: info.url)
                    toFree = toFree > info.size ? toFree - info.size : 0
                }
            } catch {
                print("DataCache: Failed to purge disk size: \(error)")
            }
        }
    }

    /// Completely clear the cache (disk and memory)
    public func clearAll() {
        if let dir = cacheDirectory {
            ioQueue.async {
                do {
                    try self.fileManager.removeItem(at: dir)
                    try self.fileManager.createDirectory(at: dir,
                                                         withIntermediateDirectories: true,
                                                         attributes: nil)
                } catch {
                    print("DataCache: Failed to clear disk cache: \(error)")
                }
            }
        }
        memoryQueue.async {
            self.memoryCache.removeAll()
        }
    }
}

// MARK: - String SHA256 Extension
private extension String {
    func sha256() -> String {
        let data = Data(self.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
