import SwiftUI

/// Shared bottom bar: takes the current selection into the F2 pipeline.
///
/// Owns three gates before anything is queued:
///  1. Destination readiness — Google Drive must be signed in, or the
///     external drive folder picked. Nothing enqueues into a dead
///     destination (it would just fail invisibly in the background).
///  2. The free-tier meter (§2.2.7) with paywall + auto-resume (§6.3).
///  3. After a successful enqueue it opens the Offload Status sheet so the
///     user watches transfer → verify progress and gets the removal step
///     the moment items are safe to delete.
struct SelectionOffloadBar: View {
    @EnvironmentObject private var purchases: PurchasesService

    let selection: [AssetRecord]

    @State private var destinationId = "gdrive"
    @State private var showPaywall = false
    @State private var overageBytes: Int64 = 0
    @State private var notice: String?
    @State private var showStatus = false
    @State private var showDrivePicker = false
    @State private var isWorking = false

    private var totalBytes: Int64 { selection.reduce(0) { $0 + $1.bytes } }

    private var driveSignedIn: Bool { GoogleDriveAuth.shared.isSignedIn }
    private var localConfigured: Bool { AppEnvironment.shared.localDrive.isConfigured }

    var body: some View {
        VStack(spacing: 8) {
            destinationPicker
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await offloadTapped() }
            } label: {
                Group {
                    if isWorking {
                        ProgressView()
                    } else {
                        Text("Offload \(selection.count) items (\(totalBytes.formattedBytes))")
                            .bold()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(selection.isEmpty || isWorking)
            .accessibilityLabel("Offload \(selection.count) items, \(totalBytes.formattedBytes)")
        }
        .padding()
        .background(.thinMaterial)
        .onAppear {
            // Default to whichever destination is actually usable.
            if !driveSignedIn && localConfigured {
                destinationId = "localdrive"
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(
                contextMessage: "This selection puts you \(overageBytes.formattedBytes) over the free 5 GB lifetime limit. Unlock unlimited offloading once, forever.",
                onPurchased: { Task { await offloadTapped() } }
            )
        }
        .sheet(isPresented: $showStatus) {
            NavigationStack { OffloadStatusView() }
        }
        .sheet(isPresented: $showDrivePicker) {
            FolderPicker { url in
                do {
                    try AppEnvironment.shared.localDrive.saveBookmark(for: url)
                    notice = "Drive connected ✓ Tap Offload again to start."
                } catch {
                    notice = "Couldn't access that folder: \(error.localizedDescription)"
                }
            }
        }
    }

    private var destinationPicker: some View {
        Picker("Destination", selection: $destinationId) {
            Label(driveSignedIn ? "Google Drive" : "Google Drive (sign in)", systemImage: "cloud")
                .tag("gdrive")
            Label(localConfigured ? "External Drive" : "External Drive (pick folder)", systemImage: "externaldrive")
                .tag("localdrive")
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Offload destination")
    }

    private func offloadTapped() async {
        isWorking = true
        defer { isWorking = false }

        // Gate 1: destination readiness.
        if destinationId == "gdrive", !driveSignedIn {
            guard !Secrets.hasPlaceholderGoogleOAuthClientId else {
                notice = "Google Drive isn't configured in this build (no OAuth client ID). Use External Drive, or add the client ID in Secrets.swift."
                return
            }
            do {
                _ = try await GoogleDriveAuth.shared.signIn()
            } catch {
                notice = "Google Drive sign-in didn't finish. Try again or use External Drive."
                return
            }
        }
        if destinationId == "localdrive", !localConfigured {
            showDrivePicker = true
            return
        }

        // Gate 2: meter/paywall, then enqueue.
        do {
            let outcome = try await AppEnvironment.shared.coordinator.enqueue(
                records: selection,
                destinationId: destinationId,
                isPro: purchases.isPro
            )
            switch outcome {
            case .enqueued(let count):
                notice = count == 0
                    ? "These items are already offloaded or in the queue."
                    : nil
                // Gate 3: show progress + the removal step when verified.
                if count > 0 { showStatus = true }
            case .paywallRequired(let overage):
                overageBytes = overage
                showPaywall = true
            }
        } catch {
            notice = "Could not queue items: \(error.localizedDescription)"
        }
    }
}
