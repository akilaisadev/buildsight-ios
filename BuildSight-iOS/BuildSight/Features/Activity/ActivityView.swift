import SwiftUI
import BuildSightKit

struct TimelineRow: View {
    let event: TimelineEvent
    let snapshot: ProjectSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.13))
                Image(systemName: Self.symbol(event.ref.kind)).font(.title2.weight(.semibold)).foregroundStyle(Theme.accentText)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.ref.kind.displayName.uppercased()).font(.caption2.weight(.bold))
                        .foregroundStyle(event.ref.kind == .issue || event.ref.kind == .helmetFlag ? Theme.accentText : Theme.secondaryText)
                    Spacer(minLength: 8)
                    Text(formatted(event.at, style: .dateTime.hour().minute())).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                }
                Text(event.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                HStack(spacing: 8) {
                    Label(snapshot.areaName(event.areaID), systemImage: "mappin")
                    Text("·")
                    Text(event.statusLabel)
                }
                .font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 10)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion { appeared = true }
            else { withAnimation(.easeOut(duration: 0.28)) { appeared = true } }
        }
        .accessibilityElement(children: .combine)
    }
    static func symbol(_ k: TimelineKind) -> String {
        switch k { case .photo: "camera.fill"; case .issue: "exclamationmark.bubble.fill"; case .inspection: "checkmark.seal.fill"; case .task: "checklist"; case .helmetFlag: "person.crop.badge.exclamationmark" }
    }
}

extension RecordRef {
    var route: Route {
        switch kind {
        case .photo: .photo(id)
        case .issue, .helmetFlag: .issue(id)
        case .inspection: .inspection(id)
        case .task: .task(id)
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var context: ScreenContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = TimelineViewModel()
    @State private var showFilters = false

    var body: some View {
        Group {
            if let s = context.data.snapshot {
                let sections = model.sections(for: s)
                List {
                    Section {
                        HStack(spacing: 14) {
                            Image(systemName: "waveform.path.ecg.rectangle")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 56, height: 56)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("SITE ACTIVITY").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(Theme.accentText)
                                Text("\(sections.reduce(0) { $0 + $1.events.count }) records")
                                    .font(.title2.bold()).foregroundStyle(Theme.text)
                                Text(model.filter.isActive ? "Showing filtered records" : "Your site's latest updates")
                                    .font(.subheadline).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                kindChip("All", "square.grid.2x2", kinds: [])
                                kindChip("Photos", "camera.fill", kinds: [.photo])
                                kindChip("Issues", "exclamationmark.bubble.fill", kinds: [.issue, .helmetFlag])
                                kindChip("Inspections", "checkmark.seal.fill", kinds: [.inspection])
                                kindChip("Tasks", "checklist", kinds: [.task])
                            }
                            .padding(.horizontal, 16)
                        }
                        .scrollClipDisabled()   // chips scroll edge to edge instead of being cut off
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    if sections.isEmpty {
                        EmptyStateView(symbol: "clock.arrow.circlepath", title: model.filter.isActive ? "No matching activity" : "No activity yet", message: model.filter.isActive ? "Try clearing a filter." : "Photos, issues, inspections and tasks appear here as they are recorded.", actionTitle: model.filter.isActive ? "Clear Filters" : nil) { model.clear() }
                            .listRowBackground(Color.clear)
                    }
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.events) { e in
                                NavigationLink(value: e.ref.route) { TimelineRow(event: e, snapshot: s) }
                                    .listRowBackground(Theme.surface)
                            }
                        } header: {
                            Text(section.day, format: .dateTime.weekday(.wide).day().month(.wide))
                                .font(.subheadline.bold()).foregroundStyle(Theme.text)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: model.filter)
            } else { ProgressView() }
        }
        .navigationTitle("Site Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: { Image(systemName: model.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel(model.filter.isActive ? "Filters, active" : "Filters")
            }
        }
        .sheet(isPresented: $showFilters) { TimelineFilterSheet(model: model) }
    }
}

extension ActivityView {
    /// One-tap filter chip. Large enough for gloved hands; the selected chip is high-contrast.
    func kindChip(_ title: String, _ symbol: String, kinds: Set<TimelineKind>) -> some View {
        let selected = model.filter.kinds == kinds
        return Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { model.filter.kinds = kinds } } label: {
            Label(title, systemImage: symbol)
                .font(.headline)
                .padding(.horizontal, 18)
                .frame(minHeight: Glove.target)
                .background(selected ? Color(light: 0x1C1C1E, dark: 0xFFFFFF) : Theme.surface, in: Capsule())
                .foregroundStyle(selected ? Color(light: 0xFFFFFF, dark: 0x000000) : Theme.text)
                .overlay(Capsule().stroke(Color.primary.opacity(selected ? 0 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TimelineFilterSheet: View {
    let model: TimelineViewModel
    @EnvironmentObject private var context: ScreenContext
    @Environment(\.dismiss) private var dismiss
    @State private var useRange = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Date") {
                    Toggle("Date range", isOn: $useRange)
                    if useRange {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("To", selection: $to, displayedComponents: .date)
                    }
                    Button("Today only") { model.setToday(now: Date()); useRange = false; dismiss() }
                }
                Section("Record type") {
                    ForEach(TimelineKind.allCases, id: \.self) { kind in
                        Toggle(kind.displayName, isOn: Binding(
                            get: { model.filter.kinds.isEmpty || model.filter.kinds.contains(kind) },
                            set: { on in
                                if on { model.filter.kinds.insert(kind) }
                                else if model.filter.kinds.isEmpty { model.filter.kinds = Set(TimelineKind.allCases).subtracting([kind]) }
                                else { model.filter.kinds.remove(kind) }
                                if model.filter.kinds.count == TimelineKind.allCases.count { model.filter.kinds = [] }
                            }
                        ))
                    }
                }
                if let s = context.data.snapshot {
                    Section("Area") {
                        ForEach(s.areas) { a in Toggle(a.displayName, isOn: Binding(get: { model.filter.areaIDs.contains(a.id) }, set: { on in if on { model.filter.areaIDs.insert(a.id) } else { model.filter.areaIDs.remove(a.id) } })) }
                    }
                    Section("Person") {
                        Picker("Person", selection: $model.filter.personID) { Text("Anyone").tag(UUID?.none); ForEach(s.members) { Text($0.displayName).tag(Optional($0.userID)) } }
                    }
                    Section("Status") {
                        Picker("Status", selection: $model.filter.statusLabel) { Text("Any").tag(String?.none); ForEach(model.availableStatuses(for: s), id: \.self) { Text($0).tag(Optional($0)) } }
                    }
                }
                Section { Button("Clear All Filters", role: .destructive) { model.clear(); useRange = false } }
            }
            .navigationTitle("Filters").inlineNavigationTitle()
            .onAppear {
                if let range = model.filter.dateRange {
                    from = range.lowerBound
                    to = range.upperBound
                    useRange = true
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") {
                if useRange {
                    let start = Calendar.current.startOfDay(for: min(from, to))
                    let last = Calendar.current.startOfDay(for: max(from, to))
                    if let end = Calendar.current.date(byAdding: .day, value: 1, to: last) {
                        model.filter.dateRange = start...end.addingTimeInterval(-1)
                    }
                } else { model.filter.dateRange = nil }
                dismiss()
            } } }
        }
    }
}
