import SwiftUI

/// Shared bottom bar: takes the current selection into the F2 pipeline.
/// Owns the free-tier meter gate (§2.2.7) — if the selection would exceed
/// 5 GB lifetime on free tier, presents the paywall with exact overage
/// messaging, and auto-resumes the enqueue after purchase (§6.3).
struct SelectionOffloadBar: View {
    @EnvironmentObject private var purchases: PurchasesService

    let selection: [AssetRecord]
    var destinationId = "gdrive"

    @State private var showPaywall = false
    @State private var overageBytes: Int64 = 0
    @State private var confirmation: String?

    private var totalBytes: Int64 { selection.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 8) {
            if let confirmation {
                Text(confirmation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await enqueue() }
            } label: {
                Text("Offload \(selection.count) items (\(totalBytes.formattedBytes))")
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(selection.isEmpty)
            .accessibilityLabel("Offload \(selection.count) items, \(totalBytes.formattedBytes)")
        }
        .padding()
        .background(.thinMaterial)
        .sheet(isPresented: $showPaywall) {
            PaywallView(
                contextMessage: "This selection puts you \(overageBytes.formattedBytes) over the free 5 GB lifetime limit. Unlock unlimited offloading once, forever.",
                onPurchased: { Task { await enqueue() } }
            )
        }
    }

    private func enqueue() async {
        do {
            let outcome = try await AppEnvironment.shared.coordinator.enqueue(
                records: selection,
                destinationId: destinationId,
                isPro: purchases.isPro
            )
            switch outcome {
            case .enqueued(let count):
                confirmation = "\(count) items queued — check “Verified & ready to remove” when transfer completes."
            case .paywallRequired(let overage):
                overageBytes = overage
                showPaywall = true
            }
        } catch {
            confirmation = "Could not queue items: \(error.localizedDescription)"
        }
    }
}
