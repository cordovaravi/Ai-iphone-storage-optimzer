import SwiftUI
import UIKit
import BackgroundTasks
import RevenueCat
import Sentry

@main
struct OffloadProApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppEnvironment.shared.purchases)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppEnvironment.shared.bootstrap()
        return true
    }
}

/// Composition root: owns long-lived services (§0.1 MVVM + service layer).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let database: AppDatabase
    let purchases: PurchasesService
    let photoAuth: PhotoAuthService
    let scanner: ScannerService
    let meter: OffloadMeterStore
    let coordinator: OffloadCoordinator
    let destinations: DestinationRegistry
    let coach: CoachService
    let exporter: AssetExportService
    let localDrive: LocalDriveDestination
    let pendrive: PendriveService

    private init() {
        do {
            database = try AppDatabase.makeShared()
        } catch {
            // A broken database file is unrecoverable in-place; fall back to
            // in-memory so the app can still show the library and re-index.
            Log.db.error("Failed to open database, falling back to in-memory: \(error.localizedDescription)")
            guard let fallback = try? AppDatabase.makeEmpty() else {
                fatalError("Cannot create even an in-memory database")
            }
            database = fallback
        }
        purchases = PurchasesService()
        photoAuth = PhotoAuthService()
        meter = OffloadMeterStore(database: database)
        scanner = ScannerService(database: database, provider: PhotoKitAssetProvider())
        exporter = AssetExportService()
        localDrive = LocalDriveDestination()
        destinations = DestinationRegistry()
        destinations.register(GoogleDriveDestination())
        destinations.register(localDrive)
        coordinator = OffloadCoordinator(
            database: database,
            meter: meter,
            destinations: destinations,
            exporter: exporter
        )
        pendrive = PendriveService(database: database, destination: localDrive)
        coach = CoachService(database: database)
    }

    func bootstrap() {
        configureSentry()
        purchases.configure()
        registerBackgroundTasks()
    }

    private func configureSentry() {
        // Skip Sentry when no DSN is configured (local/dev builds).
        guard !Secrets.sentryDSN.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = Secrets.sentryDSN
            options.enableAutoSessionTracking = true
            // §7.3 — strip anything that could identify media.
            options.beforeSend = { event in
                event.message = nil
                event.breadcrumbs = event.breadcrumbs?.filter { crumb in
                    crumb.category != "file" && crumb.category != "http"
                }
                event.context?.removeValue(forKey: "app_files")
                return event
            }
        }
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: OffloadCoordinator.backgroundTaskIdentifier,
            using: nil
        ) { [coordinator] task in
            guard let task = task as? BGProcessingTask else { return }
            coordinator.handleBackgroundTask(task)
        }
    }
}
