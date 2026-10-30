import SwiftUI
import BuildSightKit

struct IssueRow: View {
    let issue: Issue
    let snapshot: ProjectSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { PriorityChip(priority: issue.priority); IssueStatusChip(status: issue.status); Spacer() }
            Text(issue.title).font(.headline)
            Label(snapshot.areaName(issue.areaID), systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(Theme.secondaryText)
            if issue.isMachineGenerated { ReviewChip(review: issue.review) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct IssueListView: View {
    @EnvironmentObject private var context: ScreenContext
    @State private var model: IssueListViewModel
    @State private var showReport = false

    init(filter: IssueFilter) { _model = State(initialValue: IssueListViewModel(filter: filter)) }

    var body: some View {
        Group {
            if let snapshot = context.data.snapshot {
                let issues = model.issues(in: snapshot)
                List {
                    if issues.isEmpty {
                        EmptyStateView(symbol: "checkmark.bubble", title: "No matching issues", message: model.filter == IssueFilter() ? "Nothing has been reported on this project yet." : "No issues match this filter.")
                            .listRowBackground(Color.clear)
                    }
                    ForEach(issues) { issue in
                        NavigationLink(value: Route.issue(issue.id)) { IssueRow(issue: issue, snapshot: snapshot) }
                    }
                }
            } else { ProgressView() }
        }
        .navigationTitle(model.filter.machineGeneratedOnly ? "Helmet Flags" : "Issues")
        .searchable(text: $model.search, prompt: "Search issues")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $model.sort) { Text("Priority").tag(IssueSort.priority); Text("Newest").tag(IssueSort.newest) }
                    Toggle("Open only", isOn: $model.filter.openOnly)
                    Toggle("Helmet flags only", isOn: $model.filter.machineGeneratedOnly)
                    Toggle("Awaiting review only", isOn: $model.filter.unreviewedOnly)
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel("Filter and sort")
            }
            ToolbarItem(placement: .topBarTrailing) { Button { showReport = true } label: { Image(systemName: "plus") }.accessibilityLabel("Report an issue") }
        }
        .sheet(isPresented: $showReport) { ReportIssueView() }
    }
}

/// iPad record review: the list stays on the left while the selected issue
/// opens beside it, so a supervisor can work through a queue without losing place.
struct IssueReviewSplit: View {
    @EnvironmentObject private var context: ScreenContext
    @State private var model: IssueListViewModel
    @State private var selected: UUID?

    init(filter: IssueFilter) { _model = State(initialValue: IssueListViewModel(filter: filter)) }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let snapshot = context.data.snapshot {
                    List(model.issues(in: snapshot), selection: $selected) { issue in
                        IssueRow(issue: issue, snapshot: snapshot).tag(issue.id)
                    }
                    .overlay { if model.issues(in: snapshot).isEmpty { EmptyStateView(symbol: "checkmark.bubble", title: "No matching issues", message: "Nothing to review here.") } }
                } else { ProgressView() }
            }
            .frame(width: 380)
            Divider()
            Group {
                if let selected { IssueDetailView(issueID: selected).id(selected) }
                else { EmptyStateView(symbol: "sidebar.right", title: "Select an issue", message: "Evidence, history and review actions appear here.") }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(model.filter.machineGeneratedOnly ? "Helmet Flags" : "Issues")
        .searchable(text: $model.search, prompt: "Search issues")
    }
}

struct IssueDetailView: View {
    let issueID: UUID
    @EnvironmentObject private var context: ScreenContext
    @State private var model: IssueDetailViewModel?
    @State private var reasonTransition: IssueTransition?
    @State private var showReview = false
    @State private var showAssign = false

    var body: some View {
        ScrollView {
            if let snapshot = context.data.snapshot, let issue = snapshot.issue(issueID), let model {
                VStack(alignment: .leading, spacing: 16) {
                    evidence(issue, snapshot)          // photo first: what workers recognise fastest
                    header(issue, snapshot)
                    if issue.isMachineGenerated { machineSection(issue, snapshot, model) }
                    actions(issue, model)
                    if let message = model.errorMessage { ErrorBanner(message: message) }
                    history(model, snapshot)
                    commentBox(model)
                }
                .padding(16)
            } else if context.data.snapshot != nil { EmptyStateView(symbol: "questionmark.folder", title: "Issue not found", message: "It may belong to another project or hasn't synced to this device.") }
            else { ProgressView() }
        }
        .background(Theme.background)
        .navigationTitle("Issue").inlineNavigationTitle()
        .task {
            if model == nil {
                model = IssueDetailViewModel(issueID: issueID, actor: context.actor, issues: context.issues, workflow: context.workspace.helmet, session: context.workspace.sessionGate, sync: context.sync)
            }
            await model?.loadEvents()
        }
        .onChange(of: context.data.snapshot?.issues.first { $0.id == issueID }?.updatedAt) { _, _ in Task { await model?.loadEvents() } }
        .sheet(item: Binding(get: { reasonTransition.map(ReasonRequest.init) }, set: { if $0 == nil { reasonTransition = nil } })) { request in
            ReasonSheet(title: request.transition.displayName) { reason in Task { _ = await model?.perform(request.transition, reason: reason) } }
        }
    }

    private func header(_ issue: Issue, _ s: ProjectSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack { PriorityChip(priority: issue.priority); IssueStatusChip(status: issue.status) }
                Text(issue.title).font(.title2.bold())
                if !issue.details.isEmpty { Text(issue.details) }
                Divider()
                meta("Category", issue.category.displayName)
                meta("Area", s.areaName(issue.areaID))
                meta("Assignee", s.memberName(issue.assigneeID))
                meta("Reported by", s.memberName(issue.reporterID))
                meta("Created", formatted(issue.createdAt))
                if let due = issue.dueDate { meta("Due", formatted(due)) }
                meta("Location", locationText(issue.location))
                HStack { Text("Sync").foregroundStyle(Theme.secondaryText); Spacer(); SyncStateLabel(recordID: issue.id) }.font(.subheadline)
            }
        }
    }

    private func meta(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(k).foregroundStyle(Theme.secondaryText); Spacer(); Text(v).multilineTextAlignment(.trailing) }
            .font(.subheadline).accessibilityElement(children: .combine)
    }

    private func locationText(_ fix: LocationFix) -> String {
        guard let p = fix.point else { return "No GPS position (site area only)" }
        return String(format: "%.5f, %.5f (±%d m%@)", p.latitude, p.longitude, Int(p.horizontalAccuracy), fix.isApproximate ? ", approximate" : "")
    }

    @ViewBuilder private func evidence(_ issue: Issue, _ s: ProjectSnapshot) -> some View {
        ForEach(issue.evidencePhotoIDs, id: \.self) { id in
            if let photo = s.photo(id) {
                NavigationLink(value: Route.photo(id)) {
                    EvidenceImage(photo: photo, files: context.files, analysis: s.analyses.first { $0.photoID == id }).clipShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            } else { Label("Evidence photo hasn't synced to this device yet", systemImage: "photo.badge.exclamationmark").foregroundStyle(Theme.secondaryText) }
        }
    }

    private func machineSection(_ issue: Issue, _ s: ProjectSnapshot, _ model: IssueDetailViewModel) -> some View {
        let analysis = s.analyses.first { $0.id == issue.sourceAnalysisID }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Machine-generated flag")
                ReviewChip(review: issue.review)
                if let analysis {
                    Text(analysis.outcome?.summary ?? "Analysis unavailable").font(.headline)
                    if let equipment = analysis.equipment { Text(equipment.summary).font(.subheadline) }
                    Text("Model \(analysis.modelIdentifier) \(analysis.modelVersion) · policy \(analysis.policyVersion) · \(formatted(analysis.analysedAt))").font(.caption).foregroundStyle(Theme.secondaryText)
                    Text("Scores are the model's raw confidence, not calibrated probabilities.").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                if model.canReviewFlag(issue), let analysis {
                    Button("Review Flag") { showReview = true }.buttonStyle(PrimaryButtonStyle())
                        .sheet(isPresented: $showReview) { HelmetReviewSheet(analysis: analysis, model: model) }
                } else if issue.review == .awaitingReview {
                    Text("A supervisor, inspector or project manager needs to review this flag.").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private func actions(_ issue: Issue, _ model: IssueDetailViewModel) -> some View {
        VStack(spacing: 10) {
            ForEach(model.availableTransitions(for: issue), id: \.self) { t in
                Button(t.displayName) {
                    if t.requiresReason { reasonTransition = t } else { Task { _ = await model.perform(t) } }
                }
                .buttonStyle(t == .rework || t == .reopen ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
            }
            Button("Assign…") { showAssign = true }.buttonStyle(SecondaryButtonStyle())
                .sheet(isPresented: $showAssign) { AssignSheet(issue: issue, model: model) }
        }
    }

    private func history(_ model: IssueDetailViewModel, _ s: ProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "History")
            ForEach(model.events) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.describe(e, s)).font(.subheadline.weight(.semibold))
                    if let note = e.note, !note.isEmpty { Text(note).font(.subheadline) }
                    Text("\(s.memberName(e.actorID)) · \(formatted(e.at))").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                Divider()
            }
        }
    }

    static func describe(_ e: IssueEvent, _ s: ProjectSnapshot) -> String {
        switch e.kind {
        case .created: "Created"
        case .statusChanged(let from, let to): "\(from.displayName) → \(to.displayName)"
        case .assigned(let to): to.map { "Assigned to \(s.memberName($0))" } ?? "Unassigned"
        case .priorityChanged(let a, let b): "Priority \(a.displayName) → \(b.displayName)"
        case .commented: "Comment"
        case .photoAttached: "Photo attached"
        case .machineReview(let r): "Flag \(r == .dismissed ? "dismissed" : r == .corrected ? "corrected" : "confirmed")"
        case .reanalysed: "Photo analysed again"
        }
    }

    private func commentBox(_ model: IssueDetailViewModel) -> some View {
        @Bindable var model = model
        return HStack(alignment: .bottom) {
            TextField("Add a comment", text: $model.comment, axis: .vertical).lineLimit(1...4)
                .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            Button { Task { await model.addComment() } } label: { Image(systemName: "paperplane.fill").frame(width: 44, height: 44) }
                .accessibilityLabel("Send comment").disabled(model.comment.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

private struct ReasonRequest: Identifiable { let transition: IssueTransition; var id: String { transition.rawValue } }
extension ReasonRequest: Equatable {}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct SyncStateLabel: View {
    let recordID: UUID
    @EnvironmentObject private var context: ScreenContext
    @State private var state: SyncState?
    var body: some View {
        SyncBadge(state: state)
            .task(id: recordID) { for await _ in context.store.changes() { state = try? await context.store.syncState(of: recordID) }  }
            .task { state = try? await context.store.syncState(of: recordID) }
    }
}

struct ReasonSheet: View {
    let title: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var tried = false
    @EnvironmentObject private var toaster: Toaster
    var body: some View {
        NavigationStack {
            Form {
                Section("Reason (recorded in the history)") {
                    TextField("Why? (required)", text: $reason, axis: .vertical).lineLimit(2...5)
                    if tried, reason.isBlank { FieldError(message: "Enter a reason.") }
                }
            }
                .toastHost(toaster)
                .navigationTitle(title).inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Confirm") {
                        tried = true
                        guard !reason.isBlank else { toaster.error("Enter a reason."); return }
                        onSubmit(reason); dismiss(); toaster.success("Saved")
                    } }
                }
        }
        .presentationDetents([.medium])
    }
}

struct AssignSheet: View {
    let issue: Issue
    let model: IssueDetailViewModel
    @EnvironmentObject private var context: ScreenContext
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Button("Unassigned") { Task { await model.assign(to: nil); dismiss() } }
                ForEach(context.data.snapshot?.members ?? []) { m in
                    Button { Task { await model.assign(to: m.userID); dismiss() } } label: {
                        HStack { VStack(alignment: .leading) { Text(m.displayName); Text(m.role.displayName).font(.caption).foregroundStyle(Theme.secondaryText) }; Spacer(); if issue.assigneeID == m.userID { Image(systemName: "checkmark").accessibilityLabel("Assigned") } }.frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle("Assign").inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct HelmetReviewSheet: View {
    let analysis: HelmetAnalysis
    let model: IssueDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var count = 1
    @State private var note = ""
    @State private var tried = false
    @EnvironmentObject private var toaster: Toaster

    var body: some View {
        NavigationStack {
            Form {
                Section { GloveChoice(options: [GloveOption(label: "Confirm", symbol: "checkmark", value: 0, tone: "success"), GloveOption(label: "Correct", symbol: "pencil", value: 1, tone: "info"), GloveOption(label: "Dismiss", symbol: "xmark", value: 2, tone: "low")], selection: $mode).listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)) }
                switch mode {
                case 0: Section { Text("Confirms that a worker in this photo is not wearing a helmet. The issue stays open for follow-up.") }
                case 1:
                    Section("Workers actually without a helmet") { Stepper("\(count)", value: $count, in: 1...20) }
                    Section("Note") { TextField("What did you see?", text: $note, axis: .vertical) }
                default:
                    Section("Why is this a false alarm?") {
                        TextField("Reason (required)", text: $note, axis: .vertical).lineLimit(2...5)
                        if tried, note.isBlank { FieldError(message: "Say why this is a false alarm.") }
                    }
                }
                if let message = model.errorMessage { ErrorBanner(message: message) }
            }
            .navigationTitle("Review Helmet Flag").inlineNavigationTitle()
            .toastHost(toaster)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if mode == 2, note.isBlank { tried = true; toaster.error("Say why this is a false alarm."); return }
                        let decision: HelmetReviewDecision = mode == 0 ? .confirm : mode == 1 ? .correct(confirmedCount: count, note: note) : .dismiss(reason: note)
                        Task { if await model.review(decision, analysisID: analysis.id) { dismiss(); toaster.success("Review saved") } }
                    }
                }
            }
        }
    }
}

struct ReportIssueView: View {
    @EnvironmentObject private var context: ScreenContext
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReportIssueViewModel?
    @State private var drafts: [IssueDraft] = []
    @State private var showErrors = false
    @EnvironmentObject private var toaster: Toaster

    var body: some View {
        NavigationStack {
            Group {
                if let model { form(model) } else { ProgressView() }
            }
            .navigationTitle("Report Issue").inlineNavigationTitle()
            .toastHost(toaster)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Save Draft") { Task { await model?.saveDraft(); dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        showErrors = true
                        guard let model else { return }
                        guard model.canSubmit else { toaster.error("Add a title and choose a site area."); return }
                        Task { if await model.submit() { dismiss(); toaster.success("Issue reported") } else { toaster.error(model.errorMessage ?? "Couldn't save the issue.") } }
                    }
                }
            }
        }
        .task {
            let existing = (try? await context.store.drafts(projectID: context.actor.projectID)) ?? []
            model = ReportIssueViewModel(draft: existing.first, actor: context.actor, issues: context.issues, store: context.store, location: context.workspace.location, sync: context.sync)
        }
    }

    private func form(_ model: ReportIssueViewModel) -> some View {
        @Bindable var model = model
        return Form {
            Section("What happened") {
                TextField("Title (required)", text: $model.draft.title)
                if showErrors, model.draft.title.isBlank { FieldError(message: "Enter a title for the issue.") }
                TextField("Description", text: $model.draft.details, axis: .vertical).lineLimit(3...8)
            }
            Section("Classification") {
                Picker("Category", selection: $model.draft.category) { ForEach(IssueCategory.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                Picker("Priority", selection: $model.draft.priority) { ForEach(Priority.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            }
            Section("Where and who") {
                Picker("Site area", selection: $model.draft.areaID) {
                    Text("Choose area").tag(UUID?.none)
                    ForEach(context.data.snapshot?.areas ?? []) { Text($0.displayName).tag(Optional($0.id)) }
                }
                if showErrors, model.draft.areaID == nil { FieldError(message: "Choose the site area where this happened.") }
                Picker("Assignee", selection: $model.draft.assigneeID) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(context.data.snapshot?.members ?? []) { Text($0.displayName).tag(Optional($0.userID)) }
                }
                Toggle("Due date", isOn: Binding(get: { model.draft.dueDate != nil }, set: { model.draft.dueDate = $0 ? Date().addingTimeInterval(86400) : nil }))
                if model.draft.dueDate != nil { DatePicker("Due", selection: Binding(get: { model.draft.dueDate ?? Date() }, set: { model.draft.dueDate = $0 })) }
            }
            if !model.draft.photoIDs.isEmpty { Section("Evidence") { Text("\(model.draft.photoIDs.count) photo(s) attached") } }
            if let message = model.errorMessage { Section { ErrorBanner(message: message) } }
        }
    }
}

struct PhotoDetailView: View {
    let photoID: UUID
    @EnvironmentObject private var context: ScreenContext
    @State private var showOverlay = true
    @State private var busy = false

    var body: some View {
        ScrollView {
            if let s = context.data.snapshot, let photo = s.photo(photoID) {
                let analysis = s.analyses.first { $0.photoID == photoID }
                VStack(alignment: .leading, spacing: 16) {
                    EvidenceImage(photo: photo, files: context.files, analysis: analysis, showsOverlay: showOverlay).clipShape(RoundedRectangle(cornerRadius: 12))
                    if analysis != nil { Toggle("Show helmet boxes", isOn: $showOverlay).frame(minHeight: Glove.target) }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(photo.note.isEmpty ? "Photo" : photo.note).font(.headline)
                            Label(s.areaName(photo.areaID), systemImage: "mappin.and.ellipse")
                            Label("\(formatted(photo.capturedAt)) · \(s.memberName(photo.creatorID))", systemImage: "clock")
                            Label(photo.location.point.map { String(format: "%.5f, %.5f (±%d m)", $0.latitude, $0.longitude, Int($0.horizontalAccuracy)) } ?? "No GPS position", systemImage: "location")
                            HStack { SyncStateLabel(recordID: photo.id) }
                        }.font(.subheadline)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Helmet check")
                            Text(analysisSummary(analysis)).font(.subheadline)
                            Button { busy = true; Task { _ = try? await context.workspace.helmet.analyse(photo: photo, now: Date()); await context.sync.requestSync(); busy = false } } label: { busy ? AnyView(ProgressView()) : AnyView(Text("Analyse Again")) }
                                .buttonStyle(SecondaryButtonStyle()).disabled(busy)
                        }
                    }
                    ShareLink(item: context.files.url(forFilename: photo.localFilename), preview: SharePreview(photo.note.isEmpty ? "BuildSight evidence" : photo.note)) { Label("Share Original Photo", systemImage: "square.and.arrow.up") }
                        .buttonStyle(SecondaryButtonStyle())
                }.padding()
            } else { ProgressView().padding() }
        }
        .background(Theme.background).navigationTitle("Photo").inlineNavigationTitle()
    }

    private func analysisSummary(_ a: HelmetAnalysis?) -> String {
        guard let a else { return "Not analysed yet." }
        switch a.state { case .finished(let o): return o.summary; case .failed(let m): return m; case .pending: return "Analysing…" }
    }
}
