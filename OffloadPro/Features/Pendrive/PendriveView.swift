import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// F4 Pendrive Mode (Pro). Mode colors are deliberate (§4.1.4):
/// backup = blue (copy only), offload = orange (copies then offers deletion).
/// In backup mode the deletion review is structurally unreachable.
struct PendriveView: View {
    var body: some View {
        NavigationStack {
            ProGate(featureName: "Pendrive Mode") {
                PendriveContentView()
            }
            .navigationTitle("Pendrive")
        }
    }
}

private struct PendriveContentView: View {
    @State private var mode: PendriveService.Mode = .backup
    @State private var showPicker = false
    @State private var driveConfigured = AppEnvironment.shared.localDrive.isConfigured
    @State private var plan: PendriveService.RunPlan?
    @State private var status: String?
    @State private var isRunning = false
    @State private var copiedCount = 0

    private var accent: Color { mode == .backup ? .blue : .orange }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                modePicker
                if driveConfigured {
                    planSection
                } else {
                    pickDriveSection
                }
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showPicker) {
            FolderPicker { url in
                do {
                    try AppEnvironment.shared.localDrive.saveBookmark(for: url)
                    driveConfigured = true
                    status = "Drive connected. exFAT is recommended; FAT32 can't hold files over 4 GB."
                } catch {
                    status = "Couldn't access that folder: \(error.localizedDescription)"
                }
            }
        }
    }

    private var modePicker: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $mode) {
                Text("Backup").tag(PendriveService.Mode.backup)
                Text("Offload").tag(PendriveService.Mode.offload)
            }
            .pickerStyle(.segmented)

            Text(mode == .backup
                 ? "Backup copies photos to your drive. Nothing is ever removed from your iPhone."
                 : "Offload copies, verifies, then lets you review and remove originals from your iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private var pickDriveSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(accent)
            Text("Connect your drive").font(.headline)
            Text("Plug in a pendrive or SSD, then pick its folder in Files. Access is remembered for next time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Drive Folder") { showPicker = true }
                .buttonStyle(.borderedProminent)
                .tint(accent)
        }
        .padding(.vertical, 24)
    }

    private var planSection: some View {
        VStack(spacing: 12) {
            if let plan {
                VStack(spacing: 6) {
                    Text("\(plan.toCopy.count) new or changed items")
                        .font(.headline)
                    Text("\(plan.totalBytes.formattedBytes) to copy — incremental, already-copied items are skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await run(plan) }
                } label: {
                    Group {
                        if isRunning {
                            ProgressView().tint(.white)
                        } else {
                            Text(mode == .backup ? "Back Up to Drive" : "Offload to Drive").bold()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(isRunning || plan.toCopy.isEmpty)

                if isRunning {
                    ProgressView(value: Double(copiedCount), total: Double(max(plan.toCopy.count, 1))) {
                        Text("\(copiedCount)/\(plan.toCopy.count) copied").font(.caption)
                    }
                }
            } else {
                ProgressView("Planning incremental run…")
                    .task { await loadPlan() }
            }

            Button("Re-pick Drive Folder") { showPicker = true }
                .font(.footnote)
        }
    }

    private func loadPlan() async {
        do {
            plan = try await AppEnvironment.shared.pendrive.planRun(mode: mode)
        } catch {
            status = "Couldn't read the drive. Re-pick the folder after plugging it in. (\(error.localizedDescription))"
        }
    }

    private func run(_ plan: PendriveService.RunPlan) async {
        isRunning = true
        copiedCount = 0
        defer { isRunning = false }

        let pendrive = AppEnvironment.shared.pendrive
        let drive = AppEnvironment.shared.localDrive
        let exporter = AppEnvironment.shared.exporter

        for record in plan.toCopy {
            do {
                let export = try await exporter.export(localId: record.localId) { _ in }
                defer { exporter.cleanUp(export) }
                for file in export.files {
                    let relPath = OffloadCoordinator.relPath(
                        for: file.filename,
                        createdAt: record.createdAt.map { Date(timeIntervalSince1970: $0) }
                    )
                    let ref = try await drive.upload(fileURL: file.url, relPath: relPath) { _ in }
                    // Verify by re-reading the destination before the
                    // manifest row is written (§4.1.3).
                    let checksum = try await drive.checksum(of: ref)
                    guard case .sha256(let destHash) = checksum, destHash == file.sha256 else {
                        throw TransferError.checksumMismatch
                    }
                    try await pendrive.recordCopied(
                        driveUuid: plan.driveUuid,
                        localId: record.localId,
                        relPath: relPath,
                        bytes: file.bytes,
                        sha256: file.sha256
                    )
                }
                copiedCount += 1
            } catch TransferError.destinationFull {
                let remaining = Array(plan.toCopy.dropFirst(copiedCount))
                let summary = PendriveService.driveFullSummary(remaining: remaining, availableBytes: 0)
                status = "Drive is full: needs ~\(summary.neededBytes.formattedBytes) more; \(summary.itemCount) items remaining. Free space on the drive and run again — completed items won't be re-copied."
                break
            } catch {
                status = "Stopped: \(error.localizedDescription). Already-copied items are safe and won't repeat."
                break
            }
        }

        await pendrive.endSession()
        if copiedCount == plan.toCopy.count {
            status = mode == .backup
                ? "Backup complete ✓ Safe to remove the drive."
                : "Copy complete ✓ Review items in “Verified & ready to remove” on the Storage tab. Safe to remove the drive after that."
        }
        await loadPlan()
    }
}

/// UIDocumentPickerViewController in folder mode (§2.2.4).
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
