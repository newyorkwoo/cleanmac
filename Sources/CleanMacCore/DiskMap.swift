import CoreGraphics
import Foundation

public final class DiskNode: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let url: URL
    private let rawName: String
    public var name: String { isAggregate ? L("其他 %@ 個小檔案", rawName) : rawName }
    public let isDirectory: Bool
    /// Stands in for many small files that are not worth a node of their own.
    public let isAggregate: Bool
    public private(set) var size: Int64
    public private(set) var children: [DiskNode]
    public private(set) weak var parent: DiskNode?

    init(url: URL, name: String, isDirectory: Bool, isAggregate: Bool = false, size: Int64, children: [DiskNode] = []) {
        self.url = url
        self.rawName = name
        self.isDirectory = isDirectory
        self.isAggregate = isAggregate
        self.size = size
        self.children = children.sorted { $0.size > $1.size }
        for child in self.children { child.parent = self }
    }

    /// Finds the node for a path at or below this one. Small files merged into an aggregate have no node.
    public func node(atPath path: String) -> DiskNode? {
        let target = FileWalker.normalized(path)
        var cursor = self
        while true {
            let current = FileWalker.normalized(cursor.url.path)
            if current == target { return cursor.isAggregate ? nil : cursor }
            let prefix = current.hasSuffix("/") ? current : current + "/"
            guard cursor.isDirectory, target.hasPrefix(prefix) else { return nil }
            let next = cursor.children.first { child in
                guard !child.isAggregate else { return false }
                let childPath = FileWalker.normalized(child.url.path)
                return childPath == target || (child.isDirectory && target.hasPrefix(childPath + "/"))
            }
            guard let next else { return nil }
            cursor = next
        }
    }

    /// Detaches this node after its file was removed and updates ancestor totals.
    public func removeFromParent() {
        var ancestor = parent
        parent?.children.removeAll { $0 === self }
        while let node = ancestor {
            node.size -= size
            ancestor = node.parent
        }
        parent = nil
    }
}

public enum DiskMapScanner {
    /// Files below this size are merged per folder, which keeps a whole-disk tree small in memory.
    static let aggregateBelow: Int64 = 1_000_000

    private static let skippedAtRoot: Set<String> = ["/Volumes", "/dev", "/System/Volumes", "/net", "/home", "/private/var/vm"]

    /// Uses an explicit stack rather than recursion: scans run on small-stack worker
    /// threads, and a very deep folder tree would otherwise overflow one and crash the app.
    public static func scan(root: URL, progress: ProgressHandler? = nil) -> DiskNode {
        var stack = [Frame(url: root, name: root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)]
        var visited = 0

        while let index = stack.indices.last {
            let cancelled = Task.isCancelled
            if !cancelled, stack[index].next < stack[index].contents.count {
                let child = stack[index].contents[stack[index].next]
                stack[index].next += 1
                guard let values = try? child.resourceValues(forKeys: keySet) else { continue }
                visited += 1
                if visited % 2000 == 0 { progress?(L("已掃瞄 %@ 個項目", visited)) }

                if values.isDirectory == true, values.isSymbolicLink != true {
                    if values.isVolume == true || skippedAtRoot.contains(child.path) { continue }
                    stack.append(Frame(url: child, name: child.lastPathComponent))
                } else {
                    let size = Int64(values.totalFileAllocatedSize ?? 0)
                    if size >= aggregateBelow {
                        stack[index].children.append(DiskNode(url: child, name: child.lastPathComponent, isDirectory: false, size: size))
                    } else {
                        stack[index].smallTotal += size
                        stack[index].smallCount += 1
                    }
                }
                continue
            }

            // This folder is finished: build its node and hand it to the parent.
            let frame = stack.removeLast()
            var children = frame.children
            if frame.smallTotal > 0 {
                children.append(DiskNode(url: frame.url, name: String(frame.smallCount), isDirectory: false,
                                         isAggregate: true, size: frame.smallTotal))
            }
            let total = children.reduce(0) { $0 + $1.size }
            let node = DiskNode(url: frame.url, name: frame.name, isDirectory: true, size: total, children: children)
            guard let parent = stack.indices.last else { return node }
            if node.size > 0 { stack[parent].children.append(node) }
        }
        return DiskNode(url: root, name: root.lastPathComponent, isDirectory: true, size: 0)
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey, .totalFileAllocatedSizeKey]
    private static let keySet = Set(keys)

    private struct Frame {
        let url: URL
        let name: String
        let contents: [URL]
        var next = 0
        var children: [DiskNode] = []
        var smallTotal: Int64 = 0
        var smallCount = 0

        init(url: URL, name: String) {
            self.url = url
            self.name = name
            contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: DiskMapScanner.keys)) ?? []
        }
    }
}

public enum Treemap {
    /// Squarified layout. `sizes` must be sorted descending; the result has one rect per size, in order.
    public static func layout(sizes: [Double], in bounds: CGRect) -> [CGRect] {
        let total = sizes.reduce(0, +)
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return sizes.map { _ in .zero } }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = sizes.map { $0 * scale }

        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var free = bounds
        var index = 0

        while index < areas.count {
            let side = Double(min(free.width, free.height))
            var row: [Double] = []
            var worstSoFar = Double.infinity
            while index + row.count < areas.count {
                let candidate = row + [areas[index + row.count]]
                let ratio = worst(candidate, side: side)
                if !row.isEmpty, ratio > worstSoFar { break }
                row = candidate
                worstSoFar = ratio
            }
            let sum = row.reduce(0, +)
            // With extreme size ratios, rounding can leave almost no room for the last items.
            // Clamping keeps them inside the free space, where they are too small to see anyway.
            let room = Double(free.width >= free.height ? free.width : free.height)
            let thickness = side > 0 ? min(sum / side, room) : 0
            var offset = 0.0
            for area in row {
                let length = thickness > 0 ? min(area / thickness, max(0, side - offset)) : 0
                if free.width >= free.height {
                    result.append(CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length))
                } else {
                    result.append(CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness))
                }
                offset += length
            }
            if free.width >= free.height {
                free = CGRect(x: free.minX + thickness, y: free.minY,
                              width: max(0, free.width - thickness), height: free.height)
            } else {
                free = CGRect(x: free.minX, y: free.minY + thickness,
                              width: free.width, height: max(0, free.height - thickness))
            }
            index += row.count
        }
        return result
    }

    private static func worst(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let largest = row.max(), let smallest = row.min(), smallest > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }
}
