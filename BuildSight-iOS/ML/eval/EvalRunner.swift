// Runs the bundled detector over a folder of images and prints one JSON line per
// image: raw observations (after the model's own NMS), the policy's outcome and
// the measured inference time. Metrics are computed separately by
// ml_metrics.py so the Swift code never grades its own homework.
//
//   swiftc … EvalRunner.swift -lBuildSightKit -o eval-runner
//   ./eval-runner HelmetDetector.mlpackage images/ > predictions.jsonl
import Foundation
import BuildSightKit

@main
struct EvalRunner {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: eval-runner <model> <image-dir>\n".utf8)); exit(2) }
        let model = URL(fileURLWithPath: args[1])
        let dir = URL(fileURLWithPath: args[2])
        do {
            // The five-class PPE model has its own label map; anything else is the helmet-only model.
            let descriptor: HelmetModelDescriptor = model.lastPathComponent.hasPrefix("PPE") ? .ppeYOLOv8s : .candidateKeremberkeYOLOv8n
            let analyzer = try CoreMLHelmetAnalyzer(modelURL: model, descriptor: descriptor)
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            // Warm-up run so the first (compilation / cache) cost is not counted as inference time.
            if let first = files.first { _ = try? await analyzer.analyse(imageAt: first) }
            for file in files {
                let raw = try await analyzer.analyse(imageAt: file)
                let outcome = HelmetInterpreter.interpret(observations: raw.observations, quality: raw.quality)
                let obs = raw.observations.map { ["label": $0.label.rawValue, "score": $0.score, "x": $0.box.x, "y": $0.box.y, "w": $0.box.width, "h": $0.box.height] as [String: Any] }
                let line: [String: Any] = [
                    "image": file.lastPathComponent, "ms": raw.inferenceMilliseconds,
                    "sharpness": raw.quality.sharpness, "width": raw.quality.pixelWidth, "height": raw.quality.pixelHeight,
                    "observations": obs, "outcome": outcome.outcome.summary, "equipment": outcome.equipment.summary,
                ]
                let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
        }
    }
}
