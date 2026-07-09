import Foundation
import RevenueCat

/// RevenueCat wrapper (§6.2). The `pro` entitlement is the ONLY pro gate in
/// the app (F6.5) — features must read `isPro`, never local flags.
@MainActor
final class PurchasesService: NSObject, ObservableObject {
    static let entitlementId = "pro"
    static let offeringId = "default"
    static let packageId = "lifetime"

    /// Cached entitlement state. Offline behavior (§6.2.5): RevenueCat's
    /// cached CustomerInfo feeds this; with no cache at all we fail closed
    /// to free tier and show a non-blocking banner.
    @Published private(set) var isPro = false
    @Published private(set) var entitlementUnknownOffline = false
    @Published private(set) var lifetimePackage: Package?

    private var infoTask: Task<Void, Never>?

    func configure() {
        // Fail closed to free tier when secrets are still placeholders —
        // avoids crashing / noisy RC errors in unsigned local builds.
        guard !Secrets.hasPlaceholderRevenueCatKey else {
            Log.purchase.info("RevenueCat key not configured; running as free tier")
            isPro = false
            entitlementUnknownOffline = false
            return
        }

        let configuration = Configuration.Builder(withAPIKey: Secrets.revenueCatAPIKey)
        #if DEBUG
        Purchases.logLevel = .debug
        #endif
        Purchases.configure(with: configuration.build())

        infoTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                self?.apply(info)
            }
        }
        Task { await refresh() }
        Task { await loadOffering() }
    }

    private func apply(_ info: CustomerInfo) {
        isPro = info.entitlements[Self.entitlementId]?.isActive == true
        entitlementUnknownOffline = false
    }

    func refresh() async {
        do {
            let info = try await Purchases.shared.customerInfo()
            apply(info)
        } catch {
            // No cache and offline → free tier, fail closed, banner only.
            if !isPro { entitlementUnknownOffline = true }
            Log.purchase.error("customerInfo failed: \(error.localizedDescription)")
        }
    }

    func loadOffering() async {
        do {
            let offerings = try await Purchases.shared.offerings()
            lifetimePackage = offerings.offering(identifier: Self.offeringId)?
                .package(identifier: Self.packageId)
                ?? offerings.current?.availablePackages.first
        } catch {
            Log.purchase.error("offerings failed: \(error.localizedDescription)")
        }
    }

    /// Returns true when the purchase completed and pro is now active.
    @discardableResult
    func purchaseLifetime() async -> Bool {
        guard let package = lifetimePackage else { return false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return false } // silent per §6.2.3
            apply(result.customerInfo)
            Log.purchase.info("Lifetime purchase completed")
            return isPro
        } catch {
            Log.purchase.error("purchase failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func restorePurchases() async -> Bool {
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            return isPro
        } catch {
            Log.purchase.error("restore failed: \(error.localizedDescription)")
            return false
        }
    }

    var localizedPrice: String {
        lifetimePackage?.storeProduct.localizedPriceString ?? "—"
    }
}
