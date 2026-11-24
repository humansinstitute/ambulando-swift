import AmbulandoCore
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Connect to the user's nStack/Tower over HTTPS: read the public descriptor, then bind the origin
/// to the unlocked identity and start discovery. FIPS endpoints are refused, never silently swapped for HTTPS.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var origin = ""
    @State private var chooseQrImage = false
    @State private var workspaceQr: WorkspaceConnection?
    @State private var workspaceEnvelope = ""
    @State private var workspaceMode = "https"
    @State private var descriptor: NStackDescriptor?
    @State private var checkError: String?
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BrandHeader(subtitle: Product.isGrandparentChat ? "One family conversation, kept simple." : model.identity.npub.map { "Signed in as \(shortNpub($0))" }).padding(.top, 32)
                VStack(alignment: .leading, spacing: 12) {
                    Text(Product.isGrandparentChat ? "Connect to your NStack" : "Connect your nStack").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
                    Text(Product.isGrandparentChat
                         ? "Enter the web address (https://…) of your family's NStack. \(Product.name) checks it, then shows the spaces your account can open."
                         : "Paste workspace QR text or enter the HTTPS address of your Tower. \(Product.name) reads its public service descriptor first, then lists the workspaces your identity can access.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    if let tower = model.pendingTowerWorkspaceChoice {
                        Button("Cancel Tower selection") { model.cancelPendingTowerSelection() }
                        Text("Choose a workspace on " + tower).font(.headline)
                        ForEach(model.workspaceEntries.filter { $0.connection.origin == tower }) { entry in
                            Button(entry.workspace.label) { model.choosePendingWorkspace(entry) }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                        if model.workspaceEntries.filter({ $0.connection.origin == tower }).isEmpty {
                            Text("No accessible workspaces yet. Refresh or check this Tower's membership.")
                            Button("Refresh workspaces") { Task { await model.refreshPendingTowerWorkspaces() } }
                        }
                    }
                    if model.towerDiscoveryBusy { ProgressView("Discovering your Towers…") }
                    if let error = model.towerDiscoveryError { Notice(tone: .error, text: error) }
                    ForEach(model.discoveredTowers, id: \.self) { tower in
                        Button("Choose Tower: " + tower) {
                            working = true
                            Task { await model.connectDiscoveredTower(tower); working = false }
                        }.buttonStyle(PrimaryButtonStyle()).disabled(working)
                    }
                    if !Product.isGrandparentChat {
                        Button("Retry Tower discovery") { Task { await model.discoverTowers() } }
                            .disabled(working || model.towerDiscoveryBusy)
                    }
                    TextField(Product.isGrandparentChat ? "https://your-nstack.example" : "https://your-tower.example", text: $origin)
                        .urlEntry().autocorrectionDisabled()
                        .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                        .onChange(of: origin) { descriptor = nil; workspaceQr = nil; checkError = nil }
                    Button("Scan workspace QR image") { chooseQrImage = true }.disabled(working)
                    if let checkError { Notice(tone: .error, text: checkError) }
                    if let descriptor { DescriptorSummary(descriptor: descriptor) }
                    if let notice = model.notice { Notice(tone: .error, text: notice) }
                    if !Product.isGrandparentChat, workspaceQr == nil { OnboardingEntry(origin: (try? TowerOrigin(origin).description) ?? "") }
                    if let qr = workspaceQr {
                        Text(qr.name ?? "NStack workspace").font(.headline)
                        Text(qr.workspace_id).textSelection(.enabled)
                        Text(qr.service_npub).textSelection(.enabled)
                        Text(qr.workspace_service_npub).textSelection(.enabled)
                        Text("Confirm only if you trust the QR source. Your signed-in identity must already have access.")
                        Picker("Transport", selection: $workspaceMode) {
                            ForEach(qr.modes, id: \.self) { mode in Text(mode.uppercased()).tag(mode) }
                        }
                        if workspaceMode == "https" { Text(qr.transports.https?.url ?? "") }
                        else { Text(qr.transports.fips.map { "http://\($0.host):\($0.port)" } ?? "") }
                        Button("Confirm and verify workspace") {
                            working = true
                            Task {
                                do { try await model.connectWorkspaceQr(workspaceEnvelope, mode: workspaceMode) }
                                catch { checkError = error.localizedDescription }
                                working = false
                            }
                        }.buttonStyle(PrimaryButtonStyle()).disabled(working)
                    } else if descriptor == nil {
                        Button { check() } label: { label(Product.isGrandparentChat ? "Check address" : "Check service") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(origin.isEmpty || working)
                    } else {
                        Button {
                            working = true
                            Task {
                                if Product.isGrandparentChat { await model.connect(origin) }
                                else { await model.connectDiscoveredTower(origin) }
                                working = false
                            }
                        } label: { label(Product.isGrandparentChat ? "Continue" : "Connect and discover workspaces") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(working)
                    }
                }
                .ambCard()
            }
            .padding(20)
        }
        .fileImporter(isPresented: $chooseQrImage, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                try VNImageRequestHandler(url: url).perform([request])
                let codes = request.results ?? []
                guard codes.count == 1, let value = codes.first?.payloadStringValue else { throw TowerError.descriptor("choose an image containing exactly one workspace QR") }
                origin = value
                descriptor = nil; workspaceQr = nil; checkError = nil
            } catch { checkError = error.localizedDescription }
        }
    }

    private func label(_ text: String) -> some View {
        Group { if working { ProgressView().tint(Amb.primaryForeground) } else { Text(text) } }
    }

    private func check() {
        working = true
        Task {
            do {
                if origin.hasPrefix("nstack:workspace:") {
                    let qr = try WorkspaceConnection.parse(origin)
                    workspaceEnvelope = origin; workspaceMode = qr.policy.preferred; workspaceQr = qr
                } else { descriptor = try await model.checkDescriptor(origin) }
            } catch { checkError = error.localizedDescription }
            working = false
        }
    }
}

struct DescriptorSummary: View {
    let descriptor: NStackDescriptor
    var body: some View {
        if Product.isGrandparentChat {
            VStack(alignment: .leading, spacing: 6) {
                Label("NStack found (\(descriptor.tower?.availability?.status ?? "status unknown"))", systemImage: "checkmark.seal")
                    .font(.amb(.subheadline).weight(.semibold)).foregroundStyle(descriptor.advertisesFIPS ? Amb.warning : Amb.success)
                if descriptor.advertisesFIPS {
                    Text("It also advertises a FIPS service, which this \(Device.name) app does not use; it connects over HTTPS only.")
                        .font(.amb(.caption)).foregroundStyle(Amb.warning)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Amb.accent.opacity(0.6), in: RoundedRectangle(cornerRadius: Amb.radiusControl))
        } else { technicalSummary }
    }

    private var technicalSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Tower \(descriptor.tower?.availability?.status ?? "unknown")", systemImage: "server.rack")
                .font(.amb(.subheadline).weight(.semibold)).foregroundStyle(Amb.foreground)
            Text("Protocols: " + (descriptor.tower?.protocols ?? []).joined(separator: ", ")).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            Text("Services: " + descriptor.services.map(\.kind).joined(separator: ", ")).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            Text(descriptor.advertisesFIPS
                 ? "A FIPS service is advertised, but this \(Device.name) app uses HTTPS only and will not switch transports."
                 : "Transport: HTTPS with NIP-98 signed requests.")
                .font(.amb(.caption)).foregroundStyle(descriptor.advertisesFIPS ? Amb.warning : Amb.success)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Amb.accent.opacity(0.6), in: RoundedRectangle(cornerRadius: Amb.radiusControl))
    }
}
