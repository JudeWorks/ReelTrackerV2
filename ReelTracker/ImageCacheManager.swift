//
//  ImageCacheManager.swift
//  ReelTracker
//
//  Created on 2025-05-22
//  Manages in-memory image cache for responsive UI
//

import UIKit
import SwiftUI

/// Manages both in-memory and disk caching of images
@MainActor
final class ImageCacheManager: ObservableObject {
    static let shared = ImageCacheManager()
    
    private var memoryCache: [String: UIImage] = [:]
    private let maxMemoryCacheSize = 50 // Maximum number of images in memory
    private var accessOrder: [String] = [] // Track access order for LRU
    
    private init() {}
    
    /// Get image from memory cache, disk cache, or network
    func loadImage(from urlString: String) async -> UIImage? {
        // 1. Check memory cache first
        if let cachedImage = memoryCache[urlString] {
            // Update access order
            accessOrder.removeAll { $0 == urlString }
            accessOrder.append(urlString)
            return cachedImage
        }
        
        // 2. Check disk cache
        if let data = DataCache.shared.data(forKey: urlString),
           let image = UIImage(data: data) {
            // Add to memory cache
            addToMemoryCache(image: image, key: urlString)
            return image
        }
        
        // 3. Download from network
        guard !urlString.isEmpty,
              let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encoded) else {
            return nil
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                // Store in both caches
                DataCache.shared.store(data, forKey: urlString)
                addToMemoryCache(image: image, key: urlString)
                return image
            }
        } catch {
            print("Failed to load image from \(url): \(error)")
        }
        
        return nil
    }
    
    /// Add image to memory cache with LRU eviction
    private func addToMemoryCache(image: UIImage, key: String) {
        // Remove from old position if exists
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        memoryCache[key] = image
        
        // Evict oldest if over limit
        while memoryCache.count > maxMemoryCacheSize && !accessOrder.isEmpty {
            let oldestKey = accessOrder.removeFirst()
            memoryCache.removeValue(forKey: oldestKey)
        }
    }
    
    /// Clear memory cache (useful for memory warnings)
    func clearMemoryCache() {
        memoryCache.removeAll()
        accessOrder.removeAll()
    }
    
    /// Preload images for better scrolling performance
    func preloadImages(urls: [String]) {
        Task {
            for url in urls {
                _ = await loadImage(from: url)
            }
        }
    }
}

/// Optimized async image view using the cache manager
struct OptimizedAsyncImage: View {
    let urlString: String
    let width: CGFloat
    let height: CGFloat
    
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var loadTask: Task<Void, Never>?
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else if isLoading {
                ProgressView()
                    .frame(width: width, height: height)
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            loadTask = Task {
                if let loadedImage = await ImageCacheManager.shared.loadImage(from: urlString) {
                    await MainActor.run {
                        self.image = loadedImage
                        self.isLoading = false
                    }
                } else {
                    await MainActor.run {
                        self.isLoading = false
                    }
                }
            }
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }
}
