import SwiftUI
import ImageIO
import BuildSightKit

/// Loads the ORIGINAL evidence file downsampled for display, and draws helmet
/// boxes on top as a separate layer. The file on disk is never modified.
struct EvidenceImage: View {
    let photo: EvidencePhoto
    let files: EvidenceFileStoring
    var analysis: HelmetAnalysis?
    var showsOverlay = true
    var maxPixel: Int = 1200

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .overlay { if showsOverlay, let analysis { HelmetOverlay(analysis: analysis) } }
            } else {
                Rectangle().fill(Theme.secondaryText.opacity(0.15)).aspectRatio(CGFloat(photo.pixelWidth) / CGFloat(max(photo.pixelHeight, 1)), contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
        .task(id: photo.localFilename) {
            let url = files.url(forFilename: photo.localFilename)
            let size = maxPixel
            image = await Task.detached {
                guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary)
            }.value
        }
        .accessibilityLabel(photo.note.isEmpty ? "Evidence photo" : "Evidence photo: \(photo.note)")
    }
}

/// Bounding boxes in normalised top-left coordinates, scaled to the displayed
/// image. Label text carries the meaning; colour is secondary.
struct HelmetOverlay: View {
    let analysis: HelmetAnalysis

    var body: some View {
        GeometryReader { geo in
            ForEach(analysis.observations) { obs in
                let state = analysis.findings.first { $0.observationID == obs.id }?.state
                if !obs.label.isHead, let item = Self.equipmentStyle(obs) {
                    let rect = obs.box.scaled(to: geo.size)
                    RoundedRectangle(cornerRadius: 4).stroke(item.color, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                        .frame(width: rect.width, height: rect.height)
                        .overlay(alignment: .topLeading) {
                            Text("\(item.text) \(Int(obs.score * 100))%")
                                .font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(item.color.opacity(0.9))
                                .offset(y: -18).fixedSize()
                        }
                        .position(x: rect.midX, y: rect.midY)
                }
                if let state {
                    let rect = obs.box.scaled(to: geo.size)
                    let style = Self.style(state)
                    RoundedRectangle(cornerRadius: 4).stroke(style.color, lineWidth: 3)
                        .frame(width: rect.width, height: rect.height)
                        .overlay(alignment: .topLeading) {
                            Text("\(style.text) \(Int(obs.score * 100))%")
                                .font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(style.color.opacity(0.9))
                                .offset(y: -18).fixedSize()
                        }
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .accessibilityHidden(true)   // the same facts are read out in the result summary
    }

    /// Dashed boxes for vests and gloves. "No gloves" is drawn only above the
    /// same score the summary uses, so the picture and the text agree.
    static func equipmentStyle(_ obs: HelmetObservation) -> (text: String, color: Color)? {
        guard obs.score >= HelmetThresholdPolicy.standard.minimumScore else { return nil }
        switch obs.label {
        case .vest: return ("Vest", Color(hex: 0x1D4ED8))
        case .gloves: return ("Gloves", Color(hex: 0x1D4ED8))
        case .noGloves: return obs.score >= HelmetThresholdPolicy.standard.flagScore ? ("Bare hand?", Color(hex: 0x92400E)) : nil
        case .helmet, .noHelmet: return nil
        }
    }

    static func style(_ s: HeadState) -> (text: String, color: Color) {
        switch s {
        case .helmetWorn: ("Helmet", Color(hex: 0x166534))
        case .suspectedMissingHelmet: ("No helmet?", Color(hex: 0xB91C1C))
        case .uncertain: ("Unclear", Color(hex: 0x92400E))
        }
    }
}
