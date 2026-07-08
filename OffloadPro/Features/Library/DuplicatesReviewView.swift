import SwiftUI

/// Duplicates review (§1.2.8): cluster cards with keep-best preselected —
/// everything except the best copy starts selected for offload.
struct DuplicatesReviewView: View {
    let clusters: [[AssetRecord]]

    @State private var selectedIds: Set<String> = []
    @State private var initialized = false

    private var allRecords: [AssetRecord] { clusters.flatMap { $0 } }
    private var selection: [AssetRecord] {
        allRecords.filter { selectedIds.contains($0.localId) }
    }

    var body: some View {
        List {
            if clusters.isEmpty {
                ContentUnavailableCompatView(
                    title: "No duplicates found",
                    subtitle: "Great — your library has no detected duplicate groups.",
                    icon: "checkmark.seal"
                )
            }
            ForEach(Array(clusters.enumerated()), id: \.offset) { _, cluster in
                Section {
                    clusterView(cluster)
                }
            }
        }
        .navigationTitle("Duplicates")
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                SelectionOffloadBar(selection: selection)
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            // Preselect everything except the "keep best" per cluster.
            for cluster in clusters {
                let best = DuplicateDetector.keepBest(in: cluster)
                for record in cluster where record.localId != best?.localId {
                    selectedIds.insert(record.localId)
                }
            }
        }
    }

    private func clusterView(_ cluster: [AssetRecord]) -> some View {
        let best = DuplicateDetector.keepBest(in: cluster)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(cluster, id: \.localId) { record in
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            AssetThumbnailView(localId: record.localId, side: 110)
                            if selectedIds.contains(record.localId) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .background(Circle().fill(.white))
                                    .padding(4)
                            }
                        }
                        if record.localId == best?.localId {
                            Text("Keep best")
                                .font(.caption2.bold())
                                .foregroundStyle(.green)
                        } else {
                            Text(record.bytes.formattedBytes)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onTapGesture {
                        if selectedIds.contains(record.localId) {
                            selectedIds.remove(record.localId)
                        } else {
                            selectedIds.insert(record.localId)
                        }
                    }
                    .accessibilityLabel("Duplicate, \(record.bytes.formattedBytes)\(record.localId == best?.localId ? ", suggested keep" : "")")
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// iOS 16-compatible stand-in for ContentUnavailableView (iOS 17+).
struct ContentUnavailableCompatView: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
    }
}
