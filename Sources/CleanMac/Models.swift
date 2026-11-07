import AppKit
import CleanMacCore
import Observation
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case dashboard, junk, large, duplicates, photos, diskMap, memory, startup, apps, security, shredder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return L("智慧掃瞄")
        case .junk: return L("垃圾檔案")
        case .large: return L("大型檔案")
        case .duplicates: return L("重複檔案")
        case .photos: return L("相似照片")
        case .diskMap: return L("磁碟地圖")
        case .memory: return L("記憶體")
        case .startup: return L("開機項目")
        case .apps: return L("應用程式")
        case .security: return L("安全檢查")
        case .shredder: return L("檔案粉碎")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "sparkles"
        case .junk: return "trash.circle"
        case .large: return "doc.badge.ellipsis"
        case .duplicates: return "doc.on.doc"
        case .photos: return "photo.on.rectangle"
        case .diskMap: return "square.grid.3x3.square"
        case .memory: return "memorychip"
        case .startup: return "power"
        case .apps: return "square.grid.2x2"
        case .security: return "checkmark.shield"
        case .shredder: return "scissors"
        }
    }
}

struct ResultBanner: Identifiable {
    let id = UUID()
    let message: String
    var failures: [CleanResult.Failure] = []
    var offerEmptyTrash = false
    var isError = false
}

/// Bridges a blocking core call to async, forwarding cancellation so scans stop promptly.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    let task = Task.detached(priority: .userInitiated) { work() }
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}

@Observable @MainActor
final class AppModel {
    var page: Page {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "lastPage") }
    }
    var banner: ResultBanner?
    var hasFullDiskAccess = CleanMacCore.hasFullDiskAccess()

    let home: URL
    var lastResult: CleanResult?
    var language = AppLanguage.current {
        didSet {
            guard language != oldValue else { return }
            AppLanguage.select(language)
            // Messages already shown were written in the old language. Security findings
            // embed their text when created, so a finished check runs again.
            banner = nil
            if security.hasScanned { security.scan() }
        }
    }
    @ObservationIgnored lazy var junk = JunkModel(app: self)
    @ObservationIgnored lazy var large = LargeFilesModel(app: self)
    @ObservationIgnored lazy var duplicates = DuplicatesModel(app: self)
    @ObservationIgnored lazy var photos = PhotosModel(app: self)
    @ObservationIgnored lazy var diskMap = DiskMapModel(app: self)
    @ObservationIgnored lazy var memory = MemoryModel(app: self)
    @ObservationIgnored lazy var startup = StartupModel(app: self)
    @ObservationIgnored lazy var apps = AppsModel(app: self)
    @ObservationIgnored lazy var security = SecurityModel(app: self)
    @ObservationIgnored lazy var shredder = ShredderModel(app: self)

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        let saved = UserDefaults.standard.string(forKey: "lastPage").flatMap(Page.init(rawValue:))
        page = saved ?? .dashboard
    }

    func report(_ result: CleanResult, shredded: Bool = false, offerEmptyTrash: Bool = true) {
        lastResult = result
        prune(removedPaths: result.removedPaths)
        let bytes = formatBytes(result.bytes)
        let summary: String
        if result.count == 0 {
            summary = L("沒有項目被處理。")
        } else if shredded {
            summary = L("已粉碎 %@ 個項目（%@）。", result.count, bytes)
        } else {
            summary = L("已移到垃圾桶 %@ 個項目（%@）。", result.count, bytes)
        }
        let hint = offerEmptyTrash && result.count > 0 ? L("清空垃圾桶後才會真正釋放空間。") : ""
        banner = ResultBanner(message: summary + hint, failures: result.failures,
                              offerEmptyTrash: offerEmptyTrash && result.count > 0, isError: result.count == 0 && !result.failures.isEmpty)
    }

    /// Drops removed items, and anything inside removed folders, from every page's results,
    /// so no page keeps offering a file that another page already removed.
    func prune(removedPaths: [String]) {
        guard !removedPaths.isEmpty else { return }
        let removed = Set(removedPaths.map(FileWalker.normalized))
        func isGone(_ url: URL) -> Bool {
            var path = FileWalker.normalized(url.path)
            while path.count > 1 {
                if removed.contains(path) { return true }
                path = (path as NSString).deletingLastPathComponent
            }
            return false
        }
        junk.prune(isGone)
        large.prune(isGone)
        duplicates.prune(isGone)
        photos.prune(isGone)
        apps.prune(isGone)
        diskMap.prune(removedPaths)
    }

    func reportError(_ message: String) {
        banner = ResultBanner(message: message, isError: true)
    }

    func emptyTrash() {
        Task {
            let before = SystemMonitor.disk().available
            let outcome = await offMain { TrashEmptier.run() }
            switch outcome {
            case .alreadyEmpty:
                banner = ResultBanner(message: L("垃圾桶已經是空的。"))
            case .emptied:
                let gained = SystemMonitor.disk().available - before
                banner = ResultBanner(message: gained > 0 ? L("已清空垃圾桶，可用空間增加 %@。", formatBytes(gained)) : L("已清空垃圾桶。"))
            case .cancelled:
                banner = ResultBanner(message: L("已取消清空，垃圾桶的內容沒有變動。"), offerEmptyTrash: true)
            case .failed(let message):
                reportError(L("無法清空垃圾桶：%@", message))
            }
        }
    }
}

@Observable @MainActor
class ScanModel {
    @ObservationIgnored unowned let app: AppModel
    var isScanning = false
    var hasScanned = false
    var status = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    var progress: ProgressHandler {
        { [weak self] message in Task { @MainActor in self?.status = message } }
    }

    func launch(_ body: @escaping @MainActor () async -> Void) {
        guard !isScanning else { return }
        isScanning = true
        status = L("正在掃瞄…")
        task = Task {
            await body()
            isScanning = false
            hasScanned = true
        }
    }

    func cancel() { task?.cancel() }
    func waitUntilDone() async { await task?.value }
}

// MARK: - Junk

@Observable @MainActor
final class JunkModel: ScanModel {
    var categories: [JunkCategory] = []
    var selected: Set<String> = []

    var selectedItems: [JunkItem] { categories.flatMap(\.items).filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var total: Int64 { categories.reduce(0) { $0 + $1.size } }
    var selectionIncludesPermanent: Bool {
        categories.contains { $0.permanent && $0.items.contains { selected.contains($0.id) } }
    }

    func prune(_ isGone: (URL) -> Bool) {
        categories = categories.compactMap { category in
            let kept = category.items.filter { !isGone($0.url) }
            guard kept.count != category.items.count else { return category }
            return kept.isEmpty ? nil : JunkCategory(
                id: category.id, title: category.titleKey, detail: category.detailKey, symbol: category.symbol,
                defaultSelected: category.defaultSelected, permanent: category.permanent, items: kept)
        }
        selected = selected.intersection(categories.flatMap(\.items).map(\.id))
    }

    /// Risky categories and data of apps that are running now always start unchecked.
    static func defaultSelection(for categories: [JunkCategory]) -> Set<String> {
        Set(categories.filter(\.defaultSelected).flatMap(\.items).filter { !$0.inUse }.map(\.id))
    }

    func scan() {
        let home = app.home
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        launch { [self, progress] in
            let scanner = JunkScanner(home: home, runningBundleIDs: running) {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
            let categories = await offMain { scanner.scan(progress: progress) }
            self.categories = categories
            self.selected = Self.defaultSelection(for: categories)
        }
    }

    @discardableResult func clean() -> Task<Void, Never> {
        let trashIDs = Set(categories.filter(\.permanent).flatMap(\.items).map(\.id))
        let chosen = selectedItems
        let toTrash = chosen.filter { !trashIDs.contains($0.id) }.map { (url: $0.url, size: $0.size) }
        let toDelete = chosen.filter { trashIDs.contains($0.id) }.map { (url: $0.url, size: $0.size) }
        let cleaner = Cleaner(home: app.home)
        let currentCategories = categories
        let currentSelection = selected
        return Task {
            let moved = await offMain { cleaner.moveToTrash(toTrash) }
            let deleted = await offMain { cleaner.deleteFromTrash(toDelete) }
            var combined = moved
            combined.merge(deleted)
            let failed = Set(combined.failures.map(\.path))
            categories = currentCategories.compactMap { category in
                let kept = category.items.filter { !currentSelection.contains($0.id) || failed.contains($0.id) }
                return kept.isEmpty ? nil : JunkCategory(
                    id: category.id, title: category.titleKey, detail: category.detailKey, symbol: category.symbol,
                    defaultSelected: category.defaultSelected, permanent: category.permanent, items: kept)
            }
            selected = selected.intersection(failed)
            app.report(combined, offerEmptyTrash: moved.count > 0)
        }
    }
}

// MARK: - Large files

@Observable @MainActor
final class LargeFilesModel: ScanModel {
    var root: URL
    var minimumMB = 100
    var files: [FileRecord] = []
    var selected: Set<String> = []
    var sortByDate = false

    override init(app: AppModel) {
        root = app.home
        super.init(app: app)
    }

    var sortedFiles: [FileRecord] {
        sortByDate ? files.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) } : files
    }
    var selectedSize: Int64 { files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }
    var total: Int64 { files.reduce(0) { $0 + $1.size } }

    func prune(_ isGone: (URL) -> Bool) {
        files.removeAll { isGone($0.url) }
        selected = selected.intersection(files.map(\.id))
    }

    func scan() {
        let root = root, home = app.home, minimum = Int64(minimumMB) * 1_000_000
        launch { [self, progress] in
            files = await offMain {
                LargeFileFinder.scan(root: root, options: .personalFiles(home: home), minimumBytes: minimum, progress: progress)
            }
            selected = []
        }
    }

    @discardableResult func clean() -> Task<Void, Never> {
        let chosen = files.filter { selected.contains($0.id) }.map { (url: $0.url, size: $0.size) }
        let cleaner = Cleaner(home: app.home)
        return Task {
            let result = await offMain { cleaner.moveToTrash(chosen) }
            let failed = Set(result.failures.map(\.path))
            files.removeAll { selected.contains($0.id) && !failed.contains($0.id) }
            selected = selected.intersection(failed)
            app.report(result)
        }
    }
}

// MARK: - Duplicates

@Observable @MainActor
final class DuplicatesModel: ScanModel {
    var root: URL
    var minimumMB = 1
    var groups: [DuplicateGroup] = []
    var selected: Set<String> = []

    override init(app: AppModel) {
        root = app.home
        super.init(app: app)
    }

    var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
    var selectedFiles: [FileRecord] { groups.flatMap(\.files).filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }

    func scan() {
        let root = root, home = app.home, minimum = Int64(minimumMB) * 1_000_000
        launch { [self, progress] in
            groups = await offMain {
                DuplicateFinder.scan(root: root, options: .personalFiles(home: home), minimumBytes: minimum, progress: progress)
            }
            selected = []
        }
    }

    func prune(_ isGone: (URL) -> Bool) {
        groups = groups.compactMap { group in
            let kept = group.files.filter { !isGone($0.url) }
            guard kept.count != group.files.count else { return group }
            return kept.count > 1 ? DuplicateGroup(id: group.id, size: group.size, files: kept) : nil
        }
        selected = selected.intersection(groups.flatMap(\.files).map(\.id))
        // If the unchecked copy was the one removed elsewhere, the rest could all be checked.
        for group in groups where group.files.allSatisfy({ selected.contains($0.id) }) {
            if let keeper = group.suggestedKeeper { selected.remove(keeper.id) }
        }
    }

    /// Every group must keep at least one copy, so the last unchecked file cannot be checked.
    func canSelect(_ file: FileRecord, in group: DuplicateGroup) -> Bool {
        selected.contains(file.id) || group.files.filter { selected.contains($0.id) }.count < group.files.count - 1
    }

    func autoSelect() {
        selected = Set(groups.flatMap { group in
            group.files.filter { $0.id != group.suggestedKeeper?.id }.map(\.id)
        })
    }

    @discardableResult func clean() -> Task<Void, Never> {
        let chosen = selectedFiles.map { (url: $0.url, size: $0.size) }
        let cleaner = Cleaner(home: app.home)
        return Task {
            let result = await offMain { cleaner.moveToTrash(chosen) }
            let failed = Set(result.failures.map(\.path))
            let removed = selected.subtracting(failed)
            groups = groups.compactMap { group in
                let kept = group.files.filter { !removed.contains($0.id) }
                return kept.count > 1 ? DuplicateGroup(id: group.id, size: group.size, files: kept) : nil
            }
            selected = selected.intersection(failed)
            app.report(result)
        }
    }
}

// MARK: - Photos

@Observable @MainActor
final class PhotosModel: ScanModel {
    var root: URL
    var groups: [PhotoGroup] = []
    var selected: Set<String> = []

    override init(app: AppModel) {
        root = app.home
        super.init(app: app)
    }

    var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
    var selectedPhotos: [PhotoRecord] { groups.flatMap(\.photos).filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedPhotos.reduce(0) { $0 + $1.size } }

    func scan() {
        let root = root, home = app.home
        launch { [self, progress] in
            let task = Task.detached(priority: .userInitiated) {
                await SimilarPhotoFinder.scan(root: root, options: .personalFiles(home: home), progress: progress)
            }
            groups = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            selected = []
        }
    }

    func prune(_ isGone: (URL) -> Bool) {
        groups = groups.compactMap { group in
            let kept = group.photos.filter { !isGone($0.url) }
            guard kept.count != group.photos.count else { return group }
            return kept.count > 1 ? PhotoGroup(id: group.id, photos: kept) : nil
        }
        selected = selected.intersection(groups.flatMap(\.photos).map(\.id))
        for group in groups where group.photos.allSatisfy({ selected.contains($0.id) }) {
            if let best = group.photos.first { selected.remove(best.id) }
        }
    }

    func toggle(_ photo: PhotoRecord, in group: PhotoGroup) {
        if selected.contains(photo.id) {
            selected.remove(photo.id)
        } else if group.photos.filter({ selected.contains($0.id) }).count < group.photos.count - 1 {
            selected.insert(photo.id)
        }
    }

    func autoSelect() {
        selected = Set(groups.flatMap { $0.photos.dropFirst().map(\.id) })
    }

    @discardableResult func clean() -> Task<Void, Never> {
        let chosen = selectedPhotos.map { (url: $0.url, size: $0.size) }
        let cleaner = Cleaner(home: app.home)
        return Task {
            let result = await offMain { cleaner.moveToTrash(chosen) }
            let failed = Set(result.failures.map(\.path))
            let removed = selected.subtracting(failed)
            groups = groups.compactMap { group in
                let kept = group.photos.filter { !removed.contains($0.id) }
                return kept.count > 1 ? PhotoGroup(id: group.id, photos: kept) : nil
            }
            selected = selected.intersection(failed)
            app.report(result)
        }
    }
}

// MARK: - Disk map

@Observable @MainActor
final class DiskMapModel: ScanModel {
    var root: URL
    var tree: DiskNode?
    var current: DiskNode?
    /// Bumped after removals, because the node tree itself is not observable.
    var revision = 0

    override init(app: AppModel) {
        root = app.home
        super.init(app: app)
    }

    func scan() {
        let root = root
        launch { [self, progress] in
            let node = await offMain { DiskMapScanner.scan(root: root, progress: progress) }
            tree = node
            current = node
        }
    }

    func prune(_ paths: [String]) {
        guard let tree else { return }
        var changed = false
        for path in paths {
            guard let node = tree.node(atPath: path), node !== tree else { continue }
            // If the folder on screen is going away, move up to what remains.
            var cursor = current
            while let visible = cursor {
                if visible === node { current = node.parent; break }
                cursor = visible.parent
            }
            node.removeFromParent()
            changed = true
        }
        if changed { revision += 1 }
    }

    func trash(_ node: DiskNode) {
        let cleaner = Cleaner(home: app.home)
        let target = (url: node.url, size: node.size)
        Task {
            let result = await offMain { cleaner.moveToTrash([target]) }
            if result.count == 1 {
                node.removeFromParent()
                revision += 1
            }
            app.report(result)
        }
    }
}

// MARK: - Memory

@Observable @MainActor
final class MemoryModel: ScanModel {
    var snapshot = SystemMonitor.memory()
    var processes: [ProcessMemory] = []
    var cpu = 0.0
    var disk = SystemMonitor.disk()
    var isPurging = false
    @ObservationIgnored private let sampler = CPUSampler()

    func refresh() async {
        let (memory, top) = await offMain { (SystemMonitor.memory(), SystemMonitor.topProcesses()) }
        snapshot = memory
        processes = top
        cpu = sampler.sample()
        disk = SystemMonitor.disk()
    }

    func purge() {
        guard !isPurging else { return }
        isPurging = true
        let before = snapshot.free
        Task {
            let failure: String? = await offMain {
                do { try SystemMonitor.purgeInactiveMemory(); return nil }
                catch { return error.localizedDescription }
            }
            await refresh()
            isPurging = false
            if let failure {
                // Cancelling the password prompt is a normal choice, so it isn't reported as an error.
                if !failure.contains("-128") { app.reportError(L("無法釋放記憶體：%@", failure)) }
            } else {
                let gained = snapshot.free - before
                app.banner = ResultBanner(message: gained > 0 ? L("可用記憶體增加了 %@。", formatBytes(gained)) : L("已清除檔案快取，可用記憶體沒有明顯變化。"))
            }
        }
    }

    func quit(pid: Int32) {
        guard let application = NSRunningApplication(processIdentifier: pid) else { return }
        application.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        }
    }

    func isQuittable(pid: Int32) -> Bool {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: pid) else { return false }
        return application.activationPolicy == .regular
    }
}

// MARK: - Startup

@Observable @MainActor
final class StartupModel: ScanModel {
    var items: [StartupItem] = []
    var loginItems: [StartupItem] = []
    var loginItemsLoaded = false
    var busy: Set<String> = []

    func load() {
        launch { self.items = await offMain { StartupManager.list() } }
    }

    func loadLoginItems() {
        Task {
            let result: Result<[StartupItem], Error> = await offMain { Result { try StartupManager.loginItems() } }
            switch result {
            case .success(let list):
                loginItems = list
                loginItemsLoaded = true
            case .failure(let error):
                app.reportError(L("無法讀取登入項目（請在系統設定 > 隱私權與安全性 > 自動化中允許）：%@", error.localizedDescription))
            }
        }
    }

    func setEnabled(_ item: StartupItem, enabled: Bool) {
        busy.insert(item.id)
        Task {
            let failure: String? = await offMain {
                do { try StartupManager.setEnabled(item, enabled: enabled); return nil }
                catch { return error.localizedDescription }
            }
            if let failure, !failure.contains("-128") { app.reportError(L("無法變更「%@」：%@", item.displayName, failure)) }
            items = await offMain { StartupManager.list() }
            busy.remove(item.id)
        }
    }

    func removeAgent(_ item: StartupItem) {
        guard let plist = item.plistURL else { return }
        let cleaner = Cleaner(home: app.home)
        Task {
            await offMain { try? StartupManager.setEnabled(item, enabled: false) }
            let result = await offMain { cleaner.moveToTrash([(url: plist, size: 0)]) }
            items = await offMain { StartupManager.list() }
            if result.failures.isEmpty {
                app.banner = ResultBanner(message: L("已移除「%@」，設定檔已移到垃圾桶。", item.displayName))
            } else {
                app.report(result)
            }
        }
    }

    func removeLoginItem(_ item: StartupItem) {
        let name = item.label
        Task {
            let failure: String? = await offMain {
                do { try StartupManager.removeLoginItem(named: name); return nil }
                catch { return error.localizedDescription }
            }
            if let failure { app.reportError(L("無法移除登入項目：%@", failure)) }
            else { loginItems.removeAll { $0.id == item.id } }
        }
    }
}

// MARK: - Apps

@Observable @MainActor
final class AppsModel: ScanModel {
    enum Sort: String, CaseIterable, Identifiable {
        case name, size, lastUsed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: return L("名稱")
            case .size: return L("大小")
            case .lastUsed: return L("上次使用")
            }
        }
    }

    var apps: [AppInfo] = []
    var sort: Sort = .name
    var chosen: AppInfo?
    var leftovers: [LeftoverItem] = []
    var selectedLeftovers: Set<String> = []
    var isLoadingLeftovers = false

    var sortedApps: [AppInfo] {
        switch sort {
        case .name: return apps
        case .size: return apps.sorted { $0.size > $1.size }
        case .lastUsed: return apps.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    func scan() {
        let home = app.home
        launch { [self, progress] in
            apps = await offMain { AppInventory.scan(home: home, progress: progress) }
        }
    }

    func choose(_ info: AppInfo) {
        chosen = info
        leftovers = []
        selectedLeftovers = []
        isLoadingLeftovers = true
        let home = app.home
        Task {
            let found = await offMain { AppInventory.leftovers(for: info, home: home) }
            guard chosen?.id == info.id else { return }
            leftovers = found
            selectedLeftovers = Set(found.map(\.id))
            isLoadingLeftovers = false
        }
    }

    func prune(_ isGone: (URL) -> Bool) {
        apps.removeAll { isGone($0.url) }
        if let info = chosen, isGone(info.url) {
            chosen = nil
            leftovers = []
        }
        leftovers.removeAll { isGone($0.url) }
        selectedLeftovers = selectedLeftovers.intersection(leftovers.map(\.id))
    }

    func isRunning(_ info: AppInfo) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleID).isEmpty
    }

    /// How many chosen leftovers will need the administrator password.
    var selectedSystemCount: Int {
        leftovers.filter { $0.isSystem && selectedLeftovers.contains($0.id) }.count
    }

    @discardableResult func uninstall(_ info: AppInfo) -> Task<Void, Never> {
        let chosenLeftovers = leftovers.filter { selectedLeftovers.contains($0.id) }
        let cleaner = Cleaner(home: app.home)
        return Task {
            // nil means the password prompt was cancelled, so nothing changed and there is nothing to report.
            guard let result = await offMain({ cleaner.uninstall(app: (info.url, info.size), leftovers: chosenLeftovers) }) else { return }
            if !result.failures.contains(where: { $0.path == info.url.path }) {
                apps.removeAll { $0.id == info.id }
                chosen = nil
                leftovers = []
            }
            app.report(result)
        }
    }
}

// MARK: - Security

@Observable @MainActor
final class SecurityModel: ScanModel {
    var findings: [SecurityFinding] = []
    var checkedAt: Date?

    var issues: [SecurityFinding] { findings.filter { $0.severity >= .warning } }

    func scan() {
        let apps = app.apps
        let startup = app.startup
        launch { [self, progress] in
            if apps.apps.isEmpty {
                if !apps.isScanning { apps.scan() }
                await apps.waitUntilDone()
            }
            let startupItems = await offMain { StartupManager.list() }
            startup.items = startupItems
            let inventory = apps.apps
            findings = await offMain {
                SecurityAuditor.audit(startupItems: startupItems, apps: inventory, progress: progress)
            }
            checkedAt = Date()
        }
    }

    func disable(_ item: StartupItem) {
        app.startup.setEnabled(item, enabled: false)
        findings.removeAll { $0.startupItem?.id == item.id }
    }
}

// MARK: - Shredder

@Observable @MainActor
final class ShredderModel: ScanModel {
    var queue: [URL] = []
    var passes = 1

    func add(_ urls: [URL]) {
        for url in urls where !queue.contains(url) { queue.append(url) }
    }

    func shred() {
        let targets = queue, passes = passes, home = app.home
        launch { [self, progress] in
            let result = await offMain {
                Shredder.shred(targets, passes: passes, pathGuard: PathGuard(home: home), progress: progress)
            }
            queue.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
            app.report(result, shredded: true, offerEmptyTrash: false)
        }
    }
}

// MARK: - Smart scan

enum SmartScanItem: String, CaseIterable, Identifiable {
    case junk, large, duplicates, photos, startup, security
    var id: String { rawValue }

    var page: Page {
        switch self {
        case .junk: return .junk
        case .large: return .large
        case .duplicates: return .duplicates
        case .photos: return .photos
        case .startup: return .startup
        case .security: return .security
        }
    }
}

extension AppModel {
    func model(for item: SmartScanItem) -> ScanModel {
        switch item {
        case .junk: return junk
        case .large: return large
        case .duplicates: return duplicates
        case .photos: return photos
        case .startup: return startup
        case .security: return security
        }
    }

    func startSmartScan(_ items: Set<SmartScanItem>) {
        for item in items {
            switch item {
            case .junk: junk.scan()
            case .large: large.scan()
            case .duplicates: duplicates.scan()
            case .photos: photos.scan()
            case .startup: startup.load()
            case .security: security.scan()
            }
        }
    }

    func cancelSmartScan() {
        for item in SmartScanItem.allCases { model(for: item).cancel() }
        apps.cancel()
    }

    var isSmartScanning: Bool { SmartScanItem.allCases.contains { model(for: $0).isScanning } }
}
