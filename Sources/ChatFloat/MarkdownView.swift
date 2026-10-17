import SwiftUI
import AppKit
import ChatCore

struct MarkdownView: View {
    let text: String
    private func inline(_ text: String) -> Text {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            value[run.range].font = .system(size: 13, design: .monospaced)
            value[run.range].backgroundColor = AppTheme.inlineCodeBackground
        }
        return Text(value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let value): inline(value).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                case .heading(let level, let value): inline(value).font(.system(size: level == 1 ? 23 : level == 2 ? 19 : 16, weight: .semibold)).padding(.top, 5)
                case .rule: Rectangle().fill(AppTheme.separator).frame(height: 1).padding(.vertical, 4)
                case .quote(let value):
                    HStack(alignment: .top, spacing: 10) { RoundedRectangle(cornerRadius: 2).fill(AppTheme.quoteBar).frame(width: 3); inline(value).foregroundStyle(AppTheme.textSecondary).lineSpacing(4) }.fixedSize(horizontal: false, vertical: true)
                case .item(let marker, let value, let indent):
                    HStack(alignment: .top, spacing: 8) { Text(marker).foregroundStyle(AppTheme.textSecondary).frame(minWidth: 16, alignment: .trailing); inline(value).fixedSize(horizontal: false, vertical: true) }.padding(.leading, CGFloat(indent) * 12)
                case .code(let language, let value):
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(language.isEmpty ? "代码" : language).font(.caption).foregroundStyle(AppTheme.textSecondary); Spacer(); Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }.font(.caption).buttonStyle(.borderless) }
                        ScrollView(.horizontal) { Text(verbatim: value).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: true, vertical: true) }
                    }.padding(12).background(AppTheme.codeBackground, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border, lineWidth: 0.5))
                case .table(let headers, let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                            GridRow { ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in inline(cell).bold().frame(minWidth: 80, maxWidth: 230, alignment: .leading) } }
                            Rectangle().fill(AppTheme.separator).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in inline(cell).frame(minWidth: 80, maxWidth: 230, alignment: .leading) } }
                            }
                        }.padding(10)
                    }.background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border, lineWidth: 0.5))
                }
            }
        }.font(.system(size: 14)).foregroundStyle(AppTheme.textPrimary).tint(AppTheme.link)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded })
    }
}
