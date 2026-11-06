import AmbulandoCore
import SwiftUI

/// Connect to the user's nStack/Tower over HTTPS: read the public descriptor, then bind the origin
/// to the unlocked identity and start discovery. FIPS endpoints are refused, never silently swapped for HTTPS.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var origin = ""
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
                         : "Enter the HTTPS address of your Tower. \(Product.name) reads its public service descriptor first, then lists the workspaces your identity can access.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    TextField(Product.isGrandparentChat ? "https://your-nstack.example" : "https://your-tower.example", text: $origin)
                        .urlEntry().autocorrectionDisabled()
                        .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                        .onChange(of: origin) { descriptor = nil; checkError = nil }
                    if let checkError { Notice(tone: .error, text: checkError) }
                    if let descriptor { DescriptorSummary(descriptor: descriptor) }
                    if let notice = model.notice { Notice(tone: .error, text: notice) }
                    if descriptor == nil {
                        Button { check() } label: { label(Product.isGrandparentChat ? "Check address" : "Check service") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(origin.isEmpty || working)
                    } else {
                        Button {
                            working = true
                            Task { await model.connect(origin); working = false }
                        } label: { label(Product.isGrandparentChat ? "Continue" : "Connect and discover workspaces") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(working)
                    }
                }
                .ambCard()
            }
            .padding(20)
        }
    }

    private func label(_ text: String) -> some View {
        Group { if working { ProgressView().tint(Amb.primaryForeground) } else { Text(text) } }
    }

    private func check() {
        working = true
        Task {
            do { descriptor = try await model.checkDescriptor(origin) } catch { checkError = error.localizedDescription }
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
