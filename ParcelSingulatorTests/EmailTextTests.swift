import Foundation
import FoundationModels
import Testing

struct EmailSizeLimitTests {
    @Test(arguments: [-1, 0, 1])
    func rawMessageSizeBoundary(offset: Int) {
        let header = Data("Subject: Shipment\nContent-Type: text/plain\n\n".utf8)
        let body = Data("Tracking: 1Z999AA10123456784".utf8)
        var message = header
        message.append(Data(repeating: 32, count: EmailText.maximumMessageBytes + offset - header.count - body.count))
        message.append(body)

        #expect(EmailText.header("subject", from: message) == (offset <= 0 ? "Shipment" : nil))
        #expect(EmailText.extract(from: message) == (offset <= 0 ? String(decoding: body, as: UTF8.self) : ""))
    }
}

struct TriggerWordsTests {
    @Test func commaSeparatedTriggers() {
        #expect(ShipmentProcessor.looksLikeShipment("Your order SHIPPED", triggerWords: " track, shipped, out for delivery "))
        #expect(ShipmentProcessor.looksLikeShipment("Out for delivery today", triggerWords: "track, out for delivery"))
        #expect(ShipmentProcessor.looksLikeShipment("Tracking details", triggerWords: "track"))
        #expect(!ShipmentProcessor.looksLikeShipment("Tracking details", triggerWords: "shipped"))
        #expect(!ShipmentProcessor.looksLikeShipment("Unrelated message", triggerWords: "track, , shipped,"))
        #expect(!ShipmentProcessor.looksLikeShipment("Tracking details", triggerWords: " , , \n"))
        #expect(!ShipmentProcessor.looksLikeShipment("Tracking details", triggerWords: ""))
        #expect(!ShipmentProcessor.looksLikeShipment("Ready to be shipped. Track here.", triggerWords: "track, shipped"))
    }
}
import XCTest

final class EmailTextTests: XCTestCase {
    func testShipmentGateRequiresTrackText() {
        XCTAssertFalse(ShipmentProcessor.looksLikeShipment("Your order is ready to be shipped"))
        XCTAssertFalse(ShipmentProcessor.looksLikeShipment("Your order was delivered"))
        XCTAssertFalse(ShipmentProcessor.looksLikeShipment("Your order is ready to be shipped. Track it here."))
        XCTAssertFalse(ShipmentProcessor.looksLikeShipment("Your order was delivered. Tracking details are available."))
        XCTAssertFalse(ShipmentProcessor.looksLikeShipment("Unsubscribe from shipment updates"))
        XCTAssertFalse(ShipmentProcessor.looksLikeShipment("Delivery preferences were updated"))
        XCTAssertFalse(ShipmentProcessor.looksLikeShipment("Your order has shipped"))
        XCTAssertTrue(ShipmentProcessor.looksLikeShipment("Track your shipment"))
        XCTAssertTrue(ShipmentProcessor.looksLikeShipment("Tracking number available"))
    }

    func testIgnoredSendersSkipExtraction() async throws {
        for sender in ["Amazon.com <shipment-tracking@amazon.com>", "eBay <ebay@ebay.com>", " EBAY@EBAY.COM "] {
            XCTAssertTrue(ShipmentProcessor.isIgnoredSender(sender))
            let result = try await ShipmentProcessor().extractShipment(subject: "Order update", sender: sender, body: "Track your shipment")
            XCTAssertEqual(result.route, .none)
            XCTAssertNil(result.shipment)
            XCTAssertEqual(result.inputCharacters, 0)
        }
        for sender in ["tracking@example.com", "ebay@ebay.com.example.org", "eBay <tracking@example.com>"] {
            XCTAssertFalse(ShipmentProcessor.isIgnoredSender(sender))
        }
    }

    func testMultipartDecodingPrefersPlainTextAndSkipsAttachments() {
        let message = """
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="parcel-boundary"
        
        --parcel-boundary
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable
        
        Your bicycle light shipped.=0ATracking: 1Z999AA10123456784
        --parcel-boundary
        Content-Type: application/pdf; name=invoice.pdf
        Content-Disposition: attachment; filename=invoice.pdf
        Content-Transfer-Encoding: base64
        
        U0VDUkVU
        --parcel-boundary--
        """

        let text = EmailText.extract(from: Data(message.utf8))
        XCTAssertTrue(text.contains("bicycle light shipped.\nTracking: 1Z999AA10123456784"))
        XCTAssertFalse(text.contains("SECRET"))
    }

    func testCodeExtractorFindsCompleteUPSShipment() {
        let shipment = ShipmentCodeExtractor.extract(
            subject: "Your Bicycle Light has shipped",
            sender: "UPS <updates@ups.com>",
            body: "Tracking number: 1Z999AA10123456784"
        )

        XCTAssertTrue(shipment.isComplete)
        XCTAssertEqual(shipment.trackingNumber, "1Z999AA10123456784")
        XCTAssertEqual(shipment.carrierCode, "ups")
        XCTAssertEqual(shipment.carrierName, "UPS")
        XCTAssertEqual(shipment.item, "Bicycle Light")
    }

    func testCodeExtractorRejectsStatusTextAsTrackingNumber() {
        let shipment = ShipmentCodeExtractor.extract(
            subject: "Your package has shipped",
            sender: "UPS <updates@ups.com>",
            body: "Tracking is unavailable"
        )

        XCTAssertFalse(shipment.isComplete)
        XCTAssertNil(shipment.trackingNumber)
        XCTAssertNil(shipment.item)
    }

    func testCodeExtractorFindsTrackingNumberInsideHTMLLink() {
        let message = """
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="Parcel-Boundary"

        --Parcel-Boundary
        Content-Type: text/plain; charset=utf-8

        Your Bicycle Light has shipped. Track your delivery.
        --Parcel-Boundary
        Content-Type: text/html; charset=utf-8

        <a href="https://example.com/redirect?url=https%253A%252F%252Fwww.fedex.com%252Ffedextrack%252F%253Ftrackingnumbers%253D541891252367">Track shipment</a>
        --Parcel-Boundary--
        """

        let body = EmailText.extract(from: Data(message.utf8))
        let shipment = ShipmentCodeExtractor.extract(
            subject: "Your Bicycle Light has shipped",
            sender: "Store <shipping@example.com>",
            body: body
        )

        XCTAssertEqual(shipment.trackingNumber, "541891252367")
        XCTAssertEqual(shipment.carrierCode, "fedex")
        XCTAssertEqual(shipment.item, "Bicycle Light")
        XCTAssertTrue(shipment.isComplete)
    }

    func testEmptyPlainPartFallsBackToVisibleHTML() {
        let message = """
        Content-Type: multipart/alternative; boundary="MixedCase"

        --MixedCase
        Content-Type: text/plain


        --MixedCase
        Content-Type: text/html

        <p>Your tracking number is <strong>9261290277958019299441</strong>.</p><p>Shipped via DHL Global.</p>
        --MixedCase--
        """

        let body = EmailText.extract(from: Data(message.utf8))
        XCTAssertTrue(body.contains("9261290277958019299441"), body)
        let shipment = ShipmentCodeExtractor.extract(subject: "Your order is on the way", sender: "Store", body: body)
        XCTAssertEqual(shipment.trackingNumber, "9261290277958019299441")
        XCTAssertEqual(shipment.carrierCode, "dhl")
    }

    private let expectedEmails: [String: (String?, String?)] = [
        "A shipment from order #115190 is on the way.eml": (nil, nil),
        "A shipment from order US3528331 has been delivered.eml": (nil, nil),
        "Demo shipment.eml": ("1Z999AA10123456787", "ups"),
        "Jian, your package is arriving TODAY!.eml": (nil, nil), // Tracking is behind an opaque link.
        "Shipped 2 items_ 3D Printing Supplies, Health Care.eml": (nil, nil),
        "Shipped_ ⁦1⁩ Bath item.eml": (nil, nil),
        "Thank you for your UNIQLO purchase!.eml": (nil, nil),
        "Your Order is On The Way.eml": (nil, nil),
        "Your Pannierhooks.com order 21964 has shipped.eml": ("9200190187252201167458", "usps"),
        "Your UNIQLO order tracking information!.eml": ("541891252367", "fedex"),
        "Your order is arriving today!.eml": ("1lscxm8006438b3", nil), // Carrier is absent from the email.
        "Your shipment is on its way. Order No. W1492602828.eml": (nil, nil),
        "🚚 Order update_ HP NEW 3TK79AT 3TK79AA Da....eml": (nil, nil),
        "🤩 You’ll be seeing stars (5 to be exact).eml": (nil, nil),
    ]

    private func corpusDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PerformanceEmails")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Local email fixtures are unavailable")
        }
        return directory
    }

    func testEmailCorpusExpectedTrackingAndCarrier() throws {
        let directory = try corpusDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "eml" }
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(expectedEmails.keys), "Every fixture needs an expected result")
        for file in files {
            let expected = try XCTUnwrap(expectedEmails[file.lastPathComponent])
            let data = try Data(contentsOf: file)
            let subject = EmailText.header("subject", from: data) ?? ""
            let sender = EmailText.header("from", from: data) ?? ""
            let body = EmailText.extract(from: data)
            let shipment = !ShipmentProcessor.isIgnoredSender(sender) && ShipmentProcessor.looksLikeShipment(body)
                ? ShipmentCodeExtractor.extract(subject: subject, sender: sender, body: body) : nil
            XCTAssertEqual(shipment?.trackingNumber, expected.0, file.lastPathComponent)
            XCTAssertEqual(shipment?.carrierCode, expected.1, file.lastPathComponent)
        }
    }

    func testModelExtractionAgainstKnownShipments() async throws {
        guard SystemLanguageModel.default.isAvailable else {
            throw XCTSkip("Apple Intelligence is unavailable: \(SystemLanguageModel.default.availability)")
        }
        let directory = try corpusDirectory()
        var checked = 0
        for (name, expected) in expectedEmails.sorted(by: { $0.key < $1.key }) where expected.1 != nil {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let attempt = try await ShipmentProcessor().extractShipment(
                subject: EmailText.header("subject", from: data) ?? "",
                sender: EmailText.header("from", from: data) ?? "",
                body: EmailText.extract(from: data), resolveLinks: false
            )
            let shipment = try XCTUnwrap(attempt.shipment, name)
            XCTAssertEqual(shipment.trackingNumber, expected.0, name)
            XCTAssertEqual(shipment.carrierCode, expected.1, name)
            XCTAssertFalse(shipment.item.isEmpty, name)
            if name == "Demo shipment.eml" { XCTAssertEqual(shipment.item, "VeloBeam 1200 Bicycle Light") }
            checked += 1
        }
        XCTAssertEqual(checked, 3)
    }

}

struct TrackingLinkTests {
    @Test func extractsOpaqueButtonsAndPreservesEscapes() {
        let message = """
        Content-Type: text/html

        <a href="https://example.com/news">Newsletter</a>
        <a href="https://example.com/marketingtracking/unsubscribe">Unsubscribe</a>
        <a href="https://www.fedex.com/preferences">Email preferences</a>
        <a href='https://cta.narvar.com/f/a/opaque%2Ftoken?x=1&#38;y=2'><span>Track your package</span></a>
        <a href=https://cta.narvar.com/f/a/opaque%2Ftoken?x=1&amp;y=2>Track shipment</a>
        <a href="javascript:alert(1)">Track order</a>
        <a href="file:///tmp/track">Track order</a>
        """
        let body = EmailText.extract(from: Data(message.utf8))
        #expect(EmailText.trackingURLs(in: body).map(\.absoluteString) == ["https://cta.narvar.com/f/a/opaque%2Ftoken?x=1&y=2"])
    }

    @Test func unwrapsNestedDestination() {
        let message = """
        Content-Type: text/html

        <a href="https://example.com/redirect?url=https%253A%252F%252Fwww.fedex.com%252Ffedextrack%252F%253Ftrknbr%253D541891252367%2526token%253Da%25252Fb">Track shipment</a>
        """
        let body = EmailText.extract(from: Data(message.utf8))
        #expect(EmailText.trackingURLs(in: body).map(\.absoluteString) == ["https://www.fedex.com/fedextrack/?trknbr=541891252367&token=a%2Fb"])
        #expect(ShipmentCodeExtractor.extract(subject: "", sender: "", body: body).trackingNumber == "541891252367")
    }

    @Test func followsRedirectAndReadsPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackingPageProtocol.self]
        let body = "Your Bicycle Light shipped.\nTracking link: https://cta.narvar.com/start"
        let evidence = try await TrackingLinkResolver.enrich(subject: "Your Bicycle Light shipped", sender: "Store", body: body, configuration: configuration, resolve: { _ in ["8.8.8.8"] })
        let shipment = ShipmentCodeExtractor.extract(subject: "Your Bicycle Light shipped", sender: "Store", body: evidence)
        #expect(shipment.trackingNumber == "541891252367")
        #expect(shipment.carrierCode == "fedex")
        #expect(evidence.contains(body))
        #expect(!evidence.contains("script-secret"))
    }

    @Test func followsCarrierLinkWithoutLoadingCarrierPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackingPageProtocol.self]
        let evidence = try await TrackingLinkResolver.enrich(subject: "", sender: "", body: "Tracking link: https://cta.narvar.com/carrier", configuration: configuration, resolve: { _ in ["8.8.8.8"] })
        let shipment = ShipmentCodeExtractor.extract(subject: "", sender: "", body: evidence)
        #expect(shipment.trackingNumber == "541891252367")
        #expect(shipment.carrierCode == "fedex")
    }

    @Test func completeTrackingSkipsNetwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackingPageProtocol.self]
        let body = "UPS tracking number: 1Z999AA10123456784\nTracking link: https://unexpected.example.com/"
        let evidence = try await TrackingLinkResolver.enrich(subject: "", sender: "", body: body, configuration: configuration, resolve: { _ in ["8.8.8.8"] })
        #expect(evidence == body)
    }

    @Test(arguments: ["failure", "loop", "private", "untrusted", "downgrade", "binary"])
    func brokenLinksPreserveEmail(path: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackingPageProtocol.self]
        let body = "Your Bicycle Light shipped.\nTracking link: https://cta.narvar.com/\(path)"
        let evidence = try await TrackingLinkResolver.enrich(subject: "", sender: "", body: body, configuration: configuration, resolve: { _ in ["8.8.8.8"] })
        #expect(evidence.contains(body))
        #expect(ShipmentCodeExtractor.extract(subject: "", sender: "", body: evidence).trackingNumber == nil)
    }

    @Test(arguments: ["http://127.0.0.1/", "http://10.0.0.1/", "http://169.254.169.254/", "http://192.168.1.1/", "http://172.16.0.1/", "http://[::1]/", "http://localhost/", "http://printer.local/", "file:///tmp/tracking", "https://user:password@example.com/", "https://example.com:8080/", "https://127-0-0-1.nip.io/track", "https://www.fedex.com.evil.example/", "https://evil.fedex.com/", "http://www.fedex.com/", "https://www.fedex.com:80/"])
    func rejectsUnsafeDestinations(address: String) throws {
        #expect(!TrackingLinkResolver.isAllowed(try #require(URL(string: address))))
    }
}

private final class TrackingPageProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "cta.narvar.com" else {
            Issue.record("Unexpected request: \(request.url?.absoluteString ?? "nil")")
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var status = 200
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        var body = "<p>Track shipment</p><p>FedEx tracking number: 541891252367</p><script>script-secret</script>"
        switch url.path {
        case "/start": status = 302; headers["Location"] = "/page"
        case "/loop": status = 302; headers["Location"] = "/loop"
        case "/private": status = 302; headers["Location"] = "http://127.0.0.1/"
        case "/untrusted": status = 302; headers["Location"] = "https://127-0-0-1.nip.io/track"
        case "/downgrade": status = 302; headers["Location"] = "http://cta.narvar.com/page"
        case "/carrier": body = "<a href='https://www.fedex.com/fedextrack/?trknbr=541891252367'>Track shipment</a>"
        case "/failure": status = 500
        case "/binary": headers["Content-Type"] = "application/octet-stream"
        default: break
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct BackgroundSafetyTests {
    @Test func disabledAutomationSkipsProcessing() async throws {
        let result = try await ShipmentProcessor().process(
            subject: "Shipment", sender: "Store",
            rawData: Data("Content-Type: text/plain\n\nTracking link: https://cta.narvar.com/start".utf8),
            automationEnabled: false
        )
        #expect(result == nil)
    }

    @Test(arguments: ["127.0.0.1", "10.0.0.1", "169.254.169.254", "172.16.0.1", "192.168.1.1",
                      "100.64.0.1", "0.0.0.0", "224.0.0.1", "::1", "::", "::ffff:127.0.0.1",
                      "fc00::1", "fe80::1", "2001:db8::1", "2002:7f00:1::", "not-an-address"])
    func rejectsNonPublicAddresses(address: String) {
        #expect(!TrackingLinkResolver.isPublicAddress(address))
    }

    @Test(arguments: ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "2001:4860:4860::8888"])
    func acceptsPublicAddresses(address: String) {
        #expect(TrackingLinkResolver.isPublicAddress(address))
    }

    @Test(arguments: [[], ["127.0.0.1"], ["8.8.8.8", "::1"]])
    func unsafeResolutionDoesNotFetch(addresses: [String]) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetworkProtocol.self]
        let body = "Tracking link: https://cta.narvar.com/start"
        let result = try await TrackingLinkResolver.enrich(subject: "", sender: "", body: body,
            configuration: configuration, resolve: { _ in addresses })
        #expect(result.contains(body))
    }
}

private final class NoNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Issue.record("Unsafe destination was requested")
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }
    override func stopLoading() {}
}

struct ParcelResponseTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParcelResponseProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test(arguments: ["rejected", "missing-success", "missing-deliveries", "malformed", "unauthorized", "forbidden"])
    func invalidCredentialsOrResponsesAreRejected(response: String) async {
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            try await ShipmentProcessor.validateAPIKey(response, session: session)
            Issue.record("Validation accepted an unsuccessful or incomplete response")
        } catch {}
    }

    @Test func validCredentialsAndEmptyDeliveriesAreAccepted() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        try await ShipmentProcessor.validateAPIKey("valid", session: session)
    }

    @Test func duplicateResponseIsNotReportedAsFailure() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let added = try await ParcelClient(apiKey: "duplicate", session: session)
            .add(tracking: "123456789", carrier: "fedex", item: "Light")
        #expect(!added)
    }
}

private final class ParcelResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var status = 200
        let body: String
        switch request.value(forHTTPHeaderField: "api-key") {
        case "valid": body = #"{"success":true,"deliveries":[]}"#
        case "missing-success": body = #"{"deliveries":[]}"#
        case "missing-deliveries": body = #"{"success":true}"#
        case "malformed": body = "not json"
        case "duplicate": body = #"{"success":false,"error_message":"Delivery already added"}"#
        case "unauthorized": status = 401; body = "Unauthorized"
        case "forbidden": status = 403; body = "Forbidden"
        default: body = #"{"success":false,"error_message":"Invalid API key"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct ShipmentQueueTests {
    @Test func manualImportBypassesAutomaticFilters() async throws {
        let (file, session, key) = try setup()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let queue = queue(file, session, key)
        #expect(try await queue.submit(subject: "Order", sender: "store@amazon.com", body: "Your parcel is on its way") == nil)
        #expect(QueueProtocol.storage.counts(key) == [0, 0])
        #expect(try await queue.submit(subject: "Order", sender: "store@amazon.com", body: "Your parcel is on its way", manual: true)?.status == .added)
        #expect(QueueProtocol.storage.counts(key) == [1, 1])
    }

    private func setup(_ mode: String = "success") throws -> (URL, URLSession, String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("imports.json")
        let key = UUID().uuidString
        QueueProtocol.storage.setMode(mode, key: key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueProtocol.self]
        return (file, URLSession(configuration: configuration), key)
    }

    private func queue(_ file: URL, _ session: URLSession, _ key: String) -> ShipmentQueue {
        ShipmentQueue(file: file, session: session, credentials: { key }, extract: { _, _, _ in
            ExtractedShipment(trackingNumber: "123456789", carrierCode: "fedex", carrierName: "FedEx", item: "Light")
        })
    }

    @Test(arguments: [false, true])
    func persistedRequestBudgetsPreventNewRequests(additionLimit: Bool) async throws {
        let (file, session, key) = try setup()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var state = ShipmentQueue.State()
        if additionLimit { state.addDates = Array(repeating: Date(), count: 20) }
        else { state.queryDates = Array(repeating: Date(), count: 20) }
        try JSONEncoder().encode(state).write(to: file)
        let queue = queue(file, session, key)
        do { _ = try await queue.submit(subject: "Shipped", sender: "Store", body: "Tracking"); Issue.record("Expected budget limit") }
        catch {}
        #expect(QueueProtocol.storage.counts(key) == (additionLimit ? [1, 0] : [0, 0]))
    }

    @Test func disabledQueueDoesNotExtractOrFetch() async throws {
        let (file, session, key) = try setup()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let queue = ShipmentQueue(file: file, session: session, credentials: { nil }, extract: { _, _, _ in
            Issue.record("Disabled automation performed extraction")
            return nil
        })
        do { _ = try await queue.submit(subject: "Shipped", sender: "Store", body: "Tracking"); Issue.record("Expected pending import") }
        catch {}
        #expect(QueueProtocol.storage.counts(key) == [0, 0])
    }

    @Test func concurrentMessagesShareCacheAndSurviveRestart() async throws {
        let (file, session, key) = try setup()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let queue = queue(file, session, key)
        async let first = queue.submit(subject: "Shipped", sender: "Store", body: "Tracking")
        async let second = queue.submit(subject: "Shipped again", sender: "Store", body: "Tracking")
        let results = try await [first, second]
        #expect(results.filter { $0?.status == .added }.count == 1)
        #expect(results.filter { $0?.status == .duplicate }.count == 1)
        #expect(QueueProtocol.storage.counts(key) == [1, 1])
        let restarted = self.queue(file, session, key)
        #expect(try await restarted.submit(subject: "Shipped", sender: "Store", body: "Tracking")?.status == .added)
        #expect(QueueProtocol.storage.counts(key) == [1, 1])
        let state = try JSONDecoder().decode(ShipmentQueue.State.self, from: Data(contentsOf: file))
        #expect(state.jobs.allSatisfy { $0.body.isEmpty })
    }

    @Test(arguments: ["server-error", "rejected", "rate-limited"])
    func failedImportsAreDiscardedWithoutRetry(mode: String) async throws {
        let (file, session, key) = try setup(mode)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let queue = queue(file, session, key)
        do { _ = try await queue.submit(subject: "Shipped", sender: "Store", body: "Tracking"); Issue.record("Expected discarded import") }
        catch ProcessingError.importDiscarded {}
        let state = try JSONDecoder().decode(ShipmentQueue.State.self, from: Data(contentsOf: file))
        #expect(state.jobs[0].status == .failed)
        #expect(state.jobs[0].subject.isEmpty && state.jobs[0].sender.isEmpty && state.jobs[0].body.isEmpty)
        #expect(state.jobs[0].shipment == nil && state.jobs[0].error == nil)
        QueueProtocol.storage.setMode("success", key: key)
        try await queue.resume()
        let restarted = self.queue(file, session, key)
        try await restarted.resume()
        do { _ = try await restarted.submit(subject: "Shipped", sender: "Store", body: "Tracking", manual: true); Issue.record("Retried discarded import") }
        catch ProcessingError.importDiscarded {}
        #expect(QueueProtocol.storage.counts(key) == [1, 1])
    }

    @Test(arguments: [ShipmentQueue.Status.pending, .failed])
    func savedFailuresAreDiscardedOnLoad(status: ShipmentQueue.Status) async throws {
        let (file, session, key) = try setup()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let job = ShipmentQueue.Job(id: ShipmentQueue.messageID(subject: "Shipped", sender: "Store", body: "Tracking"),
                                    subject: "Shipped", sender: "Store", body: "Tracking", status: status, error: "Old failure")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ShipmentQueue.State(jobs: [job]))) as! [String: Any]
        var jobs = legacy["jobs"] as! [[String: Any]]
        jobs[0]["attempts"] = 1
        jobs[0]["nextAttempt"] = Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate
        legacy["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let queue = queue(file, session, key)
        try await queue.resume()
        let state = try JSONDecoder().decode(ShipmentQueue.State.self, from: Data(contentsOf: file))
        #expect(state.jobs[0].status == .failed)
        #expect(state.jobs[0].subject.isEmpty && state.jobs[0].sender.isEmpty && state.jobs[0].body.isEmpty)
        #expect(state.jobs[0].shipment == nil && state.jobs[0].error == nil)
        do { _ = try await queue.submit(subject: "Shipped", sender: "Store", body: "Tracking"); Issue.record("Retried saved failure") }
        catch ProcessingError.importDiscarded {}
        #expect(QueueProtocol.storage.counts(key) == [0, 0])
    }

    @Test func interruptedSubmissionChecksDuplicatesOnRestart() async throws {
        let (file, session, key) = try setup("already-present")
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let job = ShipmentQueue.Job(id: ShipmentQueue.messageID(subject: "Shipped", sender: "Store", body: "Tracking"),
                                    subject: "Shipped", sender: "Store", body: "Tracking",
                                    shipment: ExtractedShipment(trackingNumber: "123456789", carrierCode: "fedex", carrierName: "FedEx", item: "Light"))
        try JSONEncoder().encode(ShipmentQueue.State(jobs: [job])).write(to: file)
        let queue = queue(file, session, key)
        try await queue.resume()
        #expect(try await queue.submit(subject: "Shipped", sender: "Store", body: "Tracking")?.status == .duplicate)
        #expect(QueueProtocol.storage.counts(key) == [1, 0])
    }

    @Test func requestLimitsPersistForNewImportsAcrossRestart() async throws {
        let (file, session, key) = try setup("rate-limited")
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let queue = queue(file, session, key)
        do { _ = try await queue.submit(subject: "Shipped", sender: "Store", body: "Tracking"); Issue.record("Expected rate limit") }
        catch {}
        let state = try JSONDecoder().decode(ShipmentQueue.State.self, from: Data(contentsOf: file))
        #expect(state.cooldown.timeIntervalSinceNow > 3_500)
        let restarted = self.queue(file, session, key)
        do { _ = try await restarted.submit(subject: "Another shipment", sender: "Store", body: "Tracking"); Issue.record("Expected persisted rate limit") }
        catch {}
        #expect(QueueProtocol.storage.counts(key) == [1, 1])
    }

    @Test func unreadableQueueIsNeverOverwritten() async throws {
        let (file, session, key) = try setup()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("damaged queue".utf8)
        try original.write(to: file)
        do { try await queue(file, session, key).resume(); Issue.record("Expected decoding failure") }
        catch {}
        #expect(try Data(contentsOf: file) == original)
        #expect(QueueProtocol.storage.counts(key) == [0, 0])
    }
}

private final class QueueProtocol: URLProtocol {
    final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var modes: [String: String] = [:]
        private var requests: [String: [Int]] = [:]
        func setMode(_ mode: String, key: String) { lock.withLock { modes[key] = mode } }
        func counts(_ key: String) -> [Int] { lock.withLock { requests[key] ?? [0, 0] } }
        func record(_ key: String, adding: Bool) -> String {
            lock.withLock {
                requests[key, default: [0, 0]][adding ? 1 : 0] += 1
                return modes[key] ?? "success"
            }
        }
    }
    static let storage = Storage()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let adding = request.httpMethod == "POST"
        let mode = Self.storage.record(request.value(forHTTPHeaderField: "api-key") ?? "", adding: adding)
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body = adding ? #"{"success":true}"# : #"{"success":true,"deliveries":[]}"#
        if !adding && mode == "already-present" {
            body = #"{"success":true,"deliveries":[{"tracking_number":"123456789","carrier_code":"fedex"}]}"#
        }
        if adding {
            switch mode {
            case "server-error": status = 503; body = "Service unavailable"
            case "rejected": body = #"{"success":false,"error_message":"Invalid tracking number"}"#
            case "rate-limited": status = 429; headers["Retry-After"] = "3600"; body = "Too many requests"
            default: break
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
