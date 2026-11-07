import AppKit
import CleanMacCore
import SwiftUI

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

func openSettings(_ link: String) {
    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
}

@MainActor
func chooseFolder(startingAt url: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = url
    panel.prompt = L("選擇")
    return panel.runModal() == .OK ? panel.url : nil
}

func dateText(_ date: Date?) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter()
    formatter.locale = AppLanguage.current.locale
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}

/// Shows a path with the home folder abbreviated.
func displayPath(_ url: URL) -> String {
    (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Scan or stop button, with progress text while a scan runs.
struct ScanButton: View {
    let model: ScanModel
    var title = L("開始掃瞄")
    let action: () -> Void

    var body: some View {
        if model.isScanning {
            Button(L("停止"), role: .cancel) { model.cancel() }
        } else {
            Button(model.hasScanned ? L("重新掃瞄") : title, action: action)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ScanProgress: View {
    let status: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(status).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows the folder being scanned and lets the user change it.
struct FolderChooser: View {
    let url: URL
    let onChange: (URL) -> Void

    var body: some View {
        Button {
            if let picked = chooseFolder(startingAt: url) { onChange(picked) }
        } label: {
            Label(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, systemImage: "folder")
                .lineLimit(1)
        }
        .help(url.path)
    }
}

struct SelectionFooter<Extra: View>: View {
    let count: Int
    let size: Int64
    var actionTitle = L("移到垃圾桶")
    let action: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: 12) {
            Text(count > 0 ? L("已選取 %@ 個項目，共 %@", count, formatBytes(size)) : L("尚未選取項目"))
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            extra
            Spacer()
            Button(actionTitle, role: .destructive, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

extension SelectionFooter where Extra == EmptyView {
    init(count: Int, size: Int64, actionTitle: String = L("移到垃圾桶"), action: @escaping () -> Void) {
        self.init(count: count, size: size, actionTitle: actionTitle, action: action) { EmptyView() }
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
    }
}

struct FileRow: View {
    let url: URL
    let size: Int64
    var modified: Date?
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        HStack(spacing: 10) {
            Toggle(L("選取 %@", url.lastPathComponent), isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!isEnabled)
            FileIcon(url: url)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(displayPath(url)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let modified {
                Text(dateText(modified)).font(.caption).foregroundStyle(.secondary)
            }
            Text(formatBytes(size)).monospacedDigit().frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(L("在 Finder 中顯示")) { revealInFinder(url) }
            Button(L("開啟")) { NSWorkspace.shared.open(url) }
        }
    }
}

extension View {
    /// A confirmation for moving items to the Trash, stating what will happen.
    func trashConfirmation(
        isPresented: Binding<Bool>,
        count: Int,
        size: Int64,
        detail: String = L("項目會移到垃圾桶，清空前都可以救回。"),
        action: @escaping () -> Void
    ) -> some View {
        alert(L("要將 %@ 個項目（%@）移到垃圾桶嗎？", count, formatBytes(size)), isPresented: isPresented) {
            Button(L("移到垃圾桶"), role: .destructive, action: action)
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(detail)
        }
    }
}

struct Ring: View {
    let fraction: Double
    let color: Color
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: fraction)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            }
            .frame(width: 96, height: 96)
            Text(caption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption) \(value)")
    }
}
