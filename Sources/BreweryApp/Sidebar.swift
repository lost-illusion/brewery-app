import BreweryCore
import SwiftUI

struct Sidebar: View {
    @Binding var selection: BrewSection
    let counts: [BrewSection: Int]
    let model: InventoryModel

    var body: some View {
        List(selection: $selection) {
            ForEach(BrewSection.allCases, id: \.self) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
                    .badge(counts[section] ?? 0)
            }
        }
        .navigationTitle("brewery")
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(footerLines, id: \.self) { line in
                Text(line)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footerLines: [String] {
        func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        var lines: [String] = []
        if let updated = model.inventoryUpdated { lines.append("Updated \(clock(updated))") }
        if let asOf = model.versionDataAsOf { lines.append("Version data as of \(clock(asOf))") }
        return lines.isEmpty ? ["not refreshed yet"] : lines
    }
}
