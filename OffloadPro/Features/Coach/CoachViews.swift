import SwiftUI
import UIKit

/// F5 Storage Coach: checklist with progress ring + estimated GB recoverable.
struct CoachListView: View {
    @State private var tasks: [CoachTask] = []
    @State private var doneIds: Set<String> = []

    private var totalEstGB: Double { tasks.reduce(0) { $0 + $1.estGB } }
    private var doneEstGB: Double {
        tasks.filter { doneIds.contains($0.id) }.reduce(0) { $0 + $1.estGB }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        ProgressRing(fraction: tasks.isEmpty ? 0 : Double(doneIds.count) / Double(tasks.count))
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(doneIds.count) of \(tasks.count) done")
                                .font(.headline)
                            Text(String(format: "Up to %.1f GB recoverable with Apple's hidden features", totalEstGB - doneEstGB))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                Section("Guides") {
                    ForEach(tasks) { task in
                        NavigationLink {
                            CoachTaskDetailView(task: task, isDone: doneIds.contains(task.id)) { done in
                                Task { await setDone(done, taskId: task.id) }
                            }
                        } label: {
                            HStack {
                                Image(systemName: doneIds.contains(task.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(doneIds.contains(task.id) ? .green : .secondary)
                                VStack(alignment: .leading) {
                                    Text(task.title).font(.subheadline)
                                    if task.estGB > 0 {
                                        Text(String(format: "~%.1f GB", task.estGB))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Storage Coach")
            .task { await reload() }
        }
    }

    private func reload() async {
        let coach = AppEnvironment.shared.coach
        tasks = await coach.visibleTasks()
        doneIds = (try? await coach.doneTaskIds()) ?? []
    }

    private func setDone(_ done: Bool, taskId: String) async {
        let coach = AppEnvironment.shared.coach
        if done {
            try? await coach.markDone(taskId: taskId)
        } else {
            try? await coach.markUndone(taskId: taskId)
        }
        await reload()
    }
}

/// Step carousel with "Mark done" (§5.1.2). No Settings deep links — text
/// instructions only, per App Review policy (F5.2).
struct CoachTaskDetailView: View {
    let task: CoachTask
    let isDone: Bool
    let onToggleDone: (Bool) -> Void

    @State private var localDone: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            TabView {
                ForEach(Array(task.steps.enumerated()), id: \.offset) { index, step in
                    VStack(spacing: 16) {
                        if let asset = step.imageAsset, UIImage(named: asset) != nil {
                            Image(asset)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        } else {
                            Image(systemName: "iphone")
                                .font(.system(size: 64))
                                .foregroundStyle(.secondary)
                        }
                        Text("Step \(index + 1) of \(task.steps.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(step.text)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Spacer()
                    }
                    .padding(.top, 24)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                localDone.toggle()
                onToggleDone(localDone)
            } label: {
                Text(localDone ? "Done ✓" : "Mark Done")
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(localDone ? .green : .orange)
            .padding()
        }
        .navigationTitle(task.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { localDone = isDone }
    }
}

struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(fraction * 100))%")
                .font(.caption.bold())
        }
        .accessibilityLabel("\(Int(fraction * 100)) percent complete")
    }
}
