/// Fallback parser for `brew list --versions` plain-text output.
/// One line per formula: name, then every installed version. Used when
/// the JSON path fails or omits rows (untrusted taps — compatibilities §43).
public func parseTextListVersions(_ text: String) -> [(name: String, versions: [String])] {
    var rows: [(name: String, versions: [String])] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let tokens = line.split(separator: " ")
        guard let name = tokens.first else { continue } // blank or whitespace-only line
        rows.append((name: String(name), versions: tokens.dropFirst().map(String.init)))
    }
    return rows
}
