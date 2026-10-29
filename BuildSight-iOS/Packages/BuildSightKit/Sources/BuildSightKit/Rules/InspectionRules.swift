import Foundation

public enum InspectionError: Error, Equatable, Sendable {
    case alreadyCompleted
    case unansweredItems(count: Int)
    case failedItemNeedsNote(itemID: UUID)
    case emergencyStopNeedsReason
    case notPermitted
}

public enum InspectionRules {
    /// Starter checklists so the app is usable before any are synced down.
    public static let builtInTemplates: [ChecklistTemplate] = [
        ChecklistTemplate(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000E1")!, name: "Electrical Installation", itemTitles: [
            "Cable installation", "Protective conduit", "Panel labelling", "Grounding continuity", "Circuit breaker rating", "Emergency cutoff"]),
        ChecklistTemplate(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000E2")!, name: "Site Safety Walk", itemTitles: [
            "Edge protection in place", "Walkways clear", "Signage visible", "Fire extinguishers accessible", "Site access controlled"]),
        ChecklistTemplate(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000E3")!, name: "Concrete Quality", itemTitles: [
            "Formwork alignment", "Reinforcement cover", "Surface finish", "Curing method applied", "Slump test recorded"]),
    ]

    public static func start(template: ChecklistTemplate, projectID: UUID, areaID: UUID, inspectorID: UUID, role: Role, location: LocationFix, now: Date, dueDate: Date? = nil) -> Result<Inspection, InspectionError> {
        guard role.can(.runInspection) else { return .failure(.notPermitted) }
        let items = template.itemTitles.map { InspectionItem(title: $0) }
        return .success(Inspection(projectID: projectID, areaID: areaID, templateName: template.name, inspectorID: inspectorID, startedAt: now, dueDate: dueDate, items: items, location: location))
    }

    /// Completion rules, in the order they are reported to the inspector:
    /// every item answered, every Fail explained, and a raised emergency stop
    /// must state its reason. Progress can be saved at any point without these.
    public static func validateCompletion(_ inspection: Inspection) -> InspectionError? {
        if inspection.completedAt != nil { return .alreadyCompleted }
        let unanswered = inspection.items.filter { $0.result == nil }.count
        if unanswered > 0 { return .unansweredItems(count: unanswered) }
        if let item = inspection.items.first(where: { $0.result == .fail && $0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.photoIDs.isEmpty }) {
            return .failedItemNeedsNote(itemID: item.id)
        }
        if let stop = inspection.emergencyStop, stop.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emergencyStopNeedsReason
        }
        return nil
    }

    public static func complete(_ inspection: Inspection, now: Date) -> Result<Inspection, InspectionError> {
        if let error = validateCompletion(inspection) { return .failure(error) }
        var done = inspection
        done.completedAt = now
        done.updatedAt = now
        return .success(done)
    }

    /// Raises the digital stop-work notice and the Critical issue that goes with
    /// it. Both are records only; nothing here can stop a machine.
    public static func raiseEmergencyStop(on inspection: Inspection, reason: String, actorID: UUID, role: Role, now: Date) -> Result<(Inspection, Issue), InspectionError> {
        guard role.can(.raiseEmergencyStop) else { return .failure(.notPermitted) }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emergencyStopNeedsReason) }
        let issue = Issue(
            projectID: inspection.projectID, areaID: inspection.areaID,
            title: "Emergency stop raised during \(inspection.templateName)",
            details: trimmed, category: .safety, priority: .critical,
            reporterID: actorID, createdAt: now, location: inspection.location
        )
        var updated = inspection
        updated.emergencyStop = EmergencyStop(raisedAt: now, reason: trimmed, raisedIssueID: issue.id)
        updated.updatedAt = now
        return .success((updated, issue))
    }

    public static func clearEmergencyStop(on inspection: Inspection, actorID: UUID, role: Role, now: Date) -> Result<Inspection, InspectionError> {
        guard role.can(.clearEmergencyStop) else { return .failure(.notPermitted) }
        guard var stop = inspection.emergencyStop, stop.isActive else { return .success(inspection) }
        stop.clearedAt = now
        stop.clearedByID = actorID
        var updated = inspection
        updated.emergencyStop = stop
        updated.updatedAt = now
        return .success(updated)
    }

    /// Areas currently under a digital stop-work notice.
    public static func areasUnderStopWork(_ inspections: [Inspection]) -> Set<UUID> {
        Set(inspections.filter { $0.emergencyStop?.isActive == true }.map(\.areaID))
    }
}
