import AppKit
import MailKit
import OSLog
import SwiftUI

final class MailExtension: NSObject, MEExtension {
    func handlerForMessageActions() -> any MEMessageActionHandler {
        MessageActionHandler.shared
    }

    func handlerForMessageSecurity() -> any MEMessageSecurityHandler {
        MessageSecurityHandler.shared
    }
}

final class MessageActionHandler: NSObject, MEMessageActionHandler {
    static let shared = MessageActionHandler()
    private let processor = ShipmentProcessor()
    private let logger = Logger(subsystem: "com.sebersta.ParcelSingulator", category: "MailExtension")

    override init() {
        super.init()
        Task {
            do { try await ShipmentQueue.shared.resume() }
            catch { logger.error("Could not resume shipment imports: \(error.localizedDescription)") }
        }
    }

    func decideAction(for message: MEMessage, completionHandler: @escaping (MEMessageActionDecision?) -> Void) {
        let sender = message.fromAddress.rawString
        guard ParcelKeychain.isAutomationEnabled, !ShipmentProcessor.isIgnoredSender(sender) else {
            completionHandler(nil)
            return
        }
        guard let rawData = message.rawData else {
            completionHandler(.invokeAgainWithBody)
            return
        }

        Task {
            do {
                // Use the same headers as the security banner so both paths address the same queued import.
                let result = try await processor.process(
                    subject: EmailText.header("subject", from: rawData) ?? message.subject,
                    sender: EmailText.header("from", from: rawData) ?? sender,
                    rawData: rawData
                )
                completionHandler(result?.status.isInParcel == true ? .action(.markAsRead) : nil)
            } catch {
                logger.error("Parcel processing failed: \(error.localizedDescription)")
                completionHandler(nil)
            }
        }
    }
}

final class MessageSecurityHandler: NSObject, MEMessageSecurityHandler {
    static let shared = MessageSecurityHandler()

    func getEncodingStatus(
        for message: MEMessage,
        composeContext: MEComposeContext,
        completionHandler: @escaping (MEOutgoingMessageEncodingStatus) -> Void
    ) {
        completionHandler(MEOutgoingMessageEncodingStatus(
            canSign: false,
            canEncrypt: false,
            securityError: nil,
            addressesFailingEncryption: []
        ))
    }

    func encode(
        _ message: MEMessage,
        composeContext: MEComposeContext,
        completionHandler: @escaping (MEMessageEncodingResult) -> Void
    ) {
        completionHandler(MEMessageEncodingResult(encodedMessage: nil, signingError: nil, encryptionError: nil))
    }

    func decodedMessage(forMessageData data: Data) -> MEDecodedMessage? {
        let sender = EmailText.header("from", from: data) ?? ""
        let body = EmailText.extract(from: data)
        let detected = !ShipmentProcessor.isIgnoredSender(sender) && ShipmentProcessor.looksLikeShipment(body)
        let message = PopupMessage(
            subject: EmailText.header("subject", from: data) ?? "",
            sender: sender,
            body: body
        )
        guard let context = try? JSONEncoder().encode(message) else { return nil }

        let security = MEMessageSecurityInformation(
            signers: [],
            isEncrypted: false,
            signingError: nil,
            encryptionError: nil
        )
        let banner = MEDecodedMessageBanner(
            title: "Shipment detected",
            primaryActionTitle: "Extract details",
            dismissable: true
        )
        return MEDecodedMessage(
            data: data,
            securityInformation: security,
            context: context,
            banner: detected ? banner : nil
        )
    }

    func extensionViewController(signers messageSigners: [MEMessageSigner]) -> MEExtensionViewController? {
        nil
    }

    func extensionViewController(messageContext context: Data) -> MEExtensionViewController? {
        makeViewController(context: context)
    }

    func primaryActionClicked(
        forMessageContext context: Data,
        completionHandler: @escaping (MEExtensionViewController?) -> Void
    ) {
        completionHandler(makeViewController(context: context))
    }

    private func makeViewController(context: Data) -> MEExtensionViewController {
        let message = (try? JSONDecoder().decode(PopupMessage.self, from: context))
            ?? PopupMessage(subject: "", sender: "", body: String(decoding: context, as: UTF8.self))
        return ParcelViewController(message: message)
    }
}

private final class ParcelViewController: MEExtensionViewController {
    private let message: PopupMessage

    init(message: PopupMessage) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 390, height: 300)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        view = NSHostingView(rootView: ParcelPopup(message: message))
    }
}

private struct ParcelPopup: View {
    let message: PopupMessage
    @State private var state = ProcessingState.processing
    private let processor = ShipmentProcessor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                status
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 390, height: 150, alignment: .topLeading)
        .task { await processMessage() }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .processing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finding the tracking number and carrier…")
            }
            .foregroundStyle(.secondary)
        case .success(let result):
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(result.item)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LabeledContent("Tracking number") {
                        HStack(spacing: 6) {
                            Text(result.trackingNumber)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result.trackingNumber, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy tracking number")
                        }
                    }
                    LabeledContent("Carrier", value: "\(result.carrierName) (\(result.carrierCode.uppercased()))")
                    if result.status == .duplicate {
                        Label("Already in Parcel", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .textSelection(.enabled)
            } label: {
                if result.status == .added {
                    Label("Added to Parcel", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        case .empty:
            Label("No certain shipment was found in this message.", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func processMessage() async {
        state = .processing
        do {
            if let result = try await processor.process(subject: message.subject, sender: message.sender, body: message.body, manual: true) {
                state = .success(result)
            } else {
                state = .empty
            }
        } catch {
            state = .failure(error.localizedDescription)
        }
    }
}

private struct PopupMessage: Codable {
    let subject: String
    let sender: String
    let body: String
}

private enum ProcessingState {
    case processing
    case success(ShipmentResult)
    case empty
    case failure(String)
}
