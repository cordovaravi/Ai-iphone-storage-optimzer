import SwiftUI

/// Custom paywall (§6.2.2) with the iCloud-comparison block (F6.4).
/// Copy discipline: never say "subscription" — this is a one-time purchase.
struct PaywallView: View {
    @EnvironmentObject private var purchases: PurchasesService
    @Environment(\.dismiss) private var dismiss

    /// Optional context line, e.g. exact overage messaging from the meter gate.
    var contextMessage: String?
    /// Called after a successful purchase so the original action can resume.
    var onPurchased: (() -> Void)?

    @State private var isPurchasing = false
    @State private var restoreResult: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if let contextMessage {
                        Text(contextMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    featureList
                    comparisonBlock
                    purchaseButtons
                    legalLinks
                }
                .padding()
            }
            .navigationTitle("Lifetime Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Unlock everything, once.")
                .font(.title2.bold())
            Text("One-time purchase. No monthly rent. Yours forever.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            featureRow("infinity", "Unlimited offloading — no 5 GB cap")
            featureRow("externaldrive.fill", "Pendrive Mode: incremental backup to your own drive")
            featureRow("wand.and.stars", "Smart Modes: “Free up N GB” in one tap")
            featureRow("list.bullet.rectangle", "Transfer history with CSV export")
            featureRow("person.2.fill", "Family Sharing included")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private func featureRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
                .frame(width: 28)
            Text(text).font(.subheadline)
        }
    }

    private var comparisonBlock: some View {
        VStack(spacing: 8) {
            Text("iCloud 200 GB is a payment every single month, forever.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                VStack {
                    Text("iCloud").font(.caption).foregroundStyle(.secondary)
                    Text("Rent, forever").font(.headline)
                }
                .frame(maxWidth: .infinity)
                VStack {
                    Text("OffloadPro").font(.caption).foregroundStyle(.secondary)
                    Text("\(purchases.localizedPrice), once")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var purchaseButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    isPurchasing = true
                    defer { isPurchasing = false }
                    if await purchases.purchaseLifetime() {
                        onPurchased?()
                        dismiss()
                    }
                }
            } label: {
                Group {
                    if isPurchasing {
                        ProgressView()
                    } else {
                        Text("Get Lifetime Pro — \(purchases.localizedPrice)")
                            .bold()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(isPurchasing || purchases.lifetimePackage == nil)
            .accessibilityLabel("Purchase Lifetime Pro for \(purchases.localizedPrice), one-time")

            Button("Restore Purchases") {
                Task {
                    let restored = await purchases.restorePurchases()
                    restoreResult = restored ? "Pro restored ✓" : "No previous purchase found"
                    if restored {
                        onPurchased?()
                        dismiss()
                    }
                }
            }
            .font(.subheadline)

            if let restoreResult {
                Text(restoreResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var legalLinks: some View {
        HStack(spacing: 16) {
            Link("Terms", destination: URL(string: "https://offloadpro.app/terms")!)
            Link("Privacy", destination: URL(string: "https://offloadpro.app/privacy")!)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
