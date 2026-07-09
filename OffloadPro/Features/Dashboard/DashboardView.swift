import SwiftUI

/// F1 dashboard (§1.2.8): storage header + category cards + Space Hogs.
/// The scanner UI never deletes anything — all destructive actions route
/// into the F2 offload pipeline via review screens.
struct DashboardView: View {
    @EnvironmentObject private var photoAuth: PhotoAuthService
    @StateObject private var model = DashboardViewModel()

    var body: some View {
        NavigationStack {
            Group {
                switch photoAuth.state {
                case .notDetermined:
                    requestAccessView
                case .denied:
                    deniedView
                case .limited, .authorized:
                    scannerContent
                }
            }
            .navigationTitle("OffloadPro")
        }
    }

    // MARK: Permission states (§1.3 manual QA: graceful empty state)

    private var requestAccessView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("See what's eating your iPhone")
                .font(.title3.bold())
            Text("OffloadPro analyzes your photo library on this device. Photos never leave your phone except to storage you choose.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Allow Photo Access") {
                Task {
                    await photoAuth.requestAccess()
                    if photoAuth.state == .authorized || photoAuth.state == .limited {
                        model.startScan()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding()
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Photo access is off").font(.headline)
            Text("Enable photo access in Settings to scan your library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Settings") { photoAuth.openAppSettings() }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: Scanner content

    private var scannerContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                if photoAuth.state == .limited {
                    limitedAccessBanner
                }
                if let storage = model.storage {
                    StorageHeaderView(storage: storage)
                }
                scanProgressChip
                RecentlyDeletedReminderCard()
                categoryGrid
                spaceHogsSection
                reviewLinks
            }
            .padding()
        }
        .refreshable { await model.reload() }
        .task {
            if model.spaceHogs.isEmpty {
                model.startScan()
            } else {
                await model.reload()
            }
        }
    }

    private var limitedAccessBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Limited access: results incomplete")
                .font(.footnote)
            Spacer()
            Button("Select More") { photoAuth.presentLimitedLibraryPicker() }
                .font(.footnote.bold())
        }
        .padding(10)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var scanProgressChip: some View {
        switch model.progress.phase {
        case .indexing:
            ProgressView(
                value: Double(model.progress.processed),
                total: Double(max(model.progress.total, 1))
            ) {
                Text("Scanning library… \(model.progress.processed)/\(model.progress.total)")
                    .font(.footnote)
            }
        case .hashingDuplicates(let percent):
            Label("Finding duplicates… \(percent)%", systemImage: "sparkles")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .scoringBlur(let percent):
            Label("Scoring sharpness… \(percent)%", systemImage: "camera.filters")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .idle, .done:
            EmptyView()
        }
    }

    private var categoryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(model.categories, id: \.category) { entry in
                NavigationLink {
                    CategoryDetailView(category: entry.category)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: entry.category.systemImage)
                            .foregroundStyle(.orange)
                        Text(entry.category.rawValue)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text("\(entry.count) items · \(entry.bytes.formattedBytes)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel("\(entry.category.rawValue), \(entry.count) items, \(entry.bytes.formattedBytes)")
            }
        }
    }

    private var spaceHogsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Space Hogs").font(.headline)
            ForEach(model.spaceHogs, id: \.localId) { record in
                HStack {
                    Image(systemName: record.mediaType == AssetClassifier.mediaTypeVideo ? "video.fill" : "photo")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(record.bytes.formattedBytes).font(.subheadline.bold())
                        badges(for: record)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func badges(for record: AssetRecord) -> some View {
        HStack(spacing: 6) {
            if let width = record.width, let height = record.height, min(width, height) >= 2160 {
                BadgeView(text: "4K")
            }
            if (record.subtype & AssetClassifier.subtypeSloMo) != 0 {
                BadgeView(text: "Slo-mo")
            }
            if record.isScreenRecording == true {
                BadgeView(text: "Screen Rec")
            }
        }
    }

    private var reviewLinks: some View {
        VStack(spacing: 8) {
            NavigationLink {
                DuplicatesReviewView(clusters: model.duplicateClusters)
            } label: {
                reviewRow(
                    icon: "square.on.square",
                    title: "Duplicates",
                    detail: "\(model.duplicateClusters.count) groups"
                )
            }
            NavigationLink {
                JunkReviewView(records: model.junk)
            } label: {
                reviewRow(
                    icon: "trash.slash",
                    title: "Junk (blurry & accidental)",
                    detail: "\(model.junk.count) items"
                )
            }
            NavigationLink {
                DeletionReviewView()
            } label: {
                reviewRow(
                    icon: "checkmark.shield",
                    title: "Verified & ready to remove",
                    detail: ""
                )
            }
        }
    }

    private func reviewRow(icon: String, title: String, detail: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.orange).frame(width: 28)
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct StorageHeaderView: View {
    let storage: DeviceStorage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iPhone Storage").font(.headline)
            ProgressView(value: Double(storage.usedBytes), total: Double(max(storage.totalBytes, 1)))
                .tint(.orange)
            HStack {
                Text("\(storage.usedBytes.formattedBytes) used")
                Spacer()
                Text("\(storage.availableBytes.formattedBytes) free of \(storage.totalBytes.formattedBytes)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iPhone storage: \(storage.usedBytes.formattedBytes) used, \(storage.availableBytes.formattedBytes) free of \(storage.totalBytes.formattedBytes)")
    }
}

/// F1.7 — Recently Deleted reminder. Photos there still consume space for
/// up to 30 days; we cannot measure that album size without a separate
/// PhotoKit fetch, so this is guidance-only (no fabricated GB claims).
struct RecentlyDeletedReminderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Check Recently Deleted", systemImage: "trash.circle")
                .font(.subheadline.bold())
            Text("Items you delete stay in Photos → Albums → Recently Deleted for up to 30 days and still use storage until you empty that album.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

struct BadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(.orange)
    }
}
