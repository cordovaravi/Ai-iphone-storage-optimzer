import SwiftUI

/// "Verified & ready to remove" (§2.2.6, F7.2): shows exactly what will be
/// removed and where the verified copies live, then triggers ONE system
/// confirmation dialog for the whole batch. Failed items are listed
/// separately with explicit "not backed up" labeling and are excluded.
struct DeletionReviewView: View {
    @State private var verified: [TransferItem] = []
    @State private var failed: [TransferItem] = []
    @State private var toast: String?
    @State private var isDeleting = false

    private var totalBytes: Int64 { verified.reduce(0) { $0 + ($1.bytes ?? 0) } }

    var body: some View {
        List {
            if verified.isEmpty && failed.isEmpty {
                ContentUnavailableCompatView(
                    title: "Nothing ready yet",
                    subtitle: "Items appear here after their copies are checksum-verified at your destination.",
                    icon: "checkmark.shield"
                )
            }

            if !verified.isEmpty {
                Section("Verified — safe to remove (\(totalBytes.formattedBytes))") {
                    ForEach(verified, id: \.id) { item in
                        HStack {
                            AssetThumbnailView(localId: item.localId, side: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((item.bytes ?? 0).formattedBytes)
                                    .font(.subheadline.bold())
                                Text("Copy at: \(item.destPath ?? "—")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                        .accessibilityLabel("Verified item, \((item.bytes ?? 0).formattedBytes), copy stored at \(item.destPath ?? "destination")")
                    }
                }
            }

            if !failed.isEmpty {
                Section("Not backed up — will NOT be removed") {
                    ForEach(failed, id: \.id) { item in
                        HStack {
                            AssetThumbnailView(localId: item.localId, side: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.isDegradedExport ? "Original couldn't be fully exported" : (item.error ?? "Transfer failed"))
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Spacer()
                            Image(systemName: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Ready to Remove")
        .safeAreaInset(edge: .bottom) {
            if !verified.isEmpty {
                VStack(spacing: 6) {
                    Text("iOS will ask you to confirm once for the whole batch. Removed photos stay recoverable for 30 days in Recently Deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await deleteBatch() }
                    } label: {
                        Group {
                            if isDeleting {
                                ProgressView()
                            } else {
                                Text("Remove \(verified.count) items from iPhone")
                                    .bold()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isDeleting)
                }
                .padding()
                .background(.thinMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 100)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        let coordinator = AppEnvironment.shared.coordinator
        verified = (try? await coordinator.verifiedItems()) ?? []
        failed = (try? await coordinator.failedItems()) ?? []
    }

    private func deleteBatch() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            let confirmed = try await AppEnvironment.shared.coordinator
                .deleteVerifiedBatch(localIds: verified.map(\.localId))
            if confirmed {
                toast = "\(verified.count) items removed — copies are safe at your destination."
            } else {
                // User cancelled: items stay verified, nothing changes (§2.2.6).
                toast = "Kept on device"
            }
            await reload()
        } catch {
            toast = "Couldn't remove items: \(error.localizedDescription)"
        }
    }
}
