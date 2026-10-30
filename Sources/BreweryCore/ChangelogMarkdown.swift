import Foundation

// MARK: - Changelog markdown blocks (§21 release notes modal)

/// Block-level split of a GitHub release body for SwiftUI rendering. The GUI
/// styles each block (heading sizes, bullet rows, monospaced code) and hands
/// the block text to AttributedString for *inline* markdown only — GitHub's
/// block syntax never reaches the inline parser. HTML tags in some bodies
/// (details/img) pass through as text; "Open on GitHub" is the escape hatch.
public enum ChangelogBlockKind: String, Equatable, Sendable {
    case heading, bullet, paragraph, code
}

public struct ChangelogBlock: Identifiable, Equatable, Sendable {
    public let id: Int // index in the parsed array; the body is static per modal
    public let kind: ChangelogBlockKind
    public let text: String // markdown source of the block (code: fence stripped)
    public let level: Int // heading: 1-6 hashes; bullet: indent depth 0-2
    public let marker: String // bullet: "•" or the kept "3." numbering; "" otherwise
}

private let bulletMarkers: [Character] = ["-", "*", "+"]

public func parseChangelogBlocks(_ body: String) -> [ChangelogBlock] {
    var blocks: [ChangelogBlock] = []
    var paragraph: [String] = []
    var nextID = 0

    func append(_ kind: ChangelogBlockKind, _ text: String, level: Int = 0, marker: String = "") {
        guard !text.isEmpty else { return }
        blocks.append(ChangelogBlock(id: nextID, kind: kind, text: text, level: level, marker: marker))
        nextID += 1
    }
    func flushParagraph() {
        // GitHub renders a single newline inside a paragraph as a soft break;
        // joining with spaces matches that.
        append(.paragraph, paragraph.joined(separator: " "))
        paragraph = []
    }

    let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") {
            flushParagraph()
            var code: [String] = []
            i += 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
                code.append(lines[i])
                i += 1
            }
            append(.code, code.joined(separator: "\n"))
            continue
        }

        if trimmed.hasPrefix("#") {
            flushParagraph()
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            let text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            // "#text" without a space isn't an ATX heading — keep it as a paragraph.
            if hashes <= 6, hashes > 0, trimmed.dropFirst(hashes).first == " ", !text.isEmpty {
                append(.heading, text, level: hashes)
                i += 1
                continue
            }
        }

        if trimmed.isEmpty {
            flushParagraph()
            i += 1
            continue
        }

        // List items: indent (2 spaces per depth, capped) + bullet marker or
        // "N." / "N)" numbering. Continuation lines of a multi-line item merge
        // into the item, matching GitHub's lazy list continuation.
        let indent = line.prefix(while: { $0 == " " }).count
        if let item = stripListMarker(trimmed) {
            flushParagraph()
            var text = item.text
            var j = i + 1
            while j < lines.count {
                let cont = lines[j].trimmingCharacters(in: .whitespaces)
                if cont.isEmpty || cont.hasPrefix("```") || cont.hasPrefix("#") || stripListMarker(cont) != nil { break }
                text += " " + cont
                j += 1
            }
            append(.bullet, text, level: min(indent / 2, 2), marker: item.marker)
            i = j
            continue
        }

        paragraph.append(trimmed)
        i += 1
    }
    flushParagraph()
    return blocks
}

/// "- item", "* item", "+ item" → marker "•"; "3. item" / "3) item" → marker "3.".
private func stripListMarker(_ trimmed: String) -> (marker: String, text: String)? {
    if let first = trimmed.first, bulletMarkers.contains(first), trimmed.dropFirst().first == " " {
        let text = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : ("•", text)
    }
    // CommonMark needs whitespace after the delimiter: "1.25.0 is out" is a
    // paragraph, not item "1." with text "25.0 is out".
    let digits = trimmed.prefix(while: \.isNumber)
    guard !digits.isEmpty, let sep = trimmed.dropFirst(digits.count).first, sep == "." || sep == ")",
          trimmed.dropFirst(digits.count + 1).first == " " else { return nil }
    let text = trimmed.dropFirst(digits.count + 1).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return ("\(digits).", text)
}
