import SwiftUI
import UniformTypeIdentifiers

/// 目录行直接提供操作，选中详情用于查看完整路径。
struct AppDataDirectoryBrowser<Actions: View>: View {
    let groups: [DataDirGroup]
    let matchingItemIDs: Set<String>
    let isFiltering: Bool
    var showLockedStructure: Bool = false
    var revealRequest: DataDirTree.RevealRequest? = nil
    let actions: (DataDirItem) -> Actions

    @State private var selectedItemID: String?
    @State private var collapsedDirectoryIDs: Set<String> = []
    @State private var collapsedGroups: Set<DataDirType> = []
    @AppStorage("appDataDirectoryInformationPanelHeight") private var savedInformationPanelHeight = Double(DirectoryPanelLayout.minimumInformationHeight)
    @State private var informationResizeStartHeight: CGFloat?
    @State private var isInformationHandleHovered = false
    @FocusState private var isOutlineFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var informationPanelHeight: CGFloat {
        get { savedInformationPanelHeight.isFinite ? CGFloat(savedInformationPanelHeight) : DirectoryPanelLayout.minimumInformationHeight }
        nonmutating set { savedInformationPanelHeight = Double(newValue) }
    }

    private var allRows: [DataDirTree.Row] {
        groups.flatMap { DataDirTree.rows(in: $0.items) }
    }

    private var visibleRows: [DataDirTree.Row] {
        groups.filter { !collapsedGroups.contains($0.type) }
            .flatMap { DataDirTree.rows(in: $0.items, collapsedIDs: collapsedDirectoryIDs) }
    }

    private var selectedItem: DataDirItem? {
        allRows.first { $0.id == selectedItemID }?.item
    }

    private var isFullyExpanded: Bool {
        groups.allSatisfy { !collapsedGroups.contains($0.type) }
            && allRows.allSatisfy { $0.item.children.isEmpty || !collapsedDirectoryIDs.contains($0.id) }
    }

    private var outlineAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    var body: some View {
        GeometryReader { geometry in
            let panelHeight = clampedInformationHeight(informationPanelHeight, availableHeight: geometry.size.height)

            VStack(spacing: 0) {
                directoryOutline
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                informationResizeHandle(panelHeight: panelHeight, availableHeight: geometry.size.height)

                informationPanel(height: panelHeight)
                    .frame(height: panelHeight)
            }
            .coordinateSpace(name: "directoryInformationResize")
        }
        .frame(minHeight: DirectoryPanelLayout.minimumOutlineHeight + DirectoryPanelLayout.minimumInformationHeight + DirectoryPanelLayout.handleHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: isFiltering) { isFiltering in
            if isFiltering { expandAll() }
        }
        .onChange(of: showLockedStructure) { show in
            if show { expandAll() }
        }
        .onChange(of: matchingItemIDs) { _ in
            if selectedItem == nil { selectedItemID = nil }
        }
    }

    private func clampedInformationHeight(_ height: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let maximum = max(
            DirectoryPanelLayout.minimumInformationHeight,
            min(DirectoryPanelLayout.maximumInformationHeight,
                availableHeight - DirectoryPanelLayout.minimumOutlineHeight - DirectoryPanelLayout.handleHeight)
        )
        return min(max(height, DirectoryPanelLayout.minimumInformationHeight), maximum)
    }

    private func informationResizeHandle(panelHeight: CGFloat, availableHeight: CGFloat) -> some View {
        Capsule()
            .fill(Color.primary.opacity(isInformationHandleHovered || informationResizeStartHeight != nil ? 0.45 : 0.25))
            .frame(width: 32, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: DirectoryPanelLayout.handleHeight)
            .background(Color.primary.opacity(0.03))
            .contentShape(Rectangle())
            .onHover { hovering in
                isInformationHandleHovered = hovering
                if hovering { NSCursor.resizeUpDown.set() }
                else { NSCursor.arrow.set() }
            }
            .onDisappear {
                if isInformationHandleHovered { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("directoryInformationResize"))
                    .onChanged { value in
                        let startHeight = informationResizeStartHeight ?? panelHeight
                        informationResizeStartHeight = startHeight
                        informationPanelHeight = clampedInformationHeight(
                            startHeight - value.translation.height,
                            availableHeight: availableHeight
                        )
                    }
                    .onEnded { _ in informationResizeStartHeight = nil }
            )
            .help("调整信息栏高度".localized)
            .accessibilityElement()
            .accessibilityLabel("调整信息栏高度".localized)
            .accessibilityValue(Text(verbatim: String(Int(panelHeight))))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    informationPanelHeight = clampedInformationHeight(panelHeight + 20, availableHeight: availableHeight)
                case .decrement:
                    informationPanelHeight = clampedInformationHeight(panelHeight - 20, availableHeight: availableHeight)
                @unknown default: break
                }
            }
    }

    private var directoryOutline: some View {
        VStack(spacing: 0) {
            columnHeader

            ScrollViewReader { proxy in
                List(selection: $selectedItemID) {
                    ForEach(groups, id: \.type) { group in
                        Section {
                            if !collapsedGroups.contains(group.type) {
                                ForEach(DataDirTree.rows(in: group.items, collapsedIDs: collapsedDirectoryIDs)) { row in
                                    AppDataDirectoryRow(
                                        row: row,
                                        isExpanded: !collapsedDirectoryIDs.contains(row.id),
                                        isContext: !matchingItemIDs.contains(row.id),
                                        isSelected: selectedItemID == row.id,
                                        isOutlineFocused: isOutlineFocused,
                                        onToggle: { toggleDirectory(row.item) },
                                        actions: actions(row.item)
                                    )
                                    .tag(row.id)
                                    .id(row.id)
                                    .contextMenu {
                                        Button("在 Finder 中显示".localized) { reveal(row.item) }
                                        Button("复制路径".localized) { copyPath(row.item) }
                                    }
                                    .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
                                    .modifier(DirectorySeparatorVisibility())
                                }
                            }
                        } header: {
                            groupHeader(group)
                        }
                        .modifier(DirectorySeparatorVisibility())
                    }
                }
                .listStyle(.inset)
                .focused($isOutlineFocused)
                .modifier(DirectoryOutlineKeyboardNavigation { direction in
                    moveSelection(direction)
                    // Only keyboard navigation reveals off-screen rows, using the minimum scroll.
                    if let selectedItemID {
                        proxy.scrollTo(selectedItemID)
                    }
                })
                .task(id: revealRequest?.id) {
                    guard let request = revealRequest,
                          let plan = DataDirTree.revealPlan(in: groups.flatMap(\.items), matchingIDs: request.itemIDs) else { return }
                    collapsedGroups.subtract(plan.expandedGroups)
                    collapsedDirectoryIDs.subtract(plan.expandedDirectoryIDs)
                    selectedItemID = plan.selectedID
                    isOutlineFocused = true
                    // Allow the expanded rows to enter the List before requesting their position.
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(plan.selectedID, anchor: .center)
                }
                .onCopyCommand {
                    selectedItem.map { [NSItemProvider(object: $0.path.path as NSString)] } ?? []
                }
                .onChange(of: selectedItemID) { id in
                    if id != nil { isOutlineFocused = true }
                }
            }
        }
    }

    private func informationPanel(height: CGFloat) -> some View {
        Group {
            if let selectedItem {
                details(for: selectedItem, isCompact: height < 88)
            } else {
                Label("选择目录以查看完整路径".localized, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.03))
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Button {
                    if isFullyExpanded { collapseAll() }
                    else { expandAll() }
                } label: {
                    Label(
                        isFullyExpanded ? "折叠全部".localized : "展开全部".localized,
                        systemImage: isFullyExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
                    )
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isFullyExpanded ? "折叠全部".localized : "展开全部".localized)
                Text("名称".localized)
            }
            Spacer(minLength: 4)
            Text("大小".localized + " · " + "状态".localized)
                .frame(width: DirectoryRowColumns.metadataWidth, alignment: .trailing)
            Text("操作".localized)
                .frame(width: DirectoryRowColumns.actionsWidth, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.leading, 20)
        .padding(.trailing, 36)
        .padding(.vertical, 4)
    }

    private func groupHeader(_ group: DataDirGroup) -> some View {
        Button {
            withAnimation(outlineAnimation) {
                if collapsedGroups.contains(group.type) {
                    collapsedGroups.remove(group.type)
                } else {
                    collapsedGroups.insert(group.type)
                    if DataDirTree.rows(in: group.items).contains(where: { $0.id == selectedItemID }) {
                        selectedItemID = nil
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(collapsedGroups.contains(group.type) ? 0 : 90))
                    .frame(width: 16)
                Image(systemName: group.type.icon)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                Text(group.type.localizedTitle)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(verbatim: "(\(DataDirTree.rows(in: group.items).filter { matchingItemIDs.contains($0.id) }.count))")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsedGroups.contains(group.type) ? "展开目录".localized : "折叠目录".localized)
    }

    private func details(for item: DataDirItem, isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DataDirFolderIcon(pointSize: 22)
                Text(verbatim: isCompact ? item.path.path : item.path.lastPathComponent)
                    .font(.system(size: isCompact ? 11 : 14, weight: isCompact ? .regular : .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(item.path.path)
                if !isCompact {
                    PriorityBadge(priority: item.priority)
                }
                Spacer(minLength: 4)
                Button { reveal(item) } label: {
                    Label("在 Finder 中显示".localized, systemImage: "folder")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("在 Finder 中显示".localized)
                Button { copyPath(item) } label: {
                    Label("复制路径".localized, systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("复制路径".localized)
                Button { selectedItemID = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("关闭".localized)
                .accessibilityLabel("关闭".localized)
            }

            if !isCompact {
                detailContent(for: item)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isCompact ? 8 : 12)
    }

    private func detailContent(for item: DataDirItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                pathLine(item.path, label: "本地路径".localized)
                if let destination = item.linkedDestination, destination != item.path {
                    pathLine(destination, label: "链接目标".localized)
                }
                Text(item.sizeScopeExplanation)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if !item.isMigratable {
                    Label((item.nonMigratableReason ?? "此目录不支持迁移").localized, systemImage: "lock")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .id(item.id)
    }

    private func pathLine(_ url: URL, label: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize()
            Text(verbatim: url.path)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleDirectory(_ item: DataDirItem) {
        withAnimation(outlineAnimation) {
            if collapsedDirectoryIDs.contains(item.id) {
                collapsedDirectoryIDs.remove(item.id)
            } else {
                collapsedDirectoryIDs.insert(item.id)
                if let selectedItemID, selectedItemID.hasPrefix(item.id + "/") {
                    self.selectedItemID = item.id
                }
            }
        }
    }

    private func expandAll() {
        withAnimation(outlineAnimation) {
            collapsedGroups.removeAll()
            collapsedDirectoryIDs.removeAll()
        }
    }

    private func collapseAll() {
        withAnimation(outlineAnimation) {
            collapsedGroups = Set(groups.map(\.type))
            collapsedDirectoryIDs = Set(allRows.filter { !$0.item.children.isEmpty }.map(\.id))
            selectedItemID = nil
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        guard let index = rows.firstIndex(where: { $0.id == selectedItemID }) else {
            selectedItemID = rows[0].id
            return
        }
        let row = rows[index]
        switch direction {
        case .up: selectedItemID = rows[max(0, index - 1)].id
        case .down: selectedItemID = rows[min(rows.count - 1, index + 1)].id
        case .left:
            if !row.item.children.isEmpty && !collapsedDirectoryIDs.contains(row.id) {
                toggleDirectory(row.item)
            } else if let parentID = row.parentID {
                selectedItemID = parentID
            }
        case .right:
            if collapsedDirectoryIDs.contains(row.id) {
                toggleDirectory(row.item)
            } else if let child = row.item.children.first {
                selectedItemID = child.id
            }
        @unknown default: break
        }
    }

    private func reveal(_ item: DataDirItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.linkedDestination ?? item.path])
    }

    private func copyPath(_ item: DataDirItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path.path, forType: .string)
    }
}

private enum DirectoryRowColumns {
    static let metadataWidth: CGFloat = 90
    static let actionsWidth: CGFloat = 128
}

private enum DirectoryPanelLayout {
    static let minimumOutlineHeight: CGFloat = 160
    static let minimumInformationHeight: CGFloat = 48
    static let maximumInformationHeight: CGFloat = 480
    static let handleHeight: CGFloat = 12
}

private struct DataDirFolderIcon: View {
    let pointSize: CGFloat
    private static let folderIcon = NSWorkspace.shared.icon(for: UTType.folder)

    var body: some View {
        Image(nsImage: Self.folderIcon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: pointSize, height: pointSize)
            .accessibilityHidden(true)
    }
}

private struct AppDataDirectoryRow<Actions: View>: View {
    let row: DataDirTree.Row
    let isExpanded: Bool
    let isContext: Bool
    let isSelected: Bool
    let isOutlineFocused: Bool
    let onToggle: () -> Void
    let actions: Actions
    @Environment(\.controlActiveState) private var controlActiveState

    private var isEmphasized: Bool { isSelected && isOutlineFocused && controlActiveState == .key }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if row.item.children.isEmpty {
                    Color.clear.frame(width: 16, height: 28)
                } else {
                    Button(action: onToggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isEmphasized ? .white.opacity(0.85) : .secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 16, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "折叠目录".localized : "展开目录".localized)
                    .accessibilityLabel(isExpanded ? "折叠目录".localized : "展开目录".localized)
                }

                DataDirFolderIcon(pointSize: 26)
                    .opacity(isContext ? 0.55 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(verbatim: row.item.path.lastPathComponent)
                            .font(.system(size: 14))
                            .foregroundColor(isEmphasized ? .white : (isContext ? .secondary : .primary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !row.item.isMigratable {
                            Image(systemName: "lock")
                                .font(.system(size: 11))
                                .foregroundColor(isEmphasized ? .white.opacity(0.85) : .secondary)
                                .help((row.item.nonMigratableReason ?? "此目录不支持迁移").localized)
                        }
                    }
                    if let contextPath = row.contextPath {
                        Text(verbatim: contextPath)
                            .font(.system(size: 11))
                            .foregroundColor(isEmphasized ? .white.opacity(0.85) : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(row.level) * 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.item.path.path)

            VStack(alignment: .trailing, spacing: 3) {
                Text(row.item.sizeScopeLabel)
                    .font(.system(size: 10))
                    .foregroundColor(isEmphasized ? .white.opacity(0.85) : .secondary)
                    .help(row.item.sizeScopeExplanation)
                Text(row.item.size ?? "计算中...".localized)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(isEmphasized ? .white : (row.item.size == nil ? .secondary : .primary))
                DataDirStatusBadge(status: row.item.displayedStatus, isEmphasized: isEmphasized)
            }
            .frame(width: DirectoryRowColumns.metadataWidth, alignment: .trailing)

            HStack(spacing: 6) { actions }
                .frame(width: DirectoryRowColumns.actionsWidth, alignment: .trailing)
        }
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

private struct DirectorySeparatorVisibility: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
        } else {
            content
        }
    }
}

private struct DirectoryOutlineKeyboardNavigation: ViewModifier {
    let move: (MoveCommandDirection) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.leftArrow) {
                    move(.left)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    move(.right)
                    return .handled
                }
        } else {
            content.onMoveCommand(perform: move)
        }
    }
}
