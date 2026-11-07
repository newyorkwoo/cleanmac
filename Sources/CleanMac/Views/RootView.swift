import CleanMacCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmEmptyTrash = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            Divider()
            VStack(spacing: 0) {
                if !model.hasFullDiskAccess { FullDiskAccessBanner() }
                if let banner = model.banner {
                    ResultBannerView(banner: banner, confirmEmptyTrash: $confirmEmptyTrash)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 10)
        }
        // Rebuilding the tree re-reads every translated string after a language change.
        .id(model.language)
        // The layout is explicit, so it does not depend on title bar safe areas.
        .ignoresSafeArea(.container, edges: .top)
        .alert(L("要清空垃圾桶嗎？"), isPresented: $confirmEmptyTrash) {
            Button(L("清空垃圾桶"), role: .destructive) { model.emptyTrash() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("垃圾桶中的所有項目（包含你先前自己丟進去的）都會永久刪除，無法復原。"))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .dashboard: DashboardView()
        case .junk: JunkView(model: model.junk)
        case .large: LargeFilesView(model: model.large)
        case .duplicates: DuplicatesView(model: model.duplicates)
        case .photos: PhotosView(model: model.photos)
        case .diskMap: DiskMapView(model: model.diskMap)
        case .memory: MemoryView(model: model.memory)
        case .startup: StartupView(model: model.startup)
        case .apps: AppsView(model: model.apps)
        case .security: SecurityView(model: model.security)
        case .shredder: ShredderView(model: model.shredder)
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private let sections: [(String, [Page])] = [
        (L("總覽"), [.dashboard]),
        (L("清理"), [.junk, .large, .duplicates, .photos, .diskMap]),
        (L("優化"), [.memory, .startup, .apps]),
        (L("保護"), [.security, .shredder]),
    ]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.0) { section in
                    Text(section.0)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                    ForEach(section.1) { page in
                        row(page)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 40) // clears the window buttons
            .padding(.bottom, 12)
        }
            Divider()
            Picker(selection: $model.language) {
                ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
            } label: {
                Image(systemName: "globe")
            }
            .accessibilityLabel(L("語言"))
            .padding(10)
        }
        .frame(width: 190)
        .background(.regularMaterial)
    }

    private func row(_ page: Page) -> some View {
        let isSelected = model.page == page
        return Button {
            model.page = page
        } label: {
            Label {
                Text(page.title)
            } icon: {
                Image(systemName: page.symbol).frame(width: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text(L("尚未取得「完整磁碟取用權限」。部分位置（如垃圾桶、其他 App 的資料）會無法掃瞄，macOS 也可能多次跳出權限詢問。"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L("開啟設定")) { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") }
            Button(L("重新檢查")) { model.hasFullDiskAccess = hasFullDiskAccess() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }
}

private struct ResultBannerView: View {
    @Environment(AppModel.self) private var model
    let banner: ResultBanner
    @Binding var confirmEmptyTrash: Bool
    @State private var showFailures = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .red : .green)
            Text(banner.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !banner.failures.isEmpty {
                Button(L("%@ 個項目失敗", banner.failures.count)) { showFailures = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showFailures) { failureList }
            }
            Spacer()
            if banner.offerEmptyTrash {
                Button(L("清空垃圾桶")) { confirmEmptyTrash = true }
            }
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("關閉訊息"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background((banner.isError ? Color.red : Color.green).opacity(0.1))
    }

    private var failureList: some View {
        List(banner.failures) { failure in
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.path).font(.caption).lineLimit(2).truncationMode(.middle)
                Text(failure.message).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 460, height: 260)
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let memory = model.memory
        VStack(alignment: .leading, spacing: 10) {
            row(L("記憶體"), L("%@%%（壓力：%@）", Int(memory.snapshot.usedFraction * 100), memory.snapshot.pressure.title))
            row("CPU", "\(Int(memory.cpu * 100))%")
            row(L("磁碟可用"), formatBytes(memory.disk.available))
            Divider()
            Button(L("開啟 CleanMac")) {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(L("結束")) { NSApp.terminate(nil) }
        }
        .id(model.language)
        .padding(14)
        .frame(width: 260)
        .task {
            while !Task.isCancelled {
                await memory.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
