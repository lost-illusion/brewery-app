import BreweryCore
import SwiftUI

/// Confirms the mutating `brew tap` before it runs: the sheet spells out the
/// exact repository brew will clone, because tap code runs with the user's
/// privileges (compat §7 trust model).
struct AddTapSheet: View {
    let model: InventoryModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var remote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a tap").font(.title2.bold())
            TextField("Tap name", text: $name, prompt: Text("user/repo"))
                .textFieldStyle(.roundedBorder)
            TextField("Custom git URL (optional)", text: $remote,
                      prompt: Text("https://example.com/user/homebrew-repo.git"))
                .textFieldStyle(.roundedBorder)

            GroupBox {
                Text(preview).font(.callout).textSelection(.enabled)
                Text("brew clones this repository; code in a tap runs with your user's privileges, and its packages are only installed if you ask for them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let problem = validationProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            switch model.tapAction {
            case .running(let action):
                Label(action.label, systemImage: "arrow.down.app").foregroundStyle(.tint)
            case .failed(_, let message):
                Label(message, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case .idle:
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add tap") {
                    Task {
                        await model.addTap(name: name, remote: remote)
                        // brew exited 0 → the tap list and inventory already
                        // reloaded behind this sheet; a failure stays open.
                        if model.tapAction == .idle { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.tapAction != .idle || validationProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var preview: String {
        guard case .success(let parts) = parseTapName(name) else { return "waiting for a tap name" }
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmed.isEmpty ? "https://github.com/\(parts.user)/homebrew-\(parts.repo)" : trimmed
        return "brew tap \(parts.user)/\(parts.repo) \(trimmed.isEmpty ? "" : target)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationProblem: String? {
        if case .failure(let problem) = parseTapName(name) {
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : problem.message
        }
        return validateTapRemote(remote)
    }
}
