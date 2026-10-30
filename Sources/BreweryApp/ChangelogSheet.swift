import AppKit
import BreweryCore
import SwiftUI

/// One upstream GitHub release's notes in a modal (§21). The body is split
/// into blocks by BreweryCore (heading/bullet/paragraph/code) and each block's
/// text goes through inline-only markdown, so GitHub's block syntax never
/// reaches the inline parser. Bodies heavy in raw HTML stay ugly — the
/// "Open on GitHub" button is the escape hatch.
struct ChangelogSheet: View {
    let release: UpstreamRelease
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let blocks = parseChangelogBlocks(release.bodyText ?? "")
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(blocks) { block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            Divider()
                .padding(.top, 10)
            HStack {
                if let url = release.webURL {
                    Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 460)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(release.tag).font(.title3.bold())
            if release.isPrerelease {
                Text("pre-release")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let title = release.title, title.distinctFrom(release.tag) {
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let date = release.publishedAt {
                Text(date, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func blockView(_ block: ChangelogBlock) -> some View {
        switch block.kind {
        case .heading:
            Text(inline(block.text))
                .font(headingFont(block.level))
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(block.marker)
                    .foregroundStyle(.secondary)
                Text(inline(block.text))
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(block.level) * 16)
        case .code:
            Text(block.text)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .clipShape(.rect(cornerRadius: 6))
        case .paragraph:
            Text(inline(block.text))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.bold()
        case 2: return .headline.bold()
        default: return .callout.bold()
        }
    }

    /// Inline markdown only; a parse failure (malformed syntax) renders raw.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
