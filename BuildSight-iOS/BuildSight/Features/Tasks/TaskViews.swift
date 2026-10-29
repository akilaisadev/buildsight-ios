import SwiftUI
import BuildSightKit

struct TaskListView: View {
    @EnvironmentObject private var context: ScreenContext
    @State private var model: TaskListViewModel?
    @State private var showCreate = false
    let initialBucket: TaskBucket

    var body: some View {
        VStack(spacing: 0) {
            if let model, let snapshot = context.data.snapshot {
                @Bindable var model = model
                Picker("Group", selection: $model.bucket) { ForEach(TaskBucket.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    .pickerStyle(.segmented).padding()
                let groups = model.grouped(snapshot)
                let tasks = groups[model.bucket] ?? []
                List {
                    if tasks.isEmpty { EmptyStateView(symbol: "checklist", title: "Nothing \(model.bucket.displayName.lowercased())", message: "Tasks assigned on this project will appear here.").listRowBackground(Color.clear) }
                    ForEach(tasks) { task in
                        NavigationLink(value: Route.task(task.id)) { TaskRow(task: task, snapshot: snapshot, bucket: model.bucket) }
                            .swipeActions { swipe(task, model) }
                    }
                }
                if let message = model.errorMessage { ErrorBanner(message: message).padding() }
            } else { ProgressView().frame(maxHeight: .infinity) }
        }
        .navigationTitle("Tasks")
        .toolbar { if model?.canCreate == true { ToolbarItem(placement: .topBarTrailing) { Button { showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("New task") } } }
        .sheet(isPresented: $showCreate) { if let model { CreateTaskView(model: model) } }
        .task { if model == nil { model = TaskListViewModel(initialBucket: initialBucket, actor: context.actor, tasks: TaskRepository(store: context.store), sync: context.sync) } }
    }

    @ViewBuilder private func swipe(_ task: TaskItem, _ model: TaskListViewModel) -> some View {
        switch task.status {
        case .notStarted: Button("Start") { Task { await model.perform(.start, on: task.id) } }.tint(Theme.status("info").fg)
        case .inProgress: Button("Complete") { Task { await model.perform(.complete, on: task.id) } }.tint(Theme.status("success").fg)
        case .completed: Button("Reopen") { Task { await model.perform(.reopen, on: task.id) } }
        }
    }
}

struct TaskRow: View {
    let task: TaskItem
    let snapshot: ProjectSnapshot
    let bucket: TaskBucket
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { PriorityChip(priority: task.priority); StatusChip(label: bucket == .overdue ? "Overdue" : label(task.status), symbol: bucket == .overdue ? "exclamationmark.circle.fill" : "circle.dashed", tone: bucket == .overdue ? "critical" : "low") }
            Text(task.title).font(.headline)
            Text("\(snapshot.memberName(task.assigneeID)) · due \(formatted(task.dueDate))").font(.subheadline).foregroundStyle(Theme.secondaryText)
        }.accessibilityElement(children: .combine)
    }
    private func label(_ s: TaskItem.Status) -> String { switch s { case .notStarted: "Not started"; case .inProgress: "In progress"; case .completed: "Completed" } }
}

struct TaskDetailView: View {
    let taskID: UUID
    @EnvironmentObject private var context: ScreenContext
    @State private var model: TaskListViewModel?

    var body: some View {
        ScrollView {
            if let s = context.data.snapshot, let task = s.tasks.first(where: { $0.id == taskID }), let model {
                let bucket = TaskScheduling.bucket(for: task, now: Date())
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { PriorityChip(priority: task.priority); StatusChip(label: bucket.displayName, symbol: "calendar", tone: bucket == .overdue ? "critical" : "info") }
                            Text(task.title).font(.title2.bold())
                            if !task.details.isEmpty { Text(task.details) }
                            Divider()
                            row("Assignee", s.memberName(task.assigneeID)); row("Area", s.areaName(task.areaID)); row("Due", formatted(task.dueDate))
                            if let done = task.completedAt { row("Completed", formatted(done)) }
                            if let issueID = task.relatedIssueID, let issue = s.issue(issueID) {
                                NavigationLink(value: Route.issue(issueID)) { Label("Related issue: \(issue.title)", systemImage: "link") }.frame(minHeight: 44)
                            }
                        }
                    }
                    switch task.status {
                    case .notStarted: Button("Start Task") { Task { await model.perform(.start, on: task.id) } }.buttonStyle(PrimaryButtonStyle())
                    case .inProgress: Button("Mark Complete") { Task { await model.perform(.complete, on: task.id) } }.buttonStyle(PrimaryButtonStyle())
                    case .completed: Button("Reopen Task") { Task { await model.perform(.reopen, on: task.id) } }.buttonStyle(SecondaryButtonStyle())
                    }
                    if let m = model.errorMessage { ErrorBanner(message: m) }
                }.padding()
            } else { ProgressView().padding() }
        }
        .background(Theme.background).navigationTitle("Task").inlineNavigationTitle()
        .task { if model == nil { model = TaskListViewModel(actor: context.actor, tasks: TaskRepository(store: context.store), sync: context.sync) } }
    }
    private func row(_ k: String, _ v: String) -> some View { HStack { Text(k).foregroundStyle(Theme.secondaryText); Spacer(); Text(v) }.font(.subheadline).accessibilityElement(children: .combine) }
}

struct CreateTaskView: View {
    let model: TaskListViewModel
    @EnvironmentObject private var context: ScreenContext
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var areaID: UUID?
    @State private var assigneeID: UUID?
    @State private var priority: Priority = .medium
    @State private var due = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var issueID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Title", text: $title); TextField("Details", text: $details, axis: .vertical).lineLimit(2...5) }
                Section("Assignment") {
                    Picker("Assignee", selection: $assigneeID) { Text("Choose").tag(UUID?.none); ForEach(context.data.snapshot?.members ?? []) { Text($0.displayName).tag(Optional($0.userID)) } }
                    Picker("Area", selection: $areaID) { Text("None").tag(UUID?.none); ForEach(context.data.snapshot?.areas ?? []) { Text($0.displayName).tag(Optional($0.id)) } }
                    Picker("Related issue", selection: $issueID) { Text("None").tag(UUID?.none); ForEach(context.data.snapshot?.issues.filter { $0.status.isOpenWork } ?? []) { Text($0.title).tag(Optional($0.id)) } }
                }
                Section("Schedule") {
                    Picker("Priority", selection: $priority) { ForEach(Priority.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    DatePicker("Due", selection: $due)
                }
                if let m = model.errorMessage { Section { ErrorBanner(message: m) } }
            }
            .navigationTitle("New Task").inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { if await model.create(title: title, details: details, areaID: areaID, assigneeID: assigneeID ?? context.actor.userID, priority: priority, dueDate: due, relatedIssueID: issueID) { dismiss() } } }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
