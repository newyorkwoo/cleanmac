import CleanMacCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: Set<SmartScanItem> = [.junk, .large, .duplicates, .startup, .security]
    @State private var confirmClean = false

    private var memory: MemoryModel { model.memory }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 36) {
                    let disk = memory.disk
                    let used = disk.total - disk.available
                    Ring(fraction: disk.total > 0 ? Double(used) / Double(disk.total) : 0, color: .blue,
                         value: disk.total > 0 ? "\(used * 100 / disk.total)%" : "—",
                         caption: L("磁碟\n可用 %@", formatBytes(disk.available)))
                    Ring(fraction: memory.snapshot.usedFraction, color: pressureColor,
                         value: "\(Int(memory.snapshot.usedFraction * 100))%",
                         caption: L("記憶體\n壓力：%@", memory.snapshot.pressure.title))
                    Ring(fraction: memory.cpu, color: .teal, value: "\(Int(memory.cpu * 100))%", caption: L("CPU\n目前使用率"))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        if model.isSmartScanning {
                            Button(L("停止掃瞄"), role: .cancel) { model.cancelSmartScan() }.controlSize(.large)
                        } else {
                            Button(L("開始智慧掃瞄")) { model.startSmartScan(chosen) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(chosen.isEmpty)
                        }
                        if model.junk.selectedSize > 0, !model.isSmartScanning {
                            Button(L("清理建議的垃圾檔案（%@）", formatBytes(model.junk.selectedSize))) { confirmClean = true }
                        }
                    }
                }

                Text(L("掃瞄不會刪除任何檔案。結果出來後，由你確認要清理哪些項目。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(SmartScanItem.allCases) { item in
                        ScanCard(item: item, summary: summary(for: item), isOn: binding(for: item))
                    }
                }
            }
            .padding(24)
        }
        .task {
            while !Task.isCancelled {
                await memory.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .trashConfirmation(isPresented: $confirmClean, count: model.junk.selectedItems.count, size: model.junk.selectedSize) {
            model.junk.clean()
        }
    }

    private var pressureColor: Color {
        switch memory.snapshot.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func binding(for item: SmartScanItem) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(item) },
            set: { if $0 { chosen.insert(item) } else { chosen.remove(item) } }
        )
    }

    private func summary(for item: SmartScanItem) -> String {
        let scan = model.model(for: item)
        if scan.isScanning { return scan.status }
        guard scan.hasScanned else {
            switch item {
            case .photos: return L("需要較長時間，預設不勾選")
            case .security: return L("檢查系統防護、可疑開機項目和更新")
            default: return L("尚未掃瞄")
            }
        }
        switch item {
        case .junk:
            return model.junk.total > 0 ? L("共 %@，建議清理 %@", formatBytes(model.junk.total), formatBytes(model.junk.selectedSize)) : L("沒有找到垃圾檔案")
        case .large:
            return model.large.files.isEmpty ? L("沒有找到大型檔案") : L("%@ 個檔案，共 %@", model.large.files.count, formatBytes(model.large.total))
        case .duplicates:
            return model.duplicates.groups.isEmpty ? L("沒有找到重複檔案") : L("%@ 組，可釋放 %@", model.duplicates.groups.count, formatBytes(model.duplicates.reclaimable))
        case .photos:
            return model.photos.groups.isEmpty ? L("沒有找到相似照片") : L("%@ 組，可釋放 %@", model.photos.groups.count, formatBytes(model.photos.reclaimable))
        case .startup:
            let active = model.startup.items.filter { !$0.disabled }.count
            return L("%@ 個第三方項目，%@ 個已啟用", model.startup.items.count, active)
        case .security:
            let count = model.security.issues.count
            return count == 0 ? L("沒有發現需要處理的問題") : L("%@ 個項目需要注意", count)
        }
    }
}

private struct ScanCard: View {
    @Environment(AppModel.self) private var model
    let item: SmartScanItem
    let summary: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(L("掃瞄%@", item.page.title), isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Image(systemName: item.page.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.page.title).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2).monospacedDigit()
            }
            Spacer(minLength: 4)
            if model.model(for: item).isScanning {
                ProgressView().controlSize(.small)
            } else {
                Button(L("查看")) { model.page = item.page }
            }
        }
        .padding(14)
        .frame(minHeight: 70)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
