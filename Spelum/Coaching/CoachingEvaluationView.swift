import SwiftUI
import UIKit

struct CoachingEvaluationView: View {
    @Environment(\.dismiss) private var dismiss

    private let runner = CoachingEvaluationRunner()
    private let sessionStore = CoachingEvaluationSessionStore()

    @State private var selectedTask: CoachingTaskKind = .preparation
    @State private var sessions: [CoachingTaskKind: CoachingEvaluationSession] = [:]
    @State private var dataset: CoachingEvaluationDataset?
    @State private var activeCaseIndex: Int?
    @State private var isRunning = false
    @State private var progressCompleted = 0
    @State private var progressTotal = 20
    @State private var runTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var copiedConfirmation = false
    @State private var showingRevealWarning = false

    private var currentSession: CoachingEvaluationSession? {
        sessions[selectedTask]
    }

    private var deviceEnvironment: CoachingDeviceEnvironment {
        CoachingDeviceEnvironment.current()
    }

    private var modelAvailability: CoachingModelAvailability {
        runner.coachService.modelAvailability()
    }

    var body: some View {
        NavigationStack {
            List {
                policyAndEnvironmentSection
                taskControlSection
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if let session = currentSession {
                    if session.isUnblinded {
                        CoachingEvaluationResultsSections(session: session)
                    }
                    casesListSection(session)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Coach Evaluation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("closeCoachEvaluationButton")
                }
            }
            .onAppear {
                loadInitialState()
            }
            .onDisappear {
                runTask?.cancel()
                runTask = nil
                isRunning = false
            }
            .sheet(
                isPresented: Binding(
                    get: { activeCaseIndex != nil },
                    set: { isPresented in
                        if !isPresented { activeCaseIndex = nil }
                    }
                )
            ) {
                caseRatingSheetContent
            }
            .confirmationDialog(
                "Reveal sources before all 20 cases are rated?",
                isPresented: $showingRevealWarning,
                titleVisibility: .visible
            ) {
                Button("Reveal Results") {
                    setUnblinded(true)
                }
                Button("Keep Blinded", role: .cancel) {}
            } message: {
                Text("Revealing early breaks blinding for remaining unrated cases.")
            }
        }
    }

    private var policyAndEnvironmentSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shipped Defaults: Authored Baseline")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "Both pre-practice and post-take stay on authored cues until physical-device " +
                    "blinded results reach 16/20 useful, 0 safety issues, and clear preference."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            LabeledContent("Device") {
                Text(
                    deviceEnvironment.isSimulator
                        ? "Simulator (\(deviceEnvironment.osDescription))"
                        : "\(deviceEnvironment.deviceModel) · \(deviceEnvironment.osDescription)"
                )
                .font(.footnote)
                .foregroundStyle(deviceEnvironment.isSimulator ? .orange : .primary)
            }

            LabeledContent("On-Device Model") {
                Text(modelAvailability.shortStatusLabel)
                    .font(.footnote)
                    .foregroundStyle(modelAvailability.isAvailable ? .green : .secondary)
            }
        } header: {
            Text("Internal Blinded Comparison")
        }
    }

    private var taskControlSection: some View {
        Section {
            Picker("Coach Task", selection: $selectedTask) {
                Text("Pre-Practice (20)").tag(CoachingTaskKind.preparation)
                Text("Post-Take (20)").tag(CoachingTaskKind.postTake)
            }
            .pickerStyle(.segmented)
            .disabled(isRunning)
            .accessibilityIdentifier("evaluationTaskPicker")

            if isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(progressCompleted), total: Double(max(1, progressTotal)))
                    Text("Running synthetic cases (\(progressCompleted)/\(progressTotal)) & repeat checks…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    startSuiteRun()
                } label: {
                    Label(
                        currentSession == nil
                            ? "Run 20-Case Blinded Suite"
                            : "Re-Run 20-Case Blinded Suite",
                        systemImage: "play.fill"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(dataset == nil)
                .accessibilityIdentifier("runBlindedSuiteButton")
            }

            if let session = currentSession {
                sessionActionsRow(session)
            }
        }
    }

    @ViewBuilder
    private func sessionActionsRow(_ session: CoachingEvaluationSession) -> some View {
        let stats = session.summary()
        LabeledContent("Progress") {
            Text("\(stats.ratedCases)/\(stats.totalCases) rated · \(session.isUnblinded ? "Unblinded" : "Blinded")")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if !session.isUnblinded {
            Button {
                if stats.ratedCases < stats.totalCases {
                    showingRevealWarning = true
                } else {
                    setUnblinded(true)
                }
            } label: {
                Label("Reveal Blinded Results", systemImage: "eye")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("revealBlindedResultsButton")
        } else {
            Button {
                UIPasteboard.general.string = session.markdownReport()
                copiedConfirmation = true
            } label: {
                Label(
                    copiedConfirmation ? "Copied Markdown Report" : "Copy Markdown Report",
                    systemImage: copiedConfirmation ? "checkmark" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("copyEvaluationReportButton")

            Button(role: .destructive) {
                clearCurrentSession()
            } label: {
                Label("Clear Saved Session", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("clearEvaluationSessionButton")
        }
    }

    private func casesListSection(_ session: CoachingEvaluationSession) -> some View {
        Section("Synthetic Cases (\(session.entries.count))") {
            ForEach(Array(session.entries.enumerated()), id: \.element.id) { index, entry in
                Button {
                    activeCaseIndex = index
                } label: {
                    CoachingEvaluationCaseRow(
                        index: index,
                        entry: entry,
                        isUnblinded: session.isUnblinded
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("evaluationCaseRow_\(entry.id)")
            }
        }
    }

    @ViewBuilder
    private var caseRatingSheetContent: some View {
        if let index = activeCaseIndex,
           let session = currentSession,
           session.entries.indices.contains(index) {
            CoachingEvaluationCaseSheet(
                entry: session.entries[index],
                caseIndex: index,
                totalCases: session.entries.count,
                isUnblinded: session.isUnblinded,
                hasNextCase: index + 1 < session.entries.count,
                onSave: { rating, advanceNext in
                    saveRating(rating, at: index, advanceNext: advanceNext)
                }
            )
            .id(session.entries[index].id)
        }
    }
}

private extension CoachingEvaluationView {
    func loadInitialState() {
        errorMessage = nil
        do {
            dataset = try CoachingEvaluationDataset.loadBundled()
        } catch {
            errorMessage = "Could not load bundled synthetic cases: \(error.localizedDescription)"
        }
        for task in CoachingTaskKind.allCases {
            if let saved = sessionStore.loadLatest(for: task) {
                sessions[task] = saved
            }
        }
    }

    func startSuiteRun() {
        guard let dataset else { return }
        runTask?.cancel()
        errorMessage = nil
        copiedConfirmation = false
        isRunning = true
        progressCompleted = 0
        let taskKind = selectedTask
        progressTotal = taskKind == .preparation
            ? dataset.preparationCases.count
            : dataset.postTakeCases.count
        let env = deviceEnvironment
        let localRunner = runner

        runTask = Task {
            let result = await localRunner.runSuite(
                task: taskKind,
                dataset: dataset,
                environment: env,
                onProgress: { completed, total in
                    Task { @MainActor in
                        progressCompleted = completed
                        progressTotal = total
                    }
                }
            )
            guard !Task.isCancelled else { return }
            sessions[taskKind] = result
            isRunning = false
            do {
                try sessionStore.save(result)
            } catch {
                errorMessage = "Session completed, but saving failed: \(error.localizedDescription)"
            }
        }
    }

    func saveRating(_ rating: BlindedCaseRating, at index: Int, advanceNext: Bool) {
        guard var session = sessions[selectedTask],
              session.entries.indices.contains(index) else {
            return
        }
        session.entries[index].rating = rating
        session.updatedAt = Date()
        sessions[selectedTask] = session
        try? sessionStore.save(session)
        if advanceNext, index + 1 < session.entries.count {
            activeCaseIndex = index + 1
        } else if !advanceNext {
            activeCaseIndex = nil
        }
    }

    func setUnblinded(_ unblinded: Bool) {
        guard var session = sessions[selectedTask] else { return }
        session.isUnblinded = unblinded
        session.updatedAt = Date()
        sessions[selectedTask] = session
        copiedConfirmation = false
        try? sessionStore.save(session)
    }

    func clearCurrentSession() {
        sessionStore.clear(for: selectedTask)
        sessions.removeValue(forKey: selectedTask)
        copiedConfirmation = false
    }
}
