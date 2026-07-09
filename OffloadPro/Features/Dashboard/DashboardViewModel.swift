import Foundation
import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var storage = DeviceStorage.current()
    @Published var progress: ScanProgress = .idle
    @Published var spaceHogs: [AssetRecord] = []
    @Published var categories: [(category: MediaCategory, count: Int, bytes: Int64)] = []
    @Published var duplicateClusters: [[AssetRecord]] = []
    @Published var junk: [AssetRecord] = []
    @Published var scanError: String?

    private let scanner = AppEnvironment.shared.scanner
    private var progressTask: Task<Void, Never>?

    /// Launch/refresh entry point: full scan only when the persisted index
    /// is empty; otherwise a cheap reconcile — no rescan on every launch.
    func refresh() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            guard let self else { return }
            for await progress in await self.scanner.progressStream() {
                self.progress = progress
                if case .done = progress.phase {
                    await self.reload()
                }
            }
        }
        Task {
            do {
                try await scanner.refreshIfNeeded()
                await reload()
            } catch {
                scanError = error.localizedDescription
            }
        }
    }

    func reload() async {
        storage = DeviceStorage.current()
        do {
            spaceHogs = try await scanner.spaceHogs(limit: 10)
            let totals = try await scanner.categoryTotals()
            categories = totals
                .map { (category: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
                .sorted { $0.bytes > $1.bytes }
            let all = try await scanner.allRecords()
            duplicateClusters = DuplicateDetector.nearDuplicateClusters(all)
                + DuplicateDetector.exactDuplicateClusters(all)
            junk = try await scanner.junkCandidates()
        } catch {
            scanError = error.localizedDescription
        }
    }
}
