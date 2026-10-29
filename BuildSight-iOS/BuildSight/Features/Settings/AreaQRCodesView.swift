import SwiftUI
import BuildSightKit

/// One QR code per site area. Print them, stick one at each area, and workers scan it
/// in Capture to tag their photos to the right place. Codes only work for this project.
struct AreaQRCodesView: View {
    @EnvironmentObject private var context: ScreenContext

    var body: some View {
        List {
            Section {
                Text("Print one code per area and stick it up. Workers scan it in Capture to tag photos to that area.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            Section {
                ForEach(context.data.snapshot?.areas ?? []) { area in
                    HStack(spacing: 16) {
                        QRCodeView(text: "buildsight://area/\(context.actor.projectID.uuidString)/\(area.id.uuidString)")
                            .frame(width: 130, height: 130)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(area.displayName).font(.headline)
                            Text("Scan to tag photos here").font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("Area QR Codes")
    }
}
