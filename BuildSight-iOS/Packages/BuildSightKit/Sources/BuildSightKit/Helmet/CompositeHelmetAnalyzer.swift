import Foundation

/// Uses one model for the helmet / no-helmet decision and another for vests and gloves. Measured on
/// labelled photos, a helmet-only model finds missing helmets far more reliably than the multi-class
/// models, while the multi-class model is the one that knows vests and gloves.
public final class CompositeHelmetAnalyzer: HelmetAnalyzing {
    public let descriptor: HelmetModelDescriptor
    private let head: HelmetAnalyzing
    private let equipment: HelmetAnalyzing

    public init(head: HelmetAnalyzing, equipment: HelmetAnalyzing) {
        self.head = head
        self.equipment = equipment
        let extra = equipment.descriptor.labelMap.filter { !$0.value.isHead }
        descriptor = HelmetModelDescriptor(
            identifier: "\(head.descriptor.identifier)+\(equipment.descriptor.identifier)",
            version: "\(head.descriptor.version)+\(equipment.descriptor.version)",
            labelMap: head.descriptor.labelMap.merging(extra) { headLabel, _ in headLabel },
            inputSide: head.descriptor.inputSide,
            sourceDescription: "Heads: \(head.descriptor.sourceDescription). Vests and gloves: \(equipment.descriptor.sourceDescription)",
            licenceNote: "\(head.descriptor.licenceNote) \(equipment.descriptor.licenceNote)"
        )
    }

    /// The helmet model must succeed. Vests and gloves are a bonus: if that model fails, the helmet
    /// result is still returned instead of losing the whole analysis.
    public func analyse(imageAt url: URL) async throws -> HelmetRawResult {
        let headResult = try await head.analyse(imageAt: url)
        let extra = try? await equipment.analyse(imageAt: url)
        return HelmetRawResult(
            observations: headResult.observations.filter { $0.label.isHead } + (extra?.observations.filter { !$0.label.isHead } ?? []),
            quality: headResult.quality,
            inferenceMilliseconds: headResult.inferenceMilliseconds + (extra?.inferenceMilliseconds ?? 0)
        )
    }
}
