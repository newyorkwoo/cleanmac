import AppKit
import CleanMacCore
import SwiftUI

// MARK: - Memory

struct MemoryView: View {
    @Bindable var model: MemoryModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("記憶體"), subtitle: L("macOS 會自動管理記憶體，「可回收快取」並非浪費。只有在壓力偏高時，才需要結束占用多的 App。")) {
                Button(model.isPurging ? L("釋放中⋯") : L("釋放快取記憶體")) { model.purge() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPurging)
                    .help(L("執行 macOS 內建的 purge 指令，需要管理者密碼。短時間內 App 可能變慢，因為快取要重新載入。"))
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                let memory = model.snapshot
                let segments: [(String, Int64, Color)] = [
                    ("App", memory.app, .blue), (L("系統保留"), memory.wired, .orange), (L("已壓縮"), memory.compressed, .purple),
                    (L("可回收快取"), memory.cached, .teal), (L("閒置"), memory.free, .gray),
                ]
                GeometryReader { geometry in
                    let sum = max(1, segments.reduce(0) { $0 + $1.1 })
                    HStack(spacing: 1) {
                        ForEach(segments, id: \.0) { segment in
                            segment.2.frame(width: max(0, (geometry.size.width - 4) * CGFloat(segment.1) / CGFloat(sum)))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(height: 22)
                .accessibilityHidden(true)

                HStack(spacing: 18) {
                    ForEach(segments, id: \.0) { segment in
                        HStack(spacing: 5) {
                            Circle().fill(segment.2).frame(width: 8, height: 8)
                            Text(segment.0).foregroundStyle(.secondary)
                            Text(formatBytes(segment.1)).monospacedDigit()
                        }
                    }
                    Spacer()
                }
                .font(.caption)

                HStack(spacing: 24) {
                    LabeledContent(L("總記憶體"), value: formatBytes(memory.total))
                    LabeledContent(L("記憶體壓力"), value: memory.pressure.title)
                    LabeledContent(L("置換空間"), value: formatBytes(memory.swapUsed))
                    Spacer()
                }
                .font(.callout)
            }
            .padding(20)
            Divider()
            List(model.processes) { process in
                HStack {
                    Text(process.name).lineLimit(1)
                    Spacer()
                    Text(formatBytes(process.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    Button(L("結束")) { model.quit(pid: process.pid) }
                        .controlSize(.small)
                        .disabled(!model.isQuittable(pid: process.pid))
                        .help(L("正常結束 App，未儲存的文件會由 App 詢問。背景程序無法在此結束。"))
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - Startup

struct StartupView: View {
    @Bindable var model: StartupModel
    @State private var pendingRemoval: StartupItem?

    private var grouped: [(StartupDomain, [StartupItem])] {
        [StartupDomain.userAgent, .globalAgent, .globalDaemon].compactMap { domain in
            let items = model.items.filter { $0.domain == domain }
            return items.isEmpty ? nil : (domain, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("開機項目"), subtitle: L("停用可以減少開機和背景負擔，之後隨時能重新啟用。Apple 系統項目不會列出。")) {
                Button(L("系統設定")) { openSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") }
                Button(L("重新整理")) { model.load() }.disabled(model.isScanning)
            }
            Divider()
            if model.isScanning {
                ScanProgress(status: L("正在讀取開機項目"))
            } else {
                List {
                    Section(L("登入項目")) {
                        if model.loginItemsLoaded {
                            if model.loginItems.isEmpty {
                                Text(L("沒有登入項目")).foregroundStyle(.secondary)
                            }
                            ForEach(model.loginItems) { item in
                                HStack {
                                    Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(item.label)
                                        Text(item.program ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Button(L("移除")) { model.removeLoginItem(item) }.controlSize(.small)
                                }
                            }
                        } else {
                            HStack {
                                Text(L("讀取登入項目時，macOS 會詢問是否允許控制「系統事件」。"))
                                    .font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Button(L("讀取")) { model.loadLoginItems() }
                            }
                        }
                    }
                    ForEach(grouped, id: \.0) { domain, items in
                        Section(domain.title) {
                            ForEach(items) { item in
                                StartupRow(item: item, isBusy: model.busy.contains(item.id), onToggle: {
                                    model.setEnabled(item, enabled: $0)
                                }, onRemove: { pendingRemoval = item })
                            }
                        }
                    }
                }
            }
        }
        .task { if !model.hasScanned { model.load() } }
        .alert(L("要移除「%@」嗎？", pendingRemoval?.displayName ?? ""), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button(L("移除"), role: .destructive) { if let pendingRemoval { model.removeAgent(pendingRemoval) } }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("會停用這個項目，並將它的設定檔移到垃圾桶。App 本身不會被刪除，但下次開啟時可能重新加入。"))
        }
    }
}

private struct StartupRow: View {
    let item: StartupItem
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                    if item.keepAlive { Text(L("常駐")).font(.caption2).foregroundStyle(.orange) }
                    if item.runAtLoad { Text(L("開機啟動")).font(.caption2).foregroundStyle(.secondary) }
                }
                Text(item.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Toggle(L("啟用 %@", item.displayName), isOn: Binding(get: { !item.disabled }, set: onToggle))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(item.domain == .globalDaemon ? L("變更系統背景程式需要管理者密碼") : "")
            }
        }
        .contextMenu {
            if let plist = item.plistURL {
                Button(L("在 Finder 中顯示設定檔")) { revealInFinder(plist) }
            }
            if item.domain == .userAgent {
                Button(L("移除⋯"), role: .destructive, action: onRemove)
            }
        }
    }
}

// MARK: - Apps

struct AppsView: View {
    @Bindable var model: AppsModel
    @State private var pendingUninstall: AppInfo?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("應用程式"), subtitle: L("解除安裝時一併清掉 App 留下的資料。內建系統 App 不會列出。")) {
                Picker(L("排序"), selection: $model.sort) {
                    ForEach(AppsModel.Sort.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Button(L("重新整理")) { model.scan() }.disabled(model.isScanning)
            }
            Divider()
            if model.isScanning {
                ScanProgress(status: model.status)
            } else {
                HSplitView {
                    List(model.sortedApps, selection: Binding(
                        get: { model.chosen?.id },
                        set: { id in if let info = model.apps.first(where: { $0.id == id }) { model.choose(info) } }
                    )) { info in
                        HStack(spacing: 10) {
                            FileIcon(url: info.url, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name).lineLimit(1)
                                Text(L("上次使用：%@", dateText(info.lastUsed))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formatBytes(info.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .tag(info.id)
                    }
                    .frame(minWidth: 340, maxWidth: .infinity)

                    Group {
                        if let info = model.chosen {
                            detail(info)
                        } else {
                            ContentUnavailableView(L("選擇一個 App"), systemImage: "square.grid.2x2")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { if !model.hasScanned { model.scan() } }
        .alert(L("要解除安裝「%@」嗎？", pendingUninstall?.name ?? ""), isPresented: Binding(
            get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } }
        )) {
            Button(L("移到垃圾桶"), role: .destructive) { if let pendingUninstall { model.uninstall(pendingUninstall) } }
            Button(L("取消"), role: .cancel) {}
        } message: {
            if model.selectedSystemCount > 0 {
                Text(L("App 和勾選的 %@ 個相關項目會移到垃圾桶。其中 %@ 個是系統項目：需要管理者密碼，相關背景服務也會停止，之後放回原位時同樣需要密碼。", model.selectedLeftovers.count, model.selectedSystemCount))
            } else {
                Text(L("App 和勾選的 %@ 個相關項目會移到垃圾桶，清空前都可以救回。", model.selectedLeftovers.count))
            }
        }
    }

    private func detail(_ info: AppInfo) -> some View {
        let leftoverSize = model.leftovers.filter { model.selectedLeftovers.contains($0.id) }.reduce(0) { $0 + $1.size }
        let running = model.isRunning(info)
        let isSelf = info.bundleID == Bundle.main.bundleIdentifier
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                FileIcon(url: info.url, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).font(.headline)
                    Text(info.version.isEmpty ? info.bundleID : "\(info.version) · \(info.bundleID)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(16)
            Divider()
            if model.isLoadingLeftovers {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.leftovers.isEmpty {
                ContentUnavailableView(L("沒有找到相關資料"), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.leftovers) { item in
                    FileRow(url: item.url, size: item.size, isOn: Binding(
                        get: { model.selectedLeftovers.contains(item.id) },
                        set: { if $0 { model.selectedLeftovers.insert(item.id) } else { model.selectedLeftovers.remove(item.id) } }
                    ), needsAdmin: item.isSystem)
                }
            }
            Divider()
            HStack {
                Text(L("合計 %@", formatBytes(info.size + leftoverSize))).font(.callout).monospacedDigit()
                if running { Text(L("執行中，請先結束")).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button(L("解除安裝"), role: .destructive) { pendingUninstall = info }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || isSelf)
            }
            .padding(12)
        }
    }
}
