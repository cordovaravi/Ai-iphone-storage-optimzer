import SwiftUI

/// Offload Status (§2.2.6, F7.2): live view of the transfer pipeline plus
/// the reviewed deletion step.
///
/// Sections:
///  - In progress: queued/exporting/uploading/verifying items, refreshed
///    every 1.5s while visible.
///  - Verified: exactly what can be removed and where the copies live; the
///    Remove button triggers ONE system confirmation for the whole batch.
///  - Failed: explicit "not backed up" labeling; never removable.
struct OffloadStatusView: View {
    @State private var active: [TransferItem] = []
    @State private var verified: [TransferItem] = []
    @State private var failed: [TransferItem] = []
    @State private var toast: String?
    @State private var isDeleting = false

    private var totalVerifiedBytes: Int64 { verified.reduce(0) { $0 + ($1.bytes ?? 0) } }

    var body: some View {
        List {
            if active.isEmpty && verified.isEmpty && failed.isEmpty {
                ContentUnavailableCompatView(
                    title: "No transfers yet",
                    subtitle: "Select items anywhere in the app and tap Offload. Progress and the removal step appear here.",
                    icon: "checkmark.shield"
                )
            }

            if !active.isEmpty {
                Section("In progress (\(active.count))") {
                    ForEach(active, id: \.id) { item in
                        HStack {
                            AssetThumbnailView(localId: item.localId, side: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((item.bytes ?? 0).formattedBytes)
                                    .font(.subheadline.bold())
                                Text(stateLabel(item.state))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ProgressView()
                        }
                        .accessibilityLabel("Transferring item, \(stateLabel(item.state))")
                    }
                }
            }

            if !verified.isEmpty {
                Section("Verified — safe to remove (\(totalVerifiedBytes.formattedBytes))") {
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
                            Text(item.isDegradedExport
                                 ? "Original couldn't be fully exported"
                                 : (item.error ?? "Transfer failed"))
                                .font(.caption)
                                .foregroundStyle(.red)
                            Spacer()
                            Image(systemName: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Offload Status")
        .safeAreaInset(edge: .bottom) {
            if !verified.isEmpty {
                removeBar
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
        .task { await autoRefresh() }
        .refreshable { await reload() }
    }

    private var removeBar: some View {
        VStack(spacing: 6) {
            Text("iOS asks you to confirm once for the whole batch. Removed photos stay recoverable for 30 days in Recently Deleted.")
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
                        Text("Remove \(verified.count) items from iPhone").bold()
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

    private func stateLabel(_ state: TransferState) -> String {
        switch state {
        case .queued: return "Waiting…"
        case .exporting: return "Exporting original…"
        case .uploading: return "Uploading…"
        case .verifying: return "Verifying copy…"
        case .verified: return "Verified"
        case .failed: return "Failed"
        case .deleted: return "Removed"
        }
    }

    /// Poll while visible — transfers advance in a background actor and
    /// there's no change stream yet; 1.5s keeps the UI honest and cheap.
    private func autoRefresh() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private func reload() async {
        let coordinator = AppEnvironment.shared.coordinator
        active = (try? await coordinator.activeItems()) ?? []
        verified = (try? await coordinator.verifiedItems()) ?? []
        failed = (try? await coordinator.failedItems()) ?? []
    }

    private func deleteBatch() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            let count = verified.count
            let confirmed = try await AppEnvironment.shared.coordinator
                .deleteVerifiedBatch(localIds: verified.map(\.localId))
            if confirmed {
                toast = "\(count) items removed — copies are safe at your destination."
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
