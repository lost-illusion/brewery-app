import BreweryCore
import SwiftUI

/// Live progress for a long brew mutation or upgrade (design 2026-11-02 phase 2):
/// streamed `==>` lines as brew writes them, plus a Cancel that sends SIGINT —
/// brew traps INT and exits 130, the same path Ctrl-C takes in a terminal
/// (`brew.rb:22`). Fast actions never reach this sheet: ContentView presents it
/// only after the action has been running for a beat.
struct ActionProgressSheet: View {
    let model: InventoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.progressActionLabel ?? "Running brew…").font(.headline)
                Spacer()
                Button("Cancel", role: .destructive) { model.cancelAction() }
                    .keyboardShortcut(.cancelAction) // Esc cancels the running action
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.actionProgress.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if model.actionProgress.isEmpty {
                            Text("Waiting for brew output…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { proxy.scrollTo("tail", anchor: .bottom) }
                .onChange(of: model.actionProgress.count) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
            }
            .frame(minHeight: 220, maxHeight: 340)
            Text("Cancel sends SIGINT: brew aborts and cleans up what it can; anything already installed or cloned stays. The inventory re-read that follows shows the real state.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 300)
    }
}
