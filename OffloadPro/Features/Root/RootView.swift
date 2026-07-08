import SwiftUI

/// Tab-level navigation. Pro gates (F6.5): Pendrive and Smart Modes tabs
/// route through the paywall when `isPro` is false.
struct RootView: View {
    @EnvironmentObject private var purchases: PurchasesService
    @StateObject private var photoAuth = AppEnvironment.shared.photoAuth

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }

            SmartModesView()
                .tabItem { Label("Smart", systemImage: "wand.and.stars") }

            PendriveView()
                .tabItem { Label("Pendrive", systemImage: "externaldrive") }

            CoachListView()
                .tabItem { Label("Coach", systemImage: "checklist") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .environmentObject(photoAuth)
        .overlay(alignment: .top) {
            if purchases.entitlementUnknownOffline {
                OfflineEntitlementBanner()
            }
        }
    }
}

/// Non-blocking banner for the no-cache offline case (§6.2.5).
struct OfflineEntitlementBanner: View {
    var body: some View {
        Text("Offline — Pro status unavailable, running as Free tier")
            .font(.caption)
            .padding(8)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 4)
            .accessibilityLabel("Offline. Pro status unavailable. Running as free tier.")
    }
}

/// Reusable gate wrapper: shows content when pro, paywall trigger otherwise.
struct ProGate<Content: View>: View {
    @EnvironmentObject private var purchases: PurchasesService
    @State private var showPaywall = false

    let featureName: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        if purchases.isPro {
            content()
        } else {
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("\(featureName) is a Pro feature")
                    .font(.headline)
                Text("One-time purchase — no monthly rent.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("See Lifetime Pro") { showPaywall = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
        }
    }
}
