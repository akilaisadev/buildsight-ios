import SwiftUI
import BuildSightKit

struct InspectionListView: View {
    @EnvironmentObject private var context: ScreenContext
    @State private var showStart = false

    var body: some View {
        List {
            if let s = context.data.snapshot {
                let inProgress = s.inspections.filter { $0.status == .inProgress }
                let done = s.inspections.filter { $0.status == .completed }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                if s.inspections.isEmpty { EmptyStateView(symbol: "checkmark.seal", title: "No inspections yet", message: "Start a checklist inspection for an area.").listRowBackground(Color.clear) }
                if !inProgress.isEmpty { Section("In progress") { ForEach(inProgress) { row($0, s) } } }
                if !done.isEmpty { Section("History") { ForEach(done) { row($0, s) } } }
            }
        }
        .navigationTitle("Inspections")
        .toolbar { if context.actor.role.can(.runInspection) { ToolbarItem(placement: .topBarTrailing) { Button { showStart = true } label: { Image(systemName: "plus") }.accessibilityLabel("Start inspection") } } }
        .sheet(isPresented: $showStart) { StartInspectionView() }
    }

    private func row(_ i: Inspection, _ s: ProjectSnapshot) -> some View {
        NavigationLink(value: Route.inspection(i.id)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    switch i.outcome {
                    case .passed?: StatusChip(label: "Passed", symbol: "checkmark.circle.fill", tone: "success")
                    case .failed?: StatusChip(label: "Failed", symbol: "xmark.octagon.fill", tone: "critical")
                    case nil: StatusChip(label: "\(i.answeredCount)/\(i.items.count) answered", symbol: "clock.fill", tone: "info")
                    }
                    if i.emergencyStop?.isActive == true { StatusChip(label: "Stop-work notice", symbol: "hand.raised.fill", tone: "critical") }
                }
                Text(i.templateName).font(.headline)
                Text("\(s.areaName(i.areaID)) · \(s.memberName(i.inspectorID))").font(.subheadline).foregroundStyle(Theme.secondaryText)
            }.accessibilityElement(children: .combine)
        }
    }
}

struct StartInspectionView: View {
    @EnvironmentObject private var context: ScreenContext
    @Environment(\.dismiss) private var dismiss
    @State private var template = InspectionRules.builtInTemplates[0]
    @State private var areaID: UUID?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Checklist", selection: $template) { ForEach(InspectionRules.builtInTemplates) { Text($0.name).tag($0) } }
                Picker("Area", selection: $areaID) { Text("Choose area").tag(UUID?.none); ForEach(context.data.snapshot?.areas ?? []) { Text($0.displayName).tag(Optional($0.id)) } }
                Section("Items") { ForEach(template.itemTitles, id: \.self) { Text($0) } }
                if let error { ErrorBanner(message: error) }
            }
            .navigationTitle("Start Inspection").inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        guard let areaID else { return }
                        Task {
                            let fix = await context.workspace.location.currentFix(timeout: 4)
                            do { _ = try await InspectionRepository(store: context.store).start(template: template, areaID: areaID, actor: context.actor, location: fix, now: Date()); await context.sync.requestSync(); dismiss() }
                            catch { self.error = "Couldn't start the inspection." }
                        }
                    }.disabled(areaID == nil)
                }
            }
        }
    }
}

struct InspectionRunView: View {
    let inspectionID: UUID
    @EnvironmentObject private var context: ScreenContext
    @State private var model: InspectionRunViewModel?
    @State private var showStop = false
    @State private var stopReason = ""

    var body: some View {
        Group {
            if let model {
                @Bindable var model = model
                List {
                    if model.inspection.emergencyStop?.isActive == true {
                        Section { Label("Stop-work notice raised: \(model.inspection.emergencyStop?.reason ?? ""). This is a digital notice; it does not stop equipment.", systemImage: "hand.raised.fill").foregroundStyle(Theme.status("critical").fg) }
                    }
                    Section { Text(model.progress).font(.subheadline).foregroundStyle(Theme.secondaryText) }
                    ForEach(model.inspection.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.headline)
                            Picker("Result", selection: Binding(get: { item.result }, set: { if let r = $0 { model.set(r, for: item.id) } })) {
                                ForEach(ChecklistResult.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                            }.pickerStyle(.segmented).disabled(model.isReadOnly)
                            TextField("Note", text: Binding(get: { item.note }, set: { model.setNote($0, for: item.id) }), axis: .vertical).disabled(model.isReadOnly)
                        }
                    }
                    if let m = model.errorMessage { Section { ErrorBanner(message: m) } }
                    if !model.isReadOnly {
                        Section {
                            Button("Save Progress") { Task { await model.saveProgress() } }.buttonStyle(SecondaryButtonStyle())
                            Button("Complete Inspection") { Task { await model.complete() } }.buttonStyle(PrimaryButtonStyle())
                            if context.actor.role.can(.raiseEmergencyStop), model.inspection.emergencyStop == nil {
                                Button(role: .destructive) { showStop = true } label: { Label("Raise Emergency Stop", systemImage: "hand.raised.fill").frame(maxWidth: .infinity, minHeight: 44) }
                            }
                        } footer: { Text("An emergency stop creates a Critical safety issue and notifies the project. It is a record in BuildSight, not a control for machinery.") }
                        .listRowBackground(Color.clear)
                    } else if let outcome = model.inspection.outcome {
                        Section { Label(outcome == .passed ? "Inspection passed" : "Inspection failed", systemImage: outcome == .passed ? "checkmark.circle.fill" : "xmark.octagon.fill") }
                    }
                }
                .sheet(isPresented: $showStop) {
                    NavigationStack {
                        Form { Section("Why is work being stopped?") { TextField("Reason (required)", text: $stopReason, axis: .vertical).lineLimit(2...5) } }
                            .navigationTitle("Emergency Stop").inlineNavigationTitle()
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showStop = false } }
                                ToolbarItem(placement: .confirmationAction) { Button("Raise") { Task { if await model.raiseEmergencyStop(reason: stopReason) { showStop = false } } }.disabled(stopReason.trimmingCharacters(in: .whitespaces).isEmpty) }
                            }
                    }
                }
            } else { ProgressView() }
        }
        .navigationTitle("Inspection").inlineNavigationTitle()
        .task(id: context.data.snapshot != nil) {
            guard model == nil, let i = context.data.snapshot?.inspections.first(where: { $0.id == inspectionID }) else { return }
            model = InspectionRunViewModel(inspection: i, actor: context.actor, repository: InspectionRepository(store: context.store), session: context.workspace.sessionGate, sync: context.sync)
        }
    }
}
