import SwiftUI
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ConversationPicker: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @ViewState private var query = ""
    @ViewState private var kind = 0
    @ViewState private var hoveredID: String?
    private var matches: [DBGroup] {
        model.groups.filter { item in
            (kind == 0 || (kind == 1) == item.isGroup) && (query.isEmpty || ([item.name, item.id] + item.aliases).contains { $0.localizedStandardContains(query) })
        }
    }
    var body: some View {
        let nameCounts = Dictionary(model.groups.map { ($0.name, 1) }, uniquingKeysWith: +)
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("选择会话").font(.headline); Spacer(); Button("完成", action: close).buttonStyle(.borderless) }
            TextField("搜索名称或备注", text: $query).textFieldStyle(.roundedBorder)
            Picker("类型", selection: $kind) { Text("全部").tag(0); Text("群聊").tag(1); Text("私聊").tag(2) }
                .pickerStyle(.segmented).tint(AppTheme.nativeSelectionAccent)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(matches) { item in
                        Button {
                            model.selectGroup(item.id); close()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.isGroup ? "person.2" : "person").frame(width: 22)
                                    .foregroundStyle(item.id == model.groupID ? AppTheme.accent : AppTheme.textSecondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).lineLimit(2)
                                    Text(item.kindLabel + (nameCounts[item.name, default: 0] > 1 ? " · " + String(item.id.suffix(12)) : ""))
                                        .font(.caption2).foregroundStyle(AppTheme.textSecondary)
                                }
                                Spacer()
                                if item.id == model.groupID { Image(systemName: "checkmark").foregroundStyle(AppTheme.accent) }
                            }.padding(9).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(item.id == model.groupID ? AppTheme.accentSoft : hoveredID == item.id ? AppTheme.hoverSurface : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .onHover { hovered in if hovered { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil } }
                            .accessibilityAddTraits(item.id == model.groupID ? .isSelected : [])
                    }
                    if matches.isEmpty { Text("没有匹配的会话").foregroundStyle(AppTheme.textSecondary).padding(20) }
                }
            }
            Text("仅显示本机有聊天记录的会话。手动选择后固定此会话。").font(.caption).foregroundStyle(AppTheme.textSecondary)
        }.padding(16).frame(width: 330, height: 400)
            .background(AppTheme.surface).foregroundStyle(AppTheme.textPrimary).tint(AppTheme.accent)
    }
}

struct ResponseScrollTracking: ViewModifier {
    @Binding var followOutput: Bool
    @Binding var userScrolling: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollPhaseChange { _, phase in userScrolling = phase == .interacting || phase == .decelerating }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 65
                } action: { _, nearBottom in if userScrolling { followOutput = nearBottom } }
        } else { content }
    }
}
