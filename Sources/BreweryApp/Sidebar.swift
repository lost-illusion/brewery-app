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
        HStack {
            Text(footerText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footerText: String {
        func clock(_ date: Date?) -> String {
            date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—"
        }
        if model.inventoryUpdated == nil && model.versionDataAsOf == nil { return "not refreshed yet" }
        return "Updated \(clock(model.inventoryUpdated)) · Version data as of \(clock(model.versionDataAsOf))"
    }
}
