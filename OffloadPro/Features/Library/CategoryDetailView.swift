import SwiftUI

/// Category detail (§1.2.8): size-sorted grid with badges and selection.
struct CategoryDetailView: View {
    let category: MediaCategory

    @State private var records: [AssetRecord] = []
    @State private var selectedIds: Set<String> = []

    private var selection: [AssetRecord] {
        records.filter { selectedIds.contains($0.localId) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(records, id: \.localId) { record in
                    Button {
                        toggle(record.localId)
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            AssetThumbnailView(localId: record.localId, side: 100)
                            Text(record.bytes.formattedBytes)
                                .font(.caption2.bold())
                                .padding(3)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(.white)
                                .padding(4)
                        }
                        .overlay(alignment: .topTrailing) {
                            if selectedIds.contains(record.localId) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .background(Circle().fill(.white))
                                    .padding(4)
                            }
                        }
                    }
                    .accessibilityLabel("\(category.rawValue) item, \(record.bytes.formattedBytes)\(selectedIds.contains(record.localId) ? ", selected" : "")")
                }
            }
            .padding(8)
        }
        .navigationTitle(category.rawValue)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(selectedIds.count == records.count ? "Deselect All" : "Select All") {
                    if selectedIds.count == records.count {
                        selectedIds.removeAll()
                    } else {
                        selectedIds = Set(records.map(\.localId))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                SelectionOffloadBar(selection: selection)
            }
        }
        .task {
            records = (try? await AppEnvironment.shared.scanner.records(in: category)) ?? []
        }
    }

    private func toggle(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }
}
