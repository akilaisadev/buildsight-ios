import Testing
import Foundation
@testable import BuildSightKit

private func scripted(_ observations: [HelmetObservation], ms: Double = 100, descriptor: HelmetModelDescriptor, quality: ImageQuality = Fixture.sharpImage) -> ScriptedAnalyzer {
    ScriptedAnalyzer(descriptor: descriptor, result: .success(HelmetRawResult(observations: observations, quality: quality, inferenceMilliseconds: ms)))
}

private let url = URL(fileURLWithPath: "/dev/null/photo.jpg")

@Suite("Combined helmet analyzer")
struct CompositeAnalyzerTests {
    let headModel = HelmetModelDescriptor.candidateKeremberkeYOLOv8n
    let equipmentModel = HelmetModelDescriptor.ppeSafetyVisionV2

    @Test("Helmet and no-helmet boxes come from the helmet model")
    func headsFromHeadModel() async throws {
        let combined = CompositeHelmetAnalyzer(
            head: scripted([Fixture.obs(.helmet, 0.9), Fixture.obs(.noHelmet, 0.8, x: 0.5)], descriptor: headModel),
            equipment: scripted([], descriptor: equipmentModel))
        let labels = try await combined.analyse(imageAt: url).observations.map(\.label)
        #expect(labels == [.helmet, .noHelmet])
    }

    @Test("Vests and gloves come from the equipment model", arguments: [HelmetLabel.vest, .gloves, .noGloves])
    func equipmentFromEquipmentModel(_ label: HelmetLabel) async throws {
        let combined = CompositeHelmetAnalyzer(
            head: scripted([], descriptor: headModel),
            equipment: scripted([Fixture.obs(label, 0.7)], descriptor: equipmentModel))
        #expect(try await combined.analyse(imageAt: url).observations.map(\.label) == [label])
    }

    @Test("Helmet boxes from the equipment model are ignored", arguments: [HelmetLabel.helmet, .noHelmet])
    func equipmentHeadsIgnored(_ label: HelmetLabel) async throws {
        let combined = CompositeHelmetAnalyzer(
            head: scripted([], descriptor: headModel),
            equipment: scripted([Fixture.obs(label, 0.99)], descriptor: equipmentModel))
        #expect(try await combined.analyse(imageAt: url).observations.isEmpty)
    }

    @Test("Vest and glove boxes from the helmet model are ignored", arguments: [HelmetLabel.vest, .gloves, .noGloves])
    func headModelEquipmentIgnored(_ label: HelmetLabel) async throws {
        let combined = CompositeHelmetAnalyzer(
            head: scripted([Fixture.obs(label, 0.99)], descriptor: headModel),
            equipment: scripted([], descriptor: equipmentModel))
        #expect(try await combined.analyse(imageAt: url).observations.isEmpty)
    }

    @Test("Both kinds of box appear together in one result")
    func merged() async throws {
        let combined = CompositeHelmetAnalyzer(
            head: scripted([Fixture.obs(.noHelmet, 0.8)], descriptor: headModel),
            equipment: scripted([Fixture.obs(.vest, 0.9), Fixture.obs(.gloves, 0.6)], descriptor: equipmentModel))
        let labels = Set(try await combined.analyse(imageAt: url).observations.map(\.label))
        #expect(labels == [.noHelmet, .vest, .gloves])
    }

    @Test("Image quality comes from the helmet model")
    func quality() async throws {
        let blurry = ImageQuality(pixelWidth: 800, pixelHeight: 600, sharpness: 3)
        let combined = CompositeHelmetAnalyzer(
            head: scripted([], descriptor: headModel, quality: blurry),
            equipment: scripted([], descriptor: equipmentModel))
        #expect(try await combined.analyse(imageAt: url).quality == blurry)
    }

    @Test("Time is the two models added together")
    func time() async throws {
        let combined = CompositeHelmetAnalyzer(
            head: scripted([], ms: 120, descriptor: headModel),
            equipment: scripted([], ms: 80, descriptor: equipmentModel))
        #expect(try await combined.analyse(imageAt: url).inferenceMilliseconds == 200)
    }

    @Test("If the helmet model fails the analysis fails")
    func headFailureThrows() async {
        let failing = ScriptedAnalyzer(descriptor: headModel, result: .failure(.inferenceFailed("boom")))
        let combined = CompositeHelmetAnalyzer(head: failing, equipment: scripted([], descriptor: equipmentModel))
        await #expect(throws: HelmetAnalyzerError.self) { try await combined.analyse(imageAt: url) }
    }

    @Test("If only the equipment model fails, the helmet result is still returned")
    func equipmentFailureIsSoft() async throws {
        let failing = ScriptedAnalyzer(descriptor: equipmentModel, result: .failure(.inferenceFailed("boom")))
        let combined = CompositeHelmetAnalyzer(head: scripted([Fixture.obs(.noHelmet, 0.8)], ms: 90, descriptor: headModel), equipment: failing)
        let result = try await combined.analyse(imageAt: url)
        #expect(result.observations.map(\.label) == [.noHelmet])
        #expect(result.inferenceMilliseconds == 90)
    }

    @Test("The descriptor names both models and keeps the helmet model's labels first")
    func descriptor() {
        let combined = CompositeHelmetAnalyzer(head: scripted([], descriptor: headModel), equipment: scripted([], descriptor: equipmentModel))
        #expect(combined.descriptor.identifier == "\(headModel.identifier)+\(equipmentModel.identifier)")
        #expect(combined.descriptor.version == "\(headModel.version)+\(equipmentModel.version)")
        #expect(combined.descriptor.inputSide == headModel.inputSide)
        #expect(combined.descriptor.labelMap["Hardhat"] == .helmet)
        #expect(combined.descriptor.labelMap["NO-Hardhat"] == .noHelmet)
        #expect(combined.descriptor.labelMap["Safety Vest"] == .vest)
        #expect(combined.descriptor.labelMap["Gloves"] == .gloves)
    }

    @Test("A missing helmet seen by the helmet model still raises the suspected-violation finding")
    func endToEndFinding() async throws {
        let combined = CompositeHelmetAnalyzer(
            head: scripted([Fixture.obs(.noHelmet, 0.7)], descriptor: headModel),
            equipment: scripted([Fixture.obs(.vest, 0.9)], descriptor: equipmentModel))
        let raw = try await combined.analyse(imageAt: url)
        let interpretation = HelmetInterpreter.interpret(observations: raw.observations, quality: raw.quality)
        #expect(interpretation.findings.first?.state == .suspectedMissingHelmet)
    }
}
