import SwiftUI
import AVFoundation
import PhotosUI
import BuildSightKit

struct CaptureFlowView: View {
    @EnvironmentObject private var context: ScreenContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraService()
    @State private var model: CaptureViewModel?
    @State private var showScanner = false
    @State private var scanMessage: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var uploadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model { content(model) } else { ProgressView() }
            }
            .background(Theme.background)
            .overlay(alignment: .bottom) { if let uploadError { ErrorBanner(message: uploadError).padding() } }
            .navigationTitle("Capture Evidence").inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model?.cancel(); dismiss() } } }
        }
        .task {
            guard model == nil, let snapshot = context.data.snapshot else { return }
            model = CaptureViewModel(actor: context.actor, areas: snapshot.areas, store: context.store, files: context.files, location: context.workspace.location, workflow: context.workspace.helmet, sync: context.sync)
            context.workspace.location.requestAuthorisation()
            await camera.prepare()
        }
        .onDisappear { camera.stop() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
    }

    /// Reads the picked library photo, prepares it and hands it to the review step.
    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { pickerItem = nil }
        guard let model else { return }
        guard let data = try? await item.loadTransferable(type: Data.self), let photo = PhotoImport.prepare(data) else {
            uploadError = "That file couldn't be read as a photo. Pick a JPEG, HEIC or PNG picture."
            return
        }
        uploadError = nil
        model.photoUploaded(photo)
    }

    private func uploadButton(compact: Bool) -> some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            if compact {
                Image(systemName: "photo.on.rectangle").font(.title2.weight(.semibold))
                    .frame(width: Glove.target, height: Glove.target).background(.ultraThinMaterial, in: Circle())
            } else {
                Label("Upload a photo", systemImage: "photo.on.rectangle").font(.headline)
                    .padding(.horizontal, 20).frame(minHeight: Glove.target).background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
            }
        }
        .accessibilityIdentifier("capture.upload")
        .accessibilityLabel("Upload a photo")
        .accessibilityHint("Choose a picture from your library to check for helmets")
    }

    @ViewBuilder private func content(_ model: CaptureViewModel) -> some View {
        switch model.phase {
        case .camera: cameraStep(model)
        case .review, .saving: ReviewStep(model: model, showScanner: $showScanner, scanMessage: scanMessage)
                .sheet(isPresented: $showScanner) { scanner(model) }
        case .analysing: VStack(spacing: 16) { ProgressView(); Text("Analysing on this device…").font(.headline); Text("Your photo is already saved.").foregroundStyle(Theme.secondaryText) }
        case .finished: if let outcome = model.outcome { ResultStep(outcome: outcome, model: model, camera: camera, dismiss: { dismiss() }) }
        case .failed(let message): VStack(spacing: 16) { ErrorBanner(message: message); Button("Try Again") { model.retake() }.buttonStyle(SecondaryButtonStyle()) }.padding()
        }
    }

    @ViewBuilder private func cameraStep(_ model: CaptureViewModel) -> some View {
        switch camera.availability {
        case .ready:
            ZStack(alignment: .bottom) {
                CameraPreview(session: camera.session).ignoresSafeArea(edges: .bottom)
                Button {
                    Task { if let data = await camera.capture() { model.photoCaptured(data) } }
                } label: {
                    Circle().strokeBorder(.white, lineWidth: 6).background(Circle().fill(Theme.accent).padding(9)).frame(width: 92, height: 92)
                }
                .padding(.bottom, 28)
                .accessibilityLabel("Take photo")
                .accessibilityIdentifier("capture.shutter")
            }
            .overlay(alignment: .bottomLeading) { uploadButton(compact: true).padding(.leading, 24).padding(.bottom, 44) }
            .overlay(alignment: .topTrailing) {
                Button { showScanner = true } label: {
                    Label("Scan area code", systemImage: "qrcode.viewfinder").font(.headline)
                        .padding(.horizontal, 16).frame(minHeight: Glove.target)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(16)
                .accessibilityHint("Scan the QR code for the area you are in")
            }
            .overlay(alignment: .topLeading) { areaChip(model) }
            .sheet(isPresented: $showScanner) { scanner(model) }
        case .notDetermined: ProgressView()
        case .denied:
            VStack(spacing: 16) {
                EmptyStateView(symbol: "camera.fill", title: "Camera access is off", message: "Turn the camera on in Settings, or upload a picture from your library instead.", actionTitle: "Open Settings") { openSettings() }
                uploadButton(compact: false)
            }
        case .restricted:
            VStack(spacing: 16) {
                EmptyStateView(symbol: "lock.fill", title: "Camera is restricted", message: "Screen Time or device management is blocking the camera. You can still upload a picture.")
                uploadButton(compact: false)
            }
        case .noCamera:
            VStack(spacing: 16) {
                EmptyStateView(symbol: "camera.metering.unknown", title: "No camera available", message: "This device has no camera (for example the Simulator). Upload a picture from your library to check it.")
                uploadButton(compact: false)
            }
        }
    }

    /// Shows which area the next photo will be tagged to, before the worker takes it.
    @ViewBuilder private func areaChip(_ model: CaptureViewModel) -> some View {
        let name = model.selectedAreaID.flatMap { id in context.data.snapshot?.areas.first { $0.id == id }?.displayName }
        Label(name ?? "No area set: scan the area code", systemImage: name == nil ? "exclamationmark.triangle.fill" : "mappin.and.ellipse")
            .font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(name == nil ? Theme.status("high").fg : Theme.text)
            .padding(.horizontal, 16).frame(minHeight: Glove.target)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(16)
            .accessibilityLabel(name.map { "Photo will be tagged to \($0)" } ?? "No area set. Scan the area code first.")
    }

    private func scanner(_ model: CaptureViewModel) -> some View {
        NavigationStack {
            QRScannerView { code in
                switch AreaQRPayload.resolve(code, activeProject: context.actor.projectID, areas: model.areas) {
                case .success(let area): model.apply(scannedArea: area); scanMessage = "Area set to \(area.displayName)"; showScanner = false
                case .failure(.wrongProject): scanMessage = "That code belongs to a different project."
                case .failure(.unknownArea): scanMessage = "That area isn't part of this project."
                case .failure(.notABuildSightCode): scanMessage = "That isn't a BuildSight area code."
                }
            }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { if let scanMessage { ErrorBanner(message: scanMessage).padding() } }
            .navigationTitle("Scan Area Code").inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } } }
        }
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}

private struct ReviewStep: View {
    @Bindable var model: CaptureViewModel
    @Binding var showScanner: Bool
    let scanMessage: String?
    @EnvironmentObject private var context: ScreenContext
    @State private var showAreaError = false

    var body: some View {
        Form {
            if let jpeg = model.capturedJPEG, let image = UIImage(data: jpeg) {
                Section { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("Captured photo preview") }
            }
            Section("Where") {
                Picker("Site area", selection: $model.selectedAreaID) {
                    Text("Choose area").tag(UUID?.none)
                    ForEach(model.areas) { Text($0.displayName).tag(Optional($0.id)) }
                }
                if showAreaError, model.selectedAreaID == nil { FieldError(message: "Choose the site area, or scan its QR code, before saving.") }
                Button { showScanner = true } label: { Label("Scan area QR code", systemImage: "qrcode.viewfinder") }
                if let scanMessage { Text(scanMessage).font(.footnote).foregroundStyle(Theme.secondaryText) }
                locationRow
            }
            Section("Details") {
                Picker("Category", selection: $model.category) { ForEach(PhotoCategory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                TextField("Note (optional)", text: $model.note, axis: .vertical).lineLimit(1...4)
            }
            Section {
                Button {
                    guard model.canSave else { showAreaError = true; UINotificationFeedbackGenerator().notificationOccurred(.error); return }
                    Task { await model.saveAndAnalyse() }
                } label: { if model.phase == .saving { ProgressView() } else { Text("Save & Check Helmets") } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(model.phase == .saving).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                Button("Retake") { model.retake() }.buttonStyle(SecondaryButtonStyle()).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            } footer: { Text("Time, location and your name are recorded automatically. Helmet analysis runs on this device; the photo is saved first.") }
        }
    }

    @ViewBuilder private var locationRow: some View {
        switch model.locationPreview {
        case nil: Label("Finding GPS position…", systemImage: "location").foregroundStyle(Theme.secondaryText)
        case .gps(let p)?:
            Label(LocationFix.gps(p).isApproximate ? "Approximate GPS (±\(Int(p.horizontalAccuracy)) m)" : "GPS position (±\(Int(p.horizontalAccuracy)) m)", systemImage: "location.fill")
        case .unavailable(let why)?:
            Label("No GPS: \(Self.reason(why)). The site area is still recorded.", systemImage: "location.slash")
        }
    }

    static func reason(_ r: LocationUnavailableReason) -> String {
        switch r {
        case .permissionDenied: "location access is off"
        case .permissionRestricted: "location is restricted"
        case .servicesDisabled: "location services are off"
        case .noFixYet: "no signal yet"
        case .timedOut: "timed out"
        case .imported: "this photo was uploaded, not taken here"
        }
    }
}

private struct ResultStep: View {
    let outcome: CaptureOutcome
    let model: CaptureViewModel
    let camera: CameraService
    let dismiss: () -> Void
    @EnvironmentObject private var context: ScreenContext
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                EvidenceImage(photo: outcome.photo, files: context.files, analysis: outcome.analysis).clipShape(RoundedRectangle(cornerRadius: 12))
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Helmet check")
                        Text(summary).font(.headline)
                        Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryText)
                        if let equipment = outcome.analysis.equipment {
                            Text(equipment.summary).font(.subheadline)
                            Text("Vests and gloves are reported only when seen. A photo with none says nothing about whether they were worn.").font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        if let ms = outcome.analysis.inferenceMilliseconds { Text("Analysed on this device in \(Int(ms)) ms").font(.caption).foregroundStyle(Theme.secondaryText) }
                    }
                }
                if let issue = outcome.issue {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(outcome.createdNewIssue ? "Safety issue created" : "Linked safety issue", systemImage: "exclamationmark.triangle.fill").font(.headline)
                            PriorityChip(priority: issue.priority)
                            ReviewChip(review: issue.review)
                            Button("Open Issue") { dismiss(); router.open(.issue(projectID: issue.projectID, issueID: issue.id), activeProject: issue.projectID, isRegular: false) }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                Button("Take Another") { model.reset() }.buttonStyle(PrimaryButtonStyle())
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }.padding()
        }
    }

    private var summary: String {
        switch outcome.analysis.state {
        case .finished(let o): o.summary
        case .failed: "Analysis unavailable"
        case .pending: "Analysing…"
        }
    }
    private var detail: String {
        switch outcome.analysis.state {
        case .failed(let m): "\(m). The photo is saved; you can analyse it again from its detail screen."
        default: "This checks helmets only, on the workers visible in this photo. It is a suggestion for a person to review, not a safety clearance."
        }
    }
}
