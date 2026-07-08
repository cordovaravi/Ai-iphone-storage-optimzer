import SwiftUI

/// Junk review (F1.6): blurry photos and accidental micro-videos.
/// Nothing is deleted here — selection goes into the offload pipeline.
struct JunkReviewView: View {
    let records: [AssetRecord]

    @State private var selectedIds: Set<String> = []

    private var selection: [AssetRecord] {
        records.filter { selectedIds.contains($0.localId) }
    }

    var body: some View {
        ScrollView {
            if records.isEmpty {
                ContentUnavailableCompatView(
                    title: "No junk detected",
                    subtitle: "No blurry photos or accidental clips were flagged.",
                    icon: "sparkles"
                )
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(records, id: \.localId) { record in
                    Button {
                        if selectedIds.contains(record.localId) {
                            selectedIds.remove(record.localId)
                        } else {
                            selectedIds.insert(record.localId)
                        }
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            AssetThumbnailView(localId: record.localId, side: 100)
                            if let blur = record.blurScore {
                                Text("blur \(Int(blur * 100))%")
                                    .font(.caption2.bold())
                                    .padding(3)
                                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(.white)
                                    .padding(4)
                            }
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
                }
            }
            .padding(8)
        }
        .navigationTitle("Junk Review")
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                SelectionOffloadBar(selection: selection)
            }
        }
    }
}
