import SwiftData
import SwiftUI

struct AttemptHistory: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let presentation: PresentationRecord
    let initialFilter: AttemptHistoryFilter
    let anchorAttemptID: UUID?
    let onOpenReview: (UUID) -> Void

    init(
        presentation: PresentationRecord,
        initialFilter: AttemptHistoryFilter = .all,
        anchorAttemptID: UUID? = nil,
        onOpenReview: @escaping (UUID) -> Void
    ) {
        self.presentation = presentation
        self.initialFilter = initialFilter
        self.anchorAttemptID = anchorAttemptID
        self.onOpenReview = onOpenReview
        self._selectedFilter = State(initialValue: initialFilter)
    }

    @Query(sort: \AttemptRecord.startedAt, order: .reverse)
    private var allAttempts: [AttemptRecord]

    @State private var selectedFilter: AttemptHistoryFilter
    @State private var showingComparisonSheet = false
    @State private var comparisonFirstID: UUID?
    @State private var comparisonSecondID: UUID?
    @State private var hasAutoOpenedAnchor = false
    @State private var attemptPendingDelete: AttemptRecord?
    @State private var errorMessage: String?

    private var presentationStore: PresentationStore {
        PresentationStore(modelContext: modelContext)
    }

    private var attemptStore: AttemptStore {
        AttemptStore(modelContext: modelContext)
    }

    private var presentationAttempts: [AttemptRecord] {
        allAttempts.filter { $0.presentationID == presentation.id && $0.status.isFinalized }
    }

    private var filteredAttempts: [AttemptRecord] {
        presentationAttempts.filter { selectedFilter.includes($0) }
    }

    private var currentSectionRevisionIDs: Set<UUID> {
        Set(presentationStore.orderedSections(for: presentation).map(\.revisionID))
    }

    private var defaultComparablePair: DefaultComparisonSelection? {
        let descriptors = presentationAttempts.map(ComparableAttemptDescriptor.init(record:))
        return AttemptComparisonEngine.defaultComparablePair(
            from: descriptors,
            filter: selectedFilter,
            anchorAttemptID: nil,
            currentTalkRevisionID: presentation.currentRevisionID,
            currentSectionRevisionIDs: currentSectionRevisionIDs
        )
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if !presentationAttempts.isEmpty {
                filterSection
                comparisonSection
            }

            historyListSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Attempt History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            autoOpenAnchorComparisonIfNeeded()
        }
        .sheet(isPresented: $showingComparisonSheet) {
            NavigationStack {
                AttemptComparisonView(
                    presentation: presentation,
                    initialFirstID: comparisonFirstID,
                    initialSecondID: comparisonSecondID,
                    onOpenReview: { attemptID in
                        showingComparisonSheet = false
                        onOpenReview(attemptID)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showingComparisonSheet = false
                        }
                        .accessibilityIdentifier("closeComparisonSheetButton")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this rehearsal attempt?",
            isPresented: Binding(
                get: { attemptPendingDelete != nil },
                set: { if !$0 { attemptPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Attempt", role: .destructive) {
                if let target = attemptPendingDelete {
                    attemptPendingDelete = nil
                    deleteAttempt(target)
                }
            }
            Button("Cancel", role: .cancel) { attemptPendingDelete = nil }
        } message: {
            Text("This removes only this attempt and its local audio file from this device.")
        }
    }

    private var filterSection: some View {
        Section {
            if dynamicTypeSize.isAccessibilitySize {
                ForEach(AttemptHistoryFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        HStack {
                            Text(filter.displayName)
                            Spacer()
                            if selectedFilter == filter {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                    .accessibilityIdentifier("historyFilter_\(filter.rawValue)")
                }
            } else {
                Picker("Filter History", selection: $selectedFilter) {
                    ForEach(AttemptHistoryFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Filter Attempt History")
                .accessibilityIdentifier("historyFilterPicker")
            }
        }
    }

    @ViewBuilder
    private var comparisonSection: some View {
        if presentationAttempts.count >= 2 {
            Section {
                if let pair = defaultComparablePair {
                    Button {
                        comparisonFirstID = pair.earlierID
                        comparisonSecondID = pair.laterID
                        showingComparisonSheet = true
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Compare Latest Matching Pair", systemImage: "arrow.left.arrow.right")
                                .font(.headline)
                            Text(pair.scope.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("compareDefaultPairButton")
                }

                Button {
                    comparisonFirstID = nil
                    comparisonSecondID = nil
                    showingComparisonSheet = true
                } label: {
                    Label(
                        defaultComparablePair == nil
                            ? "Compare Two Attempts"
                            : "Choose Different Pair to Compare",
                        systemImage: "slider.horizontal.3"
                    )
                }
                .accessibilityIdentifier("compareCustomPairButton")
            } header: {
                Text("Progress Comparison")
            } footer: {
                Text(
                    defaultComparablePair != nil
                        ? "Defaults to two takes of the same section revision or two full runs " +
                            "of the same talk revision and scope."
                        : "Record two takes of the same section revision or two runs of the " +
                            "same talk revision and scope for a direct comparison."
                )
            }
        }
    }

    private var historyListSection: some View {
        Section {
            if filteredAttempts.isEmpty {
                ContentUnavailableView(
                    "No Saved Attempts",
                    systemImage: "clock",
                    description: Text(
                        selectedFilter == .fullRuns
                            ? "Completed, early-finished, interrupted, and silent full runs will appear here."
                            : "Your saved section takes and full runs will appear here in chronological order."
                    )
                )
            } else {
                ForEach(filteredAttempts, id: \.id) { attempt in
                    let isOlder = ComparableAttemptDescriptor(record: attempt).isOlderRevision(
                        currentTalkRevisionID: presentation.currentRevisionID,
                        currentSectionRevisionIDs: currentSectionRevisionIDs
                    )
                    Button {
                        onOpenReview(attempt.id)
                    } label: {
                        AttemptHistoryRowContent(
                            attempt: attempt,
                            isOlderRevision: isOlder,
                            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                        )
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("attemptHistoryRow_\(attempt.id.uuidString)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            attemptPendingDelete = attempt
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Chronological History (\(filteredAttempts.count))")
        } footer: {
            Text(
                "Tap any attempt to replay its snapshotted script and audio. " +
                "Older revisions stay labeled explicitly."
            )
        }
    }
}

private extension AttemptHistory {
    func autoOpenAnchorComparisonIfNeeded() {
        guard let anchorAttemptID, !hasAutoOpenedAnchor, presentationAttempts.count >= 2 else {
            return
        }
        hasAutoOpenedAnchor = true
        let descriptors = presentationAttempts.map(ComparableAttemptDescriptor.init(record:))
        if let pair = AttemptComparisonEngine.defaultComparablePair(
            from: descriptors,
            filter: selectedFilter,
            anchorAttemptID: anchorAttemptID,
            currentTalkRevisionID: presentation.currentRevisionID,
            currentSectionRevisionIDs: currentSectionRevisionIDs
        ) {
            comparisonFirstID = pair.earlierID
            comparisonSecondID = pair.laterID
        } else {
            comparisonFirstID = anchorAttemptID
            comparisonSecondID = filteredAttempts.first(where: { $0.id != anchorAttemptID })?.id
                ?? presentationAttempts.first(where: { $0.id != anchorAttemptID })?.id
        }
        showingComparisonSheet = true
    }

    func deleteAttempt(_ attempt: AttemptRecord) {
        errorMessage = nil
        do {
            try attemptStore.deleteAttempt(attempt)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
