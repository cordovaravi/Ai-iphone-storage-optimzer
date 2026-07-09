import SwiftUI
import GRDB

struct SettingsView: View {
    @EnvironmentObject private var purchases: PurchasesService
    @State private var showPaywall = false
    @State private var driveSignedIn = false
    @State private var meterBytes: Int64 = 0
    @State private var exportedCSV: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("Plan") {
                    if purchases.isPro {
                        Label("Lifetime Pro — thank you!", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            showPaywall = true
                        } label: {
                            Label("Unlock Lifetime Pro (one-time purchase)", systemImage: "sparkles")
                        }
                        Label("Free tier used: \(meterBytes.formattedBytes) of 5 GB", systemImage: "gauge.with.needle")
                            .foregroundStyle(.secondary)
                        Button("Restore Purchases") {
                            Task { await purchases.restorePurchases() }
                        }
                    }
                }

                Section("Destinations") {
                    if driveSignedIn {
                        Label("Google Drive connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Sign out of Google Drive", role: .destructive) {
                            GoogleDriveAuth.shared.signOut()
                            driveSignedIn = false
                        }
                    } else {
                        Button {
                            Task {
                                if (try? await GoogleDriveAuth.shared.signIn()) != nil {
                                    driveSignedIn = true
                                }
                            }
                        } label: {
                            Label("Connect Google Drive", systemImage: "arrow.up.doc")
                        }
                    }
                }

                Section("Transfer History") {
                    if purchases.isPro {
                        Button {
                            Task { await exportHistory() }
                        } label: {
                            Label("Export history as CSV", systemImage: "square.and.arrow.up")
                        }
                        if let exportedCSV {
                            ShareLink(item: exportedCSV) {
                                Label("Share exported CSV", systemImage: "doc.text")
                            }
                        }
                    } else {
                        Label("History export is a Pro feature", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Privacy") {
                    Text("All analysis happens on this device. Your photos go only to destinations you choose — never to our servers, because we don't have any.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Privacy Policy", destination: URL(string: "https://offloadpro.app/privacy")!)
                    Link("Terms of Use", destination: URL(string: "https://offloadpro.app/terms")!)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .task {
                driveSignedIn = GoogleDriveAuth.shared.isSignedIn
                meterBytes = (try? await AppEnvironment.shared.meter.lifetimeBytes()) ?? 0
            }
        }
    }

    /// F2.7: CSV export of transfer history (Pro gate #4, §6.2.4).
    private func exportHistory() async {
        guard purchases.isPro else { return }
        let database = AppEnvironment.shared.database
        guard let rows = try? database.writer.read({ db in
            try TransferHistoryRecord.fetchAll(db)
        }) else { return }

        let csv = HistoryCSVExporter.csv(from: rows)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offloadpro-history.csv")
        try? csv.data(using: .utf8)?.write(to: url)
        exportedCSV = url
    }
}
