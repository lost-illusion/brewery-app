import AppKit
import BreweryCore
import SwiftUI

/// Confirm sheet for "switch to <version>" rows (compat §27). Shows the exact
/// brew sequence the model will run and collects the one decision the model
/// cannot guess: which tap `brew extract` writes the old definition into.
/// The sheet dismisses immediately on confirm — progress and brew's own
/// refusals then live in the detail page's tapAction banner.
struct SwitchVersionSheet: View {
    let item: BrewItem
    let version: String
    let plan: VersionSwitchPlan
    let model: InventoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var destinationTap: String = ""

    private var candidates: [String] {
        if case .extractInstall(_, _, _, let taps, _) = plan { return taps }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch \(item.fullName) to \(version)?").font(.headline)
            Text(copy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if case .extractInstall = plan {
                Picker("Extract into tap:", selection: $destinationTap) {
                    ForEach(candidates, id: \.self) { tap in Text(tap).tag(tap) }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Switch") {
                    let tap = destinationTap.isEmpty ? (candidates.first ?? "") : destinationTap
                    Task { await model.switchFormulaVersion(item: item, version: version, destinationTap: tap) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidates.isEmpty || model.tapAction != .idle)
            }
        }
        .padding(16)
        .frame(minWidth: 400)
        .onAppear { if destinationTap.isEmpty { destinationTap = candidates.first ?? "" } }
    }

    /// Copy mirrors the plan's commands verbatim — the posture §26 established
    /// for uninstall: state exactly what brew will do, including the parts
    /// users dislike (the core clone, the source build).
    private var copy: String {
        var lines: [String] = []
        switch plan {
        case .relink(let rack, let unlinkRacks, let kegOnly):
            lines.append("Brew will run:")
            for rackName in unlinkRacks { lines.append("• brew unlink \(rackName)") }
            lines.append("• brew link \(kegOnly ? "--force " : "")\(rack)")
            lines.append("Relinks the installed \(version) keg — nothing is re-downloaded, and the other versions stay installed.")
        case .extractInstall(let sourceName, let v, let sourceTap, _, let needsClone):
            lines.append("Brew will run:")
            if needsClone {
                lines.append("• brew tap \(sourceTap) — \(sourceTap) is not cloned on this machine (API mode), and brew extract searches git history. Large one-time download.")
            }
            let versioned = versionedFormulaName(baseName: sourceName, version: v)
            lines.append("• brew extract --force --version=\(v) \(sourceName) <tap> — writes the old definition into the chosen tap as \(versioned).rb")
            lines.append("• brew unlink \(item.fullName) (the currently linked version)")
            lines.append("• brew install -y <tap>/\(versioned)")
            lines.append("The extracted definition has its bottle block stripped by brew extract itself — brew builds \(version) from source, which takes minutes and can fail on current macOS.")
            lines.append("The current version stays installed but unlinked, so switching back is an instant relink.")
        case .blocked(let reason):
            lines.append(reason)
        }
        return lines.joined(separator: "\n")
    }
}
