import SwiftUI
import GRDB

/// F3 Smart Modes (Pro): "Free up N GB", rule cards, Before-Trip Mode.
struct SmartModesView: View {
    var body: some View {
        NavigationStack {
            ProGate(featureName: "Smart Modes") {
                SmartModesContent()
            }
            .navigationTitle("Smart Modes")
        }
    }
}

private struct SmartModesContent: View {
    @State private var targetGB: Int = 10
    @State private var ruleCards: [SmartPlanner.RuleCard] = []
    @State private var tripDate = Date().addingTimeInterval(3 * 86_400)
    @State private var tripStatus: String?

    private let gbOptions = [5, 10, 20]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                freeUpSection
                ruleCardsSection
                beforeTripSection
            }
            .padding()
        }
        .task { await loadRuleCards() }
    }

    // MARK: "Free up N GB" (F3.1)

    private var freeUpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Free up space").font(.headline)
            HStack {
                ForEach(gbOptions, id: \.self) { option in
                    Button("\(option) GB") { targetGB = option }
                        .buttonStyle(.bordered)
                        .tint(targetGB == option ? .orange : .secondary)
                }
                Stepper("Custom: \(targetGB) GB", value: $targetGB, in: 1...200)
                    .labelsHidden()
            }
            Text("Target: \(targetGB) GB")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            NavigationLink {
                SmartPlanReviewView(targetGB: targetGB)
            } label: {
                Text("Propose Plan")
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding()
        .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Rule cards (F3.2)

    private var ruleCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggestions").font(.headline)
            if ruleCards.isEmpty {
                Text("Suggestions appear after your first scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(ruleCards) { card in
                NavigationLink {
                    PrefilteredSelectionView(title: card.title, records: card.records)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text("\(card.records.count) items · \(card.totalBytes.formattedBytes) — offload?")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    // MARK: Before-Trip Mode (F3.3)

    private var beforeTripSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before-Trip Mode").font(.headline)
            Text("Need space by a date? We'll remind you a day before with a ready plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DatePicker("Trip date", selection: $tripDate, in: Date()..., displayedComponents: .date)
            Button("Remind Me") {
                Task {
                    do {
                        try await BeforeTripScheduler.schedule(tripDate: tripDate, targetGB: targetGB)
                        tripStatus = "Reminder set for the day before your trip ✓"
                    } catch {
                        tripStatus = "Couldn't schedule: \(error.localizedDescription)"
                    }
                }
            }
            .buttonStyle(.bordered)
            if let tripStatus {
                Text(tripStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadRuleCards() async {
        let records = (try? await AppEnvironment.shared.scanner.allRecords()) ?? []
        ruleCards = SmartPlanner().ruleCards(from: records)
    }
}

/// Grouped review for a proposed plan (§3.1.2): per-group toggles, live sum,
/// execution through the unchanged F2 pipeline.
struct SmartPlanReviewView: View {
    let targetGB: Int

    @State private var plan: SmartPlanner.Plan?
    @State private var includeVideos = true
    @State private var includeScreenshots = true
    @State private var includeOther = true

    private var activeSelection: [AssetRecord] {
        guard let plan else { return [] }
        var result: [AssetRecord] = []
        if includeVideos { result += plan.videoGroup }
        if includeScreenshots { result += plan.screenshotGroup }
        if includeOther { result += plan.otherGroup }
        return result
    }

    private var activeBytes: Int64 { activeSelection.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        List {
            if let plan {
                Section {
                    Text("Plan total: \(activeBytes.formattedBytes)")
                        .font(.headline)
                        .accessibilityIdentifier("planTotalLabel")
                }
                groupToggle("Videos", isOn: $includeVideos, group: plan.videoGroup)
                groupToggle("Screenshots", isOn: $includeScreenshots, group: plan.screenshotGroup)
                groupToggle("Other large items", isOn: $includeOther, group: plan.otherGroup)
            } else {
                ProgressView("Ranking candidates…")
            }
        }
        .navigationTitle("Free up \(targetGB) GB")
        .safeAreaInset(edge: .bottom) {
            if !activeSelection.isEmpty {
                SelectionOffloadBar(selection: activeSelection)
            }
        }
        .task { await buildPlan() }
    }

    private func groupToggle(_ title: String, isOn: Binding<Bool>, group: [AssetRecord]) -> some View {
        Section {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading) {
                    Text(title)
                    Text("\(group.count) items · \(group.reduce(0) { $0 + $1.bytes }.formattedBytes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.orange)
        }
    }

    private func buildPlan() async {
        let database = AppEnvironment.shared.database
        let records = (try? await AppEnvironment.shared.scanner.allRecords()) ?? []

        // Never re-propose assets already offloaded or currently queued (§3.2).
        let excluded: Set<String> = (try? database.writer.read { db in
            let history = try String.fetchAll(db, sql: "SELECT local_id FROM transfer_history WHERE local_id IS NOT NULL")
            let queued = try String.fetchAll(db, sql: "SELECT local_id FROM transfer_queue WHERE state != 'deleted'")
            return Set(history + queued)
        }) ?? []

        plan = SmartPlanner().plan(
            targetBytes: Int64(targetGB) * .gigabyte,
            from: records,
            excluding: excluded
        )
    }
}

/// Prefiltered selection opened from a rule card (F3.2).
struct PrefilteredSelectionView: View {
    let title: String
    let records: [AssetRecord]

    @State private var selectedIds: Set<String> = []

    private var selection: [AssetRecord] {
        records.filter { selectedIds.contains($0.localId) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(records, id: \.localId) { record in
                    Button {
                        if selectedIds.contains(record.localId) {
                            selectedIds.remove(record.localId)
                        } else {
                            selectedIds.insert(record.localId)
                        }
                    } label: {
                        AssetThumbnailView(localId: record.localId, side: 100)
                            .overlay(alignment: .topTrailing) {
                                if selectedIds.contains(record.localId) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.orange)
                                        .background(Circle().fill(.white))
                                        .padding(4)
                                }
                            }
                    }
                }
            }
            .padding(8)
        }
        .navigationTitle(title)
        .onAppear { selectedIds = Set(records.map(\.localId)) }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                SelectionOffloadBar(selection: selection)
            }
        }
    }
}
