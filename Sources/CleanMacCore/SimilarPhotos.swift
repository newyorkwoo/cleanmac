import Accelerate
import Foundation
import ImageIO
import Vision

public struct PhotoRecord: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let modified: Date?
}

public struct PhotoGroup: Identifiable, Sendable {
    public let id: String
    /// Best photo first (most pixels, then the largest file).
    public let photos: [PhotoRecord]

    public init(id: String, photos: [PhotoRecord]) {
        self.id = id
        self.photos = photos
    }

    public var reclaimable: Int64 { photos.dropFirst().reduce(0) { $0 + $1.size } }
}

public enum SimilarPhotoFinder {
    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"]

    /// Vision feature-print distance under which two photos count as near-identical.
    /// Tuned on a real library: at 0.45 different pages of a scanned textbook merged into
    /// groups of 49, while 0.2 keeps recompressed and resized copies together without that.
    public static let defaultThreshold: Float = 0.2

    /// Photos in a Photos library are not scanned because the walker skips packages:
    /// deleting files inside a library would corrupt it.
    public static func scan(
        root: URL,
        options: WalkOptions,
        threshold: Float = defaultThreshold,
        limit: Int = 10_000,
        progress: ProgressHandler? = nil
    ) async -> [PhotoGroup] {
        var paths: [FileRecord] = []
        FileWalker.walk(root: root, options: options) { url, values in
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            if extensions.contains(url.pathExtension.lowercased()), size >= 50_000, paths.count < limit {
                paths.append(FileRecord(url: url, size: size, modified: values.contentModificationDate))
            }
        }

        var analyzed: [Analyzed] = []
        analyzed.reserveCapacity(paths.count)
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

        await withTaskGroup(of: Analyzed?.self) { group in
            var iterator = paths.makeIterator()
            func addNext() -> Bool {
                guard let next = iterator.next() else { return false }
                group.addTask { Task.isCancelled ? nil : analyze(next) }
                return true
            }
            for _ in 0..<workers where !addNext() { break }
            var finished = 0
            while let result = await group.next() {
                finished += 1
                if finished % 20 == 0 { progress?(L("正在分析照片 %@/%@", finished, paths.count)) }
                if let result { analyzed.append(result) }
                _ = addNext()
            }
        }
        if Task.isCancelled { return [] }
        progress?(L("正在比對相似度"))
        return cluster(analyzed, threshold: threshold)
    }

    /// Each photo joins the first group whose seed is close enough. Comparing against
    /// the seed only keeps a chain of slightly different shots from merging into one group.
    private static func cluster(_ photos: [Analyzed], threshold: Float) -> [PhotoGroup] {
        let sorted = photos.sorted { ($0.record.modified ?? .distantPast) < ($1.record.modified ?? .distantPast) }
        var clusters: [(seed: [Float], members: [PhotoRecord])] = []
        let limit = threshold * threshold

        for photo in sorted {
            if Task.isCancelled { return [] }
            let index = clusters.firstIndex { cluster in
                guard cluster.seed.count == photo.vector.count else { return false }
                var distance: Float = 0
                vDSP_distancesq(cluster.seed, 1, photo.vector, 1, &distance, vDSP_Length(photo.vector.count))
                return distance <= limit
            }
            if let index {
                clusters[index].members.append(photo.record)
            } else {
                clusters.append((photo.vector, [photo.record]))
            }
        }

        return clusters
            .filter { $0.members.count > 1 }
            .map { cluster in
                let ranked = cluster.members.sorted {
                    let a = $0.pixelWidth * $0.pixelHeight
                    let b = $1.pixelWidth * $1.pixelHeight
                    return a == b ? $0.size > $1.size : a > b
                }
                return PhotoGroup(id: ranked[0].id, photos: ranked)
            }
            .sorted { $0.reclaimable > $1.reclaimable }
    }

    private struct Analyzed: Sendable {
        let record: PhotoRecord
        let vector: [Float]
    }

    private static func analyze(_ file: FileRecord) -> Analyzed? {
        autoreleasepool {
            guard !FileWalker.isDataless(file.url),
                  let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                return nil
            }
            let request = VNGenerateImageFeaturePrintRequest()
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
                  let print = request.results?.first as? VNFeaturePrintObservation,
                  print.elementType == .float else { return nil }
            let vector = print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let record = PhotoRecord(url: file.url, size: file.size, pixelWidth: width, pixelHeight: height,
                                     modified: file.modified)
            return Analyzed(record: record, vector: vector)
        }
    }
}
