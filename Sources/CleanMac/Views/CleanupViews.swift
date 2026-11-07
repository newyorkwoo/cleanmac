import AppKit
import CleanMacCore
import ImageIO
import SwiftUI

// MARK: - Junk

struct JunkView: View {
    @Bindable var model: JunkModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("垃圾檔案"), subtitle: L("快取、記錄檔和各種殘留。風險較高的類別預設不勾選。")) {
                ScanButton(model: model) { model.scan() }
            }
            Divider()
            if model.isScanning {
                ScanProgress(status: model.status)
            } else if !model.hasScanned {
                ContentUnavailableView(L("尚未掃瞄"), systemImage: "trash.circle", description: Text(L("掃瞄只會計算大小，不會刪除任何檔案。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.categories.isEmpty {
                ContentUnavailableView(L("沒有找到垃圾檔案"), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.categories) { category in
                    JunkCategoryRow(category: category, selected: $model.selected)
                }
            }
            SelectionFooter(count: model.selectedItems.count, size: model.selectedSize, actionTitle: L("清理")) { confirm = true }
        }
        .alert(L("要清理 %@ 個項目（%@）嗎？", model.selectedItems.count, formatBytes(model.selectedSize)), isPresented: $confirm) {
            Button(L("清理"), role: .destructive) { model.clean() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text((model.selectionIncludesPermanent
                  ? L("其他項目會移到垃圾桶，但勾選的「垃圾桶」項目會永久刪除，無法復原。")
                  : L("項目會移到垃圾桶，清空前都可以救回。"))
                 + (model.selectedSystemCount > 0
                    ? "\n\n" + L("其中 %@ 個是系統項目：需要管理者密碼，相關背景服務也會停止，之後放回原位時同樣需要密碼。", model.selectedSystemCount)
                    : ""))
        }
    }
}

private struct JunkCategoryRow: View {
    let category: JunkCategory
    @Binding var selected: Set<String>
    @State private var expanded = false

    private var selectedCount: Int { category.items.filter { selected.contains($0.id) }.count }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(category.items) { item in
                HStack(spacing: 10) {
                    Toggle(L("選取 %@", item.name), isOn: Binding(
                        get: { selected.contains(item.id) },
                        set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if item.inUse {
                        Text(L("App 執行中")).font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer()
                    if item.isSystem {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .help(L("系統項目，需要管理者密碼"))
                            .accessibilityLabel(L("系統項目，需要管理者密碼"))
                    }
                    Text(formatBytes(item.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                .contextMenu { Button(L("在 Finder 中顯示")) { revealInFinder(item.url) } }
            }
        } label: {
            HStack(spacing: 10) {
                Toggle(L("選取%@", category.title), sources: category.items.map { item in
                    Binding(get: { selected.contains(item.id) },
                            set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })
                }, isOn: \.self)
                .labelsHidden()
                .toggleStyle(.checkbox)
                Image(systemName: category.symbol).frame(width: 22).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(category.title).fontWeight(.medium)
                        Text("\(category.items.count)").font(.caption).foregroundStyle(.secondary)
                        if category.permanent {
                            Text(L("無法復原")).font(.caption2).foregroundStyle(.red)
                        }
                    }
                    Text(category.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(formatBytes(category.size)).monospacedDigit()
            }
            .padding(.vertical, 3)
        }
    }
}

// MARK: - Large files

struct LargeFilesView: View {
    @Bindable var model: LargeFilesModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("大型檔案"), subtitle: L("找出占用空間最多的個人檔案。不含 App 資料與 Library，也不會預先勾選。")) {
                FolderChooser(url: model.root) { model.root = $0 }
                Picker(L("最小大小"), selection: $model.minimumMB) {
                    Text("50 MB").tag(50)
                    Text("100 MB").tag(100)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                }
                .labelsHidden()
                .fixedSize()
                ScanButton(model: model) { model.scan() }
            }
            Divider()
            if model.isScanning {
                ScanProgress(status: model.status)
            } else if !model.hasScanned {
                ContentUnavailableView(L("尚未掃瞄"), systemImage: "doc.badge.ellipsis")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.files.isEmpty {
                ContentUnavailableView(L("沒有超過 %@ MB 的檔案", model.minimumMB), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker(L("排序"), selection: $model.sortByDate) {
                    Text(L("由大到小")).tag(false)
                    Text(L("由舊到新")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(8)
                List(model.sortedFiles) { file in
                    FileRow(url: file.url, size: file.size, modified: file.modified, isOn: Binding(
                        get: { model.selected.contains(file.id) },
                        set: { if $0 { model.selected.insert(file.id) } else { model.selected.remove(file.id) } }
                    ))
                }
            }
            SelectionFooter(count: model.selected.count, size: model.selectedSize) { confirm = true }
        }
        .trashConfirmation(isPresented: $confirm, count: model.selected.count, size: model.selectedSize) { model.clean() }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @Bindable var model: DuplicatesModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("重複檔案"), subtitle: L("以內容比對（SHA-256），只有完全相同才算重複。每組至少會保留一份。")) {
                FolderChooser(url: model.root) { model.root = $0 }
                Picker(L("最小大小"), selection: $model.minimumMB) {
                    Text("1 MB").tag(1)
                    Text("10 MB").tag(10)
                    Text("100 MB").tag(100)
                }
                .labelsHidden()
                .fixedSize()
                ScanButton(model: model) { model.scan() }
            }
            Divider()
            if model.isScanning {
                ScanProgress(status: model.status)
            } else if !model.hasScanned {
                ContentUnavailableView(L("尚未掃瞄"), systemImage: "doc.on.doc", description: Text(L("存在雲端、尚未下載的檔案會略過。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.groups.isEmpty {
                ContentUnavailableView(L("沒有找到重複檔案"), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            FileRow(url: file.url, size: file.size, modified: file.modified, isOn: Binding(
                                get: { model.selected.contains(file.id) },
                                set: { if $0 { model.selected.insert(file.id) } else { model.selected.remove(file.id) } }
                            ), isEnabled: model.canSelect(file, in: group))
                        }
                    } header: {
                        Text(L("%@ 份相同檔案，可釋放 %@", group.files.count, formatBytes(group.reclaimable)))
                    }
                }
            }
            SelectionFooter(count: model.selected.count, size: model.selectedSize, action: { confirm = true }) {
                Button(L("自動勾選（每組保留最舊的一份）")) { model.autoSelect() }
                    .disabled(model.groups.isEmpty)
                Button(L("全部取消")) { model.selected = [] }
                    .disabled(model.selected.isEmpty)
            }
        }
        .trashConfirmation(isPresented: $confirm, count: model.selected.count, size: model.selectedSize,
                           detail: L("每組都會保留未勾選的檔案。若專案或 App 依賴被移除的檔案，可從垃圾桶救回。")) { model.clean() }
    }
}

// MARK: - Photos

struct PhotosView: View {
    @Bindable var model: PhotosModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("相似照片"), subtitle: L("用裝置端影像分析找出近乎相同的照片，資料不會上傳。「照片」App 的圖庫不會被掃瞄，請在「照片」中管理。")) {
                FolderChooser(url: model.root) { model.root = $0 }
                ScanButton(model: model) { model.scan() }
            }
            Divider()
            if model.isScanning {
                ScanProgress(status: model.status)
            } else if !model.hasScanned {
                ContentUnavailableView(L("尚未掃瞄"), systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.groups.isEmpty {
                ContentUnavailableView(L("沒有找到相似照片"), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(model.groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("%@ 張相似照片，可釋放 %@", group.photos.count, formatBytes(group.reclaimable)))
                                    .font(.headline)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                                    ForEach(group.photos) { photo in
                                        PhotoTile(photo: photo, isBest: photo.id == group.photos.first?.id,
                                                  isSelected: model.selected.contains(photo.id)) {
                                            model.toggle(photo, in: group)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            SelectionFooter(count: model.selected.count, size: model.selectedSize, action: { confirm = true }) {
                Button(L("自動勾選（每組保留最佳的一張）")) { model.autoSelect() }
                    .disabled(model.groups.isEmpty)
                Button(L("全部取消")) { model.selected = [] }
                    .disabled(model.selected.isEmpty)
            }
        }
        .trashConfirmation(isPresented: $confirm, count: model.selected.count, size: model.selectedSize) { model.clean() }
    }
}

private struct PhotoTile: View {
    let photo: PhotoRecord
    let isBest: Bool
    let isSelected: Bool
    let toggle: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    .frame(width: 150, height: 112)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.red : .clear, lineWidth: 3)
                    }
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.red : .white)
                        .shadow(radius: 2)
                        .padding(6)
                }
                Text(photo.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                Text("\(photo.pixelWidth)×\(photo.pixelHeight) · \(formatBytes(photo.size))")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(isBest ? L("畫質最佳") : " ").font(.caption2).foregroundStyle(.green)
            }
            .frame(width: 150)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L("在 Finder 中顯示")) { revealInFinder(photo.url) }
            Button(L("開啟")) { NSWorkspace.shared.open(photo.url) }
        }
        .accessibilityLabel(L("%@%@", photo.url.lastPathComponent, isSelected ? L("，已選取") : ""))
        .task(id: photo.id) {
            let url = photo.url
            let cgImage: CGImage? = await offMain {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            if let cgImage { image = NSImage(cgImage: cgImage, size: .zero) }
        }
    }
}

// MARK: - Disk map

struct DiskMapView: View {
    @Bindable var model: DiskMapModel
    @State private var hovered: DiskNode?
    @State private var pendingTrash: DiskNode?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("磁碟地圖"), subtitle: L("方塊越大代表占用越多。點資料夾可以往下看，對右側清單按右鍵可以處理項目。")) {
                FolderChooser(url: model.root) { model.root = $0 }
                ScanButton(model: model) { model.scan() }
            }
            Divider()
            if model.isScanning {
                ScanProgress(status: model.status)
            } else if let current = model.current {
                breadcrumb(current)
                Divider()
                HSplitView {
                    TreemapView(node: current, revision: model.revision, hovered: $hovered) { model.current = $0 }
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    childList(current)
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                }
                HStack {
                    Text(hovered.map { L("%@：%@", $0.name, formatBytes($0.size)) } ?? L("將游標移到方塊上可查看名稱與大小"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
            } else {
                ContentUnavailableView(L("尚未掃瞄"), systemImage: "square.grid.3x3.square", description: Text(L("預設掃瞄家目錄，也可以選擇其他資料夾。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(L("要將「%@」移到垃圾桶嗎？", pendingTrash?.name ?? ""), isPresented: Binding(
            get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }
        )) {
            Button(L("移到垃圾桶"), role: .destructive) {
                if let pendingTrash { model.trash(pendingTrash) }
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("%@。清空垃圾桶前都可以救回。", formatBytes(pendingTrash?.size ?? 0)))
        }
    }

    private func breadcrumb(_ node: DiskNode) -> some View {
        var chain: [DiskNode] = []
        var cursor: DiskNode? = node
        while let current = cursor {
            chain.insert(current, at: 0)
            cursor = current.parent
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(chain) { item in
                    Button(item.name) { model.current = item }
                        .buttonStyle(.link)
                        .disabled(item === node)
                    if item !== node {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("· \(formatBytes(node.size))").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func childList(_ node: DiskNode) -> some View {
        let revision = model.revision
        return List(node.children.prefix(300)) { child in
            HStack(spacing: 8) {
                Image(systemName: child.isAggregate ? "ellipsis.circle" : (child.isDirectory ? "folder" : "doc"))
                    .foregroundStyle(.secondary)
                Text(child.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(formatBytes(child.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { if child.isDirectory { model.current = child } }
            .contextMenu {
                if !child.isAggregate {
                    Button(L("在 Finder 中顯示")) { revealInFinder(child.url) }
                    Button(L("移到垃圾桶⋯"), role: .destructive) { pendingTrash = child }
                }
            }
        }
        .id(revision)
    }
}

private struct TreemapView: View {
    let node: DiskNode
    let revision: Int
    @Binding var hovered: DiskNode?
    let open: (DiskNode) -> Void

    private static let palette: [Color] = [
        Color(red: 0.16, green: 0.42, blue: 0.75), Color(red: 0.11, green: 0.52, blue: 0.51),
        Color(red: 0.42, green: 0.33, blue: 0.72), Color(red: 0.70, green: 0.36, blue: 0.20),
        Color(red: 0.25, green: 0.50, blue: 0.27), Color(red: 0.66, green: 0.27, blue: 0.47),
    ]

    var body: some View {
        GeometryReader { geometry in
            let children = Array(node.children.filter { $0.size > 0 }.prefix(250))
            let rects = Treemap.layout(sizes: children.map { Double($0.size) },
                                       in: CGRect(origin: .zero, size: geometry.size))
            Canvas { context, _ in
                for (index, child) in children.enumerated() {
                    let rect = rects[index].insetBy(dx: 1, dy: 1)
                    guard rect.width > 0, rect.height > 0 else { continue }
                    let shape = Path(roundedRect: rect, cornerRadius: min(4, min(rect.width, rect.height) / 3))
                    let color = child.isAggregate ? Color.gray : Self.palette[index % Self.palette.count]
                    context.fill(shape, with: .color(child === hovered ? color.opacity(0.75) : color))
                    guard rect.width > 56, rect.height > 34 else { continue }
                    let label = Text("\(child.name)\n\(formatBytes(child.size))")
                        .font(.caption)
                        .foregroundColor(.white)
                    context.draw(label, in: rect.insetBy(dx: 6, dy: 5))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovered = rects.firstIndex { $0.contains(point) }.map { children[$0] }
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture { point in
                if let index = rects.firstIndex(where: { $0.contains(point) }), children[index].isDirectory {
                    open(children[index])
                }
            }
            .accessibilityLabel(L("%@ 的磁碟用量圖", node.name))
        }
        .padding(8)
        .id(revision)
    }
}
