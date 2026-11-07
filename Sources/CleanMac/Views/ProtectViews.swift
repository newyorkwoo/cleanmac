import AppKit
import CleanMacCore
import SwiftUI

// MARK: - Security

struct SecurityView: View {
    @Bindable var model: SecurityModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("安全檢查"), subtitle: L("檢查系統防護、可疑開機項目、App 簽章和軟體更新。這不是防毒軟體，沒有惡意程式資料庫；惡意程式防護仍由 macOS 內建的 XProtect 負責。")) {
                ScanButton(model: model) { model.scan() }
            }
            Divider()
            if model.isScanning {
                ScanProgress(status: model.status)
            } else if !model.hasScanned {
                ContentUnavailableView(L("尚未檢查"), systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.findings) { finding in
                    HStack(alignment: .top, spacing: 10) {
                        icon(finding.severity)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(finding.title).fontWeight(.medium)
                                Text(finding.group).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        if let link = finding.settingsURL {
                            Button(L("開啟設定")) { openSettings(link) }.controlSize(.small)
                        }
                        if let item = finding.startupItem, !item.disabled {
                            Button(L("停用")) { model.disable(item) }.controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func icon(_ severity: FindingSeverity) -> some View {
        let (name, color, label): (String, Color, String) = switch severity {
        case .ok: ("checkmark.circle.fill", .green, L("正常"))
        case .info: ("info.circle.fill", .blue, L("資訊"))
        case .warning: ("exclamationmark.triangle.fill", .orange, L("警告"))
        case .critical: ("xmark.octagon.fill", .red, L("嚴重"))
        }
        return Image(systemName: name).foregroundStyle(color).accessibilityLabel(label)
    }
}

// MARK: - Shredder

struct ShredderView: View {
    @Bindable var model: ShredderModel
    @Environment(AppModel.self) private var app
    @State private var confirm = false
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("檔案粉碎"), subtitle: L("以隨機資料覆寫後刪除。不經過垃圾桶，完成後無法復原。")) {
                Button(L("加入檔案或資料夾")) { pick() }
            }
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(L("Mac 的 SSD 和 APFS 檔案系統會把資料寫到新位置，所以無法保證舊資料被物理抹除，Time Machine 備份或 APFS 快照也可能留有副本。保護敏感資料最可靠的方式是開啟 FileVault。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            if model.isScanning {
                ScanProgress(status: model.status)
            } else if model.queue.isEmpty {
                ContentUnavailableView(L("把檔案拖到這裡"), systemImage: "scissors", description: Text(L("或按右上角的按鈕加入。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(isTargeted ? Color.accentColor.opacity(0.1) : .clear)
            } else {
                List(model.queue, id: \.self) { url in
                    HStack(spacing: 10) {
                        FileIcon(url: url)
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(displayPath(url)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            model.queue.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("從清單移除 %@", url.lastPathComponent))
                    }
                }
            }

            HStack(spacing: 12) {
                Picker(L("覆寫次數"), selection: $model.passes) {
                    Text(L("1 次（建議）")).tag(1)
                    Text(L("3 次")).tag(3)
                }
                .fixedSize()
                Spacer()
                Button(L("永久粉碎 %@ 個項目", model.queue.count), role: .destructive) { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.queue.isEmpty || model.isScanning)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.add(files)
            return !files.isEmpty
        } isTargeted: { isTargeted = $0 }
        .alert(L("要永久粉碎 %@ 個項目嗎？", model.queue.count), isPresented: $confirm) {
            Button(L("永久粉碎"), role: .destructive) { model.shred() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            let names = model.queue.prefix(5).map(\.lastPathComponent).joined(separator: "\n")
            Text(L("%@%@\n\n這個動作無法復原，資料夾內的所有內容也會一併粉碎。", names, model.queue.count > 5 ? "\n⋯" : ""))
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("加入")
        if panel.runModal() == .OK { model.add(panel.urls) }
    }
}
