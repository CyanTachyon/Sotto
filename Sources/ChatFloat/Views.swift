import SwiftUI
import AppKit
import ChatCore

private typealias UIState<Value> = SwiftUI.State<Value>

private struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(enabled ? AppTheme.onAccent : AppTheme.textSecondary)
            .background(enabled ? AppTheme.accent : AppTheme.hoverSurface, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct FloatView: View {
    @ObservedObject var model: AppModel
    var onConversationPickerChange: (Bool) -> Void = { _ in }
    @UIState private var followOutput = true
    @UIState private var userScrolling = false
    @UIState private var selectingConversation = false
    @UIState private var composerFocusRequest = 0
    private var followingConfirmed: Bool { model.followState == "confirmed" }
    private var savedImports: [ChatSession] { model.sessions.filter { $0.origin != .demo } }
    private var canSend: Bool { model.canAsk && !model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var composerContext: MessageComposerContext {
        model.live ? .database(account: model.root, conversation: model.groupID) : .imported(model.current?.id)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        target
                        if model.current != nil || model.selectedGroup != nil { rangeControls }
                        if model.current == nil && model.selectedGroup == nil { welcome }
                        if model.turns.isEmpty && model.canAsk { starters }
                        ForEach(model.turns) { turn in answer(turn) }
                        if model.busy && !model.pendingQuestion.isEmpty { questionBubble(model.pendingQuestion) }
                        if !model.streamingText.isEmpty {
                            SurfaceCard { MarkdownView(text: model.streamingText) }
                        }
                        if model.busy {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(model.phase).font(.callout)
                                Spacer()
                                Button("停止", action: model.cancel)
                            }.padding(12).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if !model.error.isEmpty {
                            Label { Text(verbatim: model.error).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.circle") }
                                .font(.callout).foregroundStyle(AppTheme.error).padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppTheme.errorBackground, in: RoundedRectangle(cornerRadius: 10))
                        }
                        Color.clear.frame(height: 1).id("response-bottom")
                    }.padding(16)
                }
                .modifier(ResponseScrollTracking(followOutput: $followOutput, userScrolling: $userScrolling))
                .onChange(of: model.streamingRevision) { _, _ in if followOutput { scroll.scrollTo("response-bottom", anchor: .bottom) } }
                .onChange(of: model.turns.count) { _, _ in if followOutput { scroll.scrollTo("response-bottom", anchor: .bottom) } }
                .onChange(of: model.busy) { _, busy in if busy { followOutput = true } }
                .overlay(alignment: .bottomTrailing) {
                    if model.busy && !followOutput {
                        Button("回到最新回答") { followOutput = true; scroll.scrollTo("response-bottom", anchor: .bottom) }
                            .buttonStyle(PrimaryActionStyle()).controlSize(.small).padding(12)
                    }
                }
            }
            Divider()
            composer
        }
        .background(AppTheme.canvas).foregroundStyle(AppTheme.textPrimary).tint(AppTheme.accent)
        .frame(minWidth: 360, minHeight: 460)
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill").foregroundStyle(AppTheme.accent)
            Text("微信伴读").font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                model.startNewConversation()
                composerFocusRequest += 1
            } label: { Label("新对话", systemImage: "square.and.pencil") }
                .buttonStyle(.borderless).font(.callout)
                .disabled(!model.canStartNewConversation)
                .help("清空当前伴读回答和上下文，开始新对话；微信记录不受影响。")
                .accessibilityLabel("新对话")
            if model.companionExpanded {
                Button { model.companionExpanded = false } label: { Label("收起", systemImage: "chevron.down") }
                    .buttonStyle(.borderless).help("收起到气泡，保留当前回答").accessibilityLabel("收起到微信气泡")
            }
            Menu {
                Button("微信连接…") { model.showConnection = true }
                Button("导入聊天记录…", action: model.importFile)
                if !savedImports.isEmpty {
                    Divider()
                    ForEach(savedImports) { session in Button(session.name + " · " + Display.date(session.createdAt)) { model.select(session) } }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("更多选项").accessibilityLabel("更多选项")
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("外观与设置").accessibilityLabel("外观与设置")
        }.padding(.horizontal, 16).padding(.vertical, 12).background(AppTheme.toolbar)
    }
    private var target: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(model.current?.origin == .demo ? "示例聊天 · 虚构内容" : model.live ? "当前会话" : "聊天记录")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Spacer()
                if !model.groups.isEmpty {
                    Toggle("自动跟随", isOn: $model.autoFollow).toggleStyle(.switch).controlSize(.mini)
                        .onChange(of: model.autoFollow) { _, _ in model.followChanged() }
                }
            }
            if model.live && !model.groups.isEmpty {
                Button { selectingConversation = true } label: {
                    HStack {
                        Image(systemName: model.selectedGroup?.isGroup == false ? "person.crop.circle" : "person.2")
                            .foregroundStyle(AppTheme.accent)
                        Text(model.autoFollow && !followingConfirmed ? "请选择当前会话" : model.selectedGroup?.name ?? "选择会话")
                            .font(.system(size: 17, weight: .semibold)).lineLimit(2)
                        Spacer(); Image(systemName: "chevron.down").font(.caption).foregroundStyle(AppTheme.textSecondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else if model.current != nil {
                Text(model.current?.name ?? "聊天记录").font(.system(size: 17, weight: .semibold)).lineLimit(2)
            }
            if model.current != nil || !model.groups.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(model.autoFollow && !followingConfirmed ? AppTheme.warning : AppTheme.success)
                        .frame(width: 6, height: 6).padding(.top, 4)
                    Text(model.autoFollow && !followingConfirmed ? "尚未确认会话，已暂停发送" : model.autoFollow ? "已跟随微信窗口" : model.selectedGroup == nil && model.current == nil ? "连接已就绪，请选择会话" : "固定使用此会话，切换微信不会改变这里")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                }
            }
            if model.autoFollow && !followingConfirmed && !model.groups.isEmpty {
                Text("请在微信中将聊天「在独立窗口中打开」，再点击伴读气泡。主窗口内切换会话暂时需要手动选择。")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary).lineSpacing(3)
                Button("选择会话") { selectingConversation = true }.font(.callout)
                DisclosureGroup("跟随状态") {
                    Text(model.followMessage.isEmpty ? model.identity : model.followMessage).font(.caption).textSelection(.enabled)
                }.font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
        }.popover(isPresented: $selectingConversation) {
            ConversationPicker(model: model) { selectingConversation = false }
                .onDisappear { onConversationPickerChange(false) }
        }
        .onChange(of: selectingConversation) { _, presented in onConversationPickerChange(presented) }
    }
    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("阅读范围", selection: $model.range) {
                    ForEach(AppModel.timePresets, id: \.0) { item in Text(item.1).tag(item.0) }
                }.pickerStyle(.menu).disabled(model.frozenSnapshot != nil || model.busy)
                if model.frozenSnapshot != nil { Button("更新记录", action: model.resetQuestion).controlSize(.small).disabled(model.busy) }
            }
            if model.range == 0 {
                DatePicker("从", selection: $model.start, displayedComponents: [.date, .hourAndMinute]).disabled(model.frozenSnapshot != nil || model.busy)
                DatePicker("到", selection: $model.end, displayedComponents: [.date, .hourAndMinute]).disabled(model.frozenSnapshot != nil || model.busy)
            }
            if let frozen = model.frozenSnapshot {
                Text("本次参考 \(frozen.messages.count) 条记录 · 追问沿用相同记录").font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
            if let session = model.current {
                DisclosureGroup("查看参考记录") { coverage(session) }.font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
    private func coverage(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: session.coverageLabel).lineSpacing(3)
            Button("查看 \(model.displayedMessages.count) 条原文") { model.showSources = true }.buttonStyle(.link)
            if let frozen = model.frozenSnapshot {
                Text("\(Display.date(frozen.window.start)) — \(Display.date(frozen.window.end))")
                if !model.imageSummary.isEmpty { Text(model.imageSummary) }
                DisclosureGroup("容量信息") {
                    Text("文本 \(frozen.textBytes / 1024) KB · 约 \(frozen.estimatedTokens) tokens，设置容量 \(model.config.contextTokens)。仅作参考，实际限制由模型服务决定。")
                }
            }
            if session.unknownCount > 0 {
                Toggle("附加 \(session.unknownCount) 条时间未知文字", isOn: $model.includeUnknown).disabled(model.frozenSnapshot != nil)
            }
        }.font(.caption).padding(.top, 8)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "text.bubble").font(.system(size: 32, weight: .light)).foregroundStyle(AppTheme.accent)
            Text(model.hasDatabaseConnection ? (model.groups.isEmpty ? "已连接，暂无会话" : "从一段聊天开始") : "一会儿没看，\n也能接上聊天。")
                .font(.system(size: 23, weight: .medium)).lineSpacing(5)
            Text(model.hasDatabaseConnection ? (model.groups.isEmpty ? "暂时没有读到可用会话。请确认微信已经同步记录，再到连接设置重新检测；也可以导入聊天文件。" : "选择一个群聊或联系人，看看发生了什么、有哪些结论和待办。") : "帮你整理群聊和私聊的重点。回答附有原消息，方便随时核对。")
                .font(.callout).foregroundStyle(AppTheme.textSecondary).lineSpacing(4)
            if model.connecting || model.detecting {
                HStack { ProgressView().controlSize(.small); Text("正在连接微信…").font(.callout) }
            } else if model.hasDatabaseConnection && model.groups.isEmpty {
                HStack {
                    Button("检查连接") { model.showConnection = true }.buttonStyle(PrimaryActionStyle())
                    Button("导入记录", action: model.importFile)
                }
            } else if model.hasDatabaseConnection {
                Button("选择会话") { selectingConversation = true }.buttonStyle(PrimaryActionStyle())
            } else {
                Button("连接微信") { model.showConnection = true }.buttonStyle(PrimaryActionStyle())
            }
            if !model.hasDatabaseConnection {
                Button("导入记录", action: model.importFile).buttonStyle(.borderless).font(.callout)
            }
            Text("只有提问时，才会将所选记录发送给你配置的 AI 服务。")
                .font(.caption).foregroundStyle(AppTheme.textSecondary).lineSpacing(3)
        }.padding(.vertical, 8)
    }
    private var starters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("试着问问").font(.caption).foregroundStyle(AppTheme.textSecondary)
            ForEach(["这段聊天发生了什么？", "有哪些结论和待办？", "谁提出了哪些事情？"], id: \.self) { text in
                Button { model.question = text } label: {
                    HStack { Text(text); Spacer(); Image(systemName: "arrow.up.left").foregroundStyle(AppTheme.textSecondary) }.padding(11)
                }.buttonStyle(.plain).font(.callout).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private func questionBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 32)
            Text(verbatim: text).font(.system(size: 14)).textSelection(.enabled).padding(12)
                .foregroundStyle(AppTheme.questionText).background(AppTheme.questionBubble, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func answer(_ turn: AnswerTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            questionBubble(turn.question)
            Label("伴读 · \(turn.snapshot.sessionName)", systemImage: "sparkle").font(.caption).foregroundStyle(AppTheme.textSecondary)
            SurfaceCard {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(turn.answer.claims.enumerated()), id: \.offset) { _, claim in
                        VStack(alignment: .leading, spacing: 8) {
                            if let title = claim.title { Text(verbatim: title).font(.system(size: 15, weight: .semibold)) }
                            MarkdownView(text: claim.text)
                            if !claim.references.isEmpty {
                                Button {
                                    model.evidenceSelection = nil
                                    model.evidenceMessages = claim.references.compactMap { turn.snapshot.referenceMap[$0.id] }
                                    model.showSources = true
                                } label: {
                                    Label("查看 \(claim.references.count) 条原消息", systemImage: "quote.bubble").font(.caption)
                                }.buttonStyle(.link).tint(AppTheme.link)
                            }
                        }
                    }
                }
            }
            if !turn.answer.insufficient.isEmpty { MarkdownView(text: turn.answer.insufficient).foregroundStyle(AppTheme.textSecondary) }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if model.question.isEmpty {
                    Text(model.turns.isEmpty ? "问问这段聊天…" : "继续追问…")
                        .foregroundStyle(AppTheme.textSecondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                }
                MessageComposer(text: $model.question, canSend: canSend, editable: true, contextID: composerContext,
                                focusRequest: composerFocusRequest, onSend: model.ask)
                    .frame(height: 58)
            }.padding(5).background(AppTheme.input, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border, lineWidth: 0.5))
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(composerHint).font(.caption2)
                    Text("Return 发送 · ⌘Return / ⇧Return 换行").font(.system(size: 10))
                    if !model.config.endpoint.isEmpty { Text(model.receiver).font(.system(size: 10)).lineLimit(1) }
                }.foregroundStyle(AppTheme.textSecondary)
                Spacer(minLength: 8)
                Button(action: model.ask) { Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)).frame(width: 20, height: 22) }
                    .buttonStyle(PrimaryActionStyle())
                    .accessibilityLabel(model.turns.isEmpty ? "发送问题" : "发送追问").help("发送问题（Return）；⌘Return 或 ⇧Return 换行")
                    .disabled(!canSend)
            }
        }.padding(14).background(AppTheme.toolbar)
    }
    private var composerHint: String {
        if model.busy { return model.phase }
        if model.autoFollow && !followingConfirmed && !model.groups.isEmpty { return "先确认当前会话，再提问" }
        if !model.canAsk { return model.hasDatabaseConnection ? "选择一个会话后即可提问" : "连接微信并选择会话，或导入记录" }
        return "仅发送所选会话与范围的记录"
    }
}

struct SourcesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("原消息").font(.title2.weight(.semibold)); Spacer(); Button("完成") { model.showSources = false } }
            Text("核对回答所参考的记录；这里只展示本次选择的范围。").font(.caption).foregroundStyle(AppTheme.textSecondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.evidenceMessages ?? model.evidenceSelection.map { [$0] } ?? model.displayedMessages) { message in
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(message.sender ?? "发言者未知").bold(); Spacer(); Text(message.timestamp.map(Display.date) ?? "时间未知").font(.caption).foregroundStyle(AppTheme.textSecondary) }
                                Text(verbatim: message.text).lineSpacing(4).textSelection(.enabled)
                                DisclosureGroup("来源详情") {
                                    Text(verbatim: message.source + " · 条目 \(message.sourceLine)").textSelection(.enabled)
                                }.font(.caption2).foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                    }
                }
            }
            if model.evidenceSelection != nil || model.evidenceMessages != nil { Button("查看本次全部原文") { model.evidenceSelection = nil; model.evidenceMessages = nil } }
        }.padding(20).frame(minWidth: 400, idealWidth: 500, maxWidth: .infinity, minHeight: 360, idealHeight: 540, maxHeight: .infinity)
            .background(AppTheme.canvas).foregroundStyle(AppTheme.textPrimary).tint(AppTheme.accent)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var appearance = AppAppearanceController.shared
    @UIState private var config = ModelConfig()
    @UIState private var key = ""
    @UIState private var consent = false
    @UIState private var status = ""
    @UIState private var testing = false
    @UIState private var editingService = false
    @UIState private var confirmDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("外观与设置").font(.title2.weight(.semibold)); Spacer(); Button("完成") { model.showSettings = false }.disabled(testing) }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    appearanceSection
                    serviceSection
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Label("微信连接", systemImage: "link").font(.headline); Spacer(); Button("管理连接") { model.showSettings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.showConnection = true } } }
                            Text("群聊和私聊都可使用。将聊天在微信中独立打开后，可按窗口标题自动跟随。主窗口内的会话请手动选择。")
                                .font(.caption).foregroundStyle(AppTheme.textSecondary).lineSpacing(3)
                        }
                    }
                    dataSection
                }.padding(20)
            }
        }.frame(minWidth: 440, idealWidth: 520, maxWidth: .infinity, minHeight: 360, idealHeight: 620, maxHeight: .infinity)
            .background(AppTheme.canvas).foregroundStyle(AppTheme.textPrimary).tint(AppTheme.accent)
            .onAppear { config = model.config; consent = config.consentEndpoint == config.endpoint && !config.endpoint.isEmpty; editingService = config.endpoint.isEmpty }
            .onChange(of: config.endpoint) { _, value in consent = model.config.consentEndpoint == value && !value.isEmpty }
            .alert("删除此服务的访问密钥？", isPresented: $confirmDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { do { try CredentialStore.delete(endpoint: model.config.endpoint); key = ""; status = "已保存服务的访问密钥已删除。" } catch { status = error.localizedDescription } }
            } message: { Text("将删除已保存服务「\(model.receiver)」的访问密钥。之后使用此服务时，需要重新填写。") }
    }
    private var appearanceSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("外观", systemImage: "circle.lefthalf.filled").font(.headline)
                Picker("外观", selection: $appearance.mode) { ForEach(AppAppearanceMode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().tint(AppTheme.nativeSelectionAccent)
                Text("默认跟随 Mac 的外观。微信也跟随系统时，两者会同步；若微信单独设为深色，可在这里选择深色。")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary).lineSpacing(3)
                Divider()
                Text("点击微信旁的气泡展开伴读；收起后保留回答。支持微信全屏桌面。")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
    private var serviceSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("AI 服务", systemImage: "sparkles").font(.headline)
                Text(config.endpoint.isEmpty ? "连接你选择的 AI 服务后，即可提问。" : "\(config.model) · \(model.receiver)")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary).textSelection(.enabled)
                DisclosureGroup("服务配置", isExpanded: $editingService) {
                    VStack(alignment: .leading, spacing: 12) {
                        labeledField("服务地址", hint: "填写服务提供的完整 Chat Completions 接口地址。") {
                            TextField("https://服务地址/v1/chat/completions", text: $config.endpoint)
                        }
                        labeledField("模型名称", hint: "填写服务提供的模型 ID。") { TextField("模型名称", text: $config.model) }
                        labeledField("访问密钥（API Key）", hint: "首次使用请填写服务提供的密钥；留空保留本机已保存的密钥。本机免密服务无需填写。") { SecureField("访问密钥", text: $key) }
                        Toggle("允许发送图片（需要模型支持）", isOn: $config.supportsVision)
                        DisclosureGroup("高级模型选项") {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("上下文容量（tokens）", value: $config.contextTokens, format: .number)
                                Stepper("每次图片预算：\(config.imageBudgetMB) MB", value: $config.imageBudgetMB, in: 1...100)
                                Text("容量仅作估算参考。图片最长边缩至 1536 像素，缺失或超出预算时会提示；其余文字照常处理。")
                                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                            }.padding(.top, 8)
                        }
                        Toggle("允许将所选记录、已开启的图片和问题发送到此服务", isOn: $consent)
                        Text("访问密钥保存在这台 Mac 的本地文件中，仅用于向此服务验证身份。不发送数据库密钥或完整数据库；服务可能保存请求，请选择你信任的服务。")
                            .font(.caption).foregroundStyle(AppTheme.textSecondary).lineSpacing(3)
                        HStack {
                            Button("保存配置") { Task { await save() } }.buttonStyle(PrimaryActionStyle())
                            Button(testing ? "测试中…" : "保存并测试（无聊天）", action: testConnection)
                        }
                    }.textFieldStyle(.roundedBorder).font(.callout).padding(.top, 10).disabled(testing)
                }
                if !status.isEmpty { Text(verbatim: status).font(.callout).foregroundStyle(AppTheme.textSecondary).textSelection(.enabled) }
            }
        }
    }
    private func labeledField<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.medium))
            content().accessibilityLabel(title)
            Text(hint).font(.caption).foregroundStyle(AppTheme.textSecondary)
        }
    }
    private var dataSection: some View {
        SurfaceCard {
            DisclosureGroup("数据与隐私") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("微信数据库正文和回答仅保留在当前进程内存，退出后清除。主动导入的记录缓存在本机，可在这里清理。")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                    Text("连接密钥和服务访问密钥以普通文件保存在本机，不额外加密。能读取当前 Mac 账户文件的程序也可能读取这些密钥。清理记录不会删除密钥。")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                    Button("清理本地记录和回答…", action: model.clearData)
                    Button("删除已保存服务的访问密钥…") { confirmDelete = true }.disabled(model.config.endpoint.isEmpty || testing)
                }.font(.callout).padding(.top, 10)
            }
        }
    }
    private func testConnection() {
        testing = true
        Task {
            guard await save() else { testing = false; return }
            do { try await ModelClient().probe(config: config, key: CredentialStore.readAsync(endpoint: config.endpoint)); status = "连接成功，未发送聊天记录。" }
            catch { status = error.localizedDescription }
            testing = false
        }
    }
    @discardableResult private func save() async -> Bool {
        do {
            config.endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
            config.consentEndpoint = consent ? config.endpoint : ""
            try await model.saveConfig(config, key: key); key = ""; status = "配置已保存。"; return true
        } catch { status = error.localizedDescription; return false }
    }
}

struct ConnectionView: View {
    @ObservedObject var model: AppModel
    @UIState private var acknowledge = false
    @UIState private var firstSetup = false
    @UIState private var confirmDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("微信连接").font(.title2.weight(.semibold)); Spacer(); Button("完成") { model.showConnection = false }.disabled(model.initializing) }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionStatus
                    if !model.hasDatabaseConnection && !model.error.isEmpty {
                        Text(verbatim: model.error).font(.callout).foregroundStyle(AppTheme.error).textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AppTheme.errorBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("自动跟随会话", systemImage: "rectangle.on.rectangle").font(.headline)
                            Text("请用微信自身的功能将聊天在独立窗口中打开。伴读会按窗口标题跟随，群聊和私聊都支持。无法确认时，可在伴读中选择会话。")
                                .font(.callout).foregroundStyle(AppTheme.textSecondary).lineSpacing(3)
                            if !AXIsProcessTrusted() {
                                Button("允许读取窗口标题", action: CurrentWeChat.requestPermission)
                                Text("需要辅助功能权限；这项功能不读取屏幕画面。")
                                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                    }
                    SurfaceCard {
                        DisclosureGroup("首次设置：准备连接密钥", isExpanded: Binding(get: { firstSetup || model.initializing }, set: { firstSetup = $0 })) {
                            initialization.padding(.top, 10)
                        }
                    }
                    SurfaceCard { advanced }
                }.padding(20)
            }
        }.frame(minWidth: 440, idealWidth: 560, maxWidth: .infinity, minHeight: 400, idealHeight: 600, maxHeight: .infinity)
            .background(AppTheme.canvas).foregroundStyle(AppTheme.textPrimary).tint(AppTheme.accent).interactiveDismissDisabled(model.initializing)
            .alert("删除此账号的连接密钥？", isPresented: $confirmDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { do { try model.removeDatabaseKeys() } catch { model.error = error.localizedDescription } }
            } message: { Text("删除后，伴读需要重新导入或获取密钥才能读取此账号的聊天。微信中的记录不受影响。") }
    }
    private var connectionStatus: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if model.connecting || model.detecting { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.hasDatabaseConnection ? "checkmark.circle.fill" : "link").foregroundStyle(model.hasDatabaseConnection ? AppTheme.success : AppTheme.accent).font(.title2) }
                    Text(statusTitle).font(.headline)
                }
                Text(statusDescription).font(.callout).foregroundStyle(AppTheme.textSecondary).lineSpacing(3)
                if model.discoveredAccounts.count > 1 {
                    Picker("本人账号", selection: Binding(get: { model.root }, set: { value in
                        if let account = model.discoveredAccounts.first(where: { $0.root.path == value }) { model.useDiscoveredAccount(account) }
                    })) {
                        Text("选择账号").tag("")
                        ForEach(model.discoveredAccounts) { account in Text(account.displayName).tag(account.root.path) }
                    }.disabled(model.initializing || model.connecting)
                }
                if !model.hasDatabaseConnection && !model.connecting && !model.detecting {
                    HStack {
                        if model.discoveryState == "permissionRequired" {
                            Button("打开完全磁盘访问", action: model.openDataPermissionSettings).buttonStyle(PrimaryActionStyle())
                            Button("授权后继续") { model.assistSetup(openPermissions: false) }
                        } else if model.root.isEmpty {
                            Button("查找并连接微信") { model.assistSetup() }.buttonStyle(PrimaryActionStyle())
                        } else {
                            Button("验证并连接") { model.connect() }.buttonStyle(PrimaryActionStyle())
                        }
                    }.disabled(model.initializing)
                }
                if !model.root.isEmpty && !model.hasDatabaseConnection && !model.messageQueryNeedsVerification {
                    Text("连接密钥保存在本机文件中，读取密钥不需要系统授权。尚未保存密钥时，请在下方导入或完成首次设置。")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }
    private var statusTitle: String {
        if model.initializing { return "正在完成首次设置" }
        if model.connecting || model.detecting { return "正在连接微信…" }
        if model.messageQueryNeedsVerification { return "聊天记录暂时无法读取" }
        if model.hasDatabaseConnection { return "微信已连接" }
        if model.discoveryState == "permissionRequired" { return "需要允许读取本机微信数据" }
        return "连接你的微信"
    }
    private var statusDescription: String {
        if model.messageQueryNeedsVerification { return "会话列表已连接，但聊天记录尚未读取成功。重新连接后，请重试刚才的问题。" }
        if model.hasDatabaseConnection { return "已找到 \(model.groups.count) 个有本地记录的会话。以后启动或回到伴读时会自动连接，无需重复验证。" }
        if model.discoveryState == "permissionRequired" { return "请在系统设置中为当前「群聊伴读」开启完全磁盘访问，然后继续。" }
        if model.connecting || model.detecting { return "正在检查本机数据和已有连接，请稍候。" }
        return "从这台 Mac 上读取你自己的聊天记录。已有连接会自动恢复；首次使用可先查找账号。"
    }
    private var initialization: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("仅在没有可用密钥时需要。已有连接无需重复进行。")
                .font(.callout.weight(.medium)).foregroundStyle(AppTheme.warning)
            Text("先由你在微信菜单正常退出。会创建、重新签名并启动一个临时微信副本，读取并验证你所选账号的数据库密钥。验证通过的密钥保存在这台 Mac 的本地文件中。")
            Text("原版微信与 SIP 保持不变。副本仍会访问本人账号资料，可能需要手机确认或重新登录，微信自身可能更新缓存或登录状态。此路线在本机 macOS 27 尚未实账号验证；调试许可不通过会失败，不自动降低系统安全设置。")
                .font(.caption).foregroundStyle(AppTheme.textSecondary)
            Toggle("我已正常退出微信，并同意本次创建、重签和启动临时副本取钥", isOn: $acknowledge)
            Button(model.initializing ? "正在初始化，请在临时微信完成本人登录…" : "开始一次性初始化", action: model.initializeKeys)
                .buttonStyle(PrimaryActionStyle()).disabled(!acknowledge || model.root.isEmpty || model.initializing || model.connecting)
            Text("最多等待 180 秒。期间不要在副本中聊天或编辑草稿。结束后自行打开 /Applications/WeChat.app，再点“验证并连接”。应用不替你退出或重启原版。")
                .font(.caption).foregroundStyle(AppTheme.textSecondary)
            if model.initializing { Text(verbatim: model.setupLog).font(.caption).textSelection(.enabled) }
        }.font(.callout).lineSpacing(3)
    }
    private var advanced: some View {
        DisclosureGroup("高级与诊断") {
            VStack(alignment: .leading, spacing: 12) {
                Text("本机适配：微信 4.1.15 · Apple Silicon").font(.caption).foregroundStyle(AppTheme.textSecondary)
                Text(verbatim: model.discoveryMessage).font(.caption).textSelection(.enabled)
                Button("重新检测账号") { model.assistSetup(openPermissions: false) }.disabled(model.initializing || model.detecting || model.connecting)
                Button("重新检查连接") { model.connect() }.disabled(model.root.isEmpty || model.connecting || model.initializing)
                Button("导入已有逐库密钥…", action: model.importKeys).disabled(model.root.isEmpty || model.initializing || model.connecting)
                Button("选择其他数据文件夹…", action: model.chooseRoot).disabled(model.initializing || model.connecting)
                if !model.root.isEmpty { Text(verbatim: model.root).font(.caption).foregroundStyle(AppTheme.textSecondary).textSelection(.enabled) }
                Button("辅助功能设置") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) } }
                if !model.setupLog.isEmpty {
                    DisclosureGroup("诊断记录") {
                        Text(verbatim: model.setupLog).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(AppTheme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Button("删除此账号的连接密钥…") { confirmDelete = true }.disabled(model.root.isEmpty || model.initializing || model.connecting)
            }.font(.callout).padding(.top, 10)
        }
    }
}
