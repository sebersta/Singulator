import CryptoKit
import Foundation

/// Owned by the Mail extension. Both background actions and the popup use this single worker.
actor ShipmentQueue {
    static let shared = ShipmentQueue()
    static let fileURL = URL.applicationSupportDirectory
        .appendingPathComponent("ParcelSingulator", isDirectory: true).appendingPathComponent("imports.json")

    enum Status: String, Codable { case pending, failed, added, duplicate, empty }
    struct Job: Codable {
        let id: String
        let subject: String
        let sender: String
        var body: String
        var shipment: ExtractedShipment?
        var status = Status.pending
        var error: String?
    }
    struct State: Codable {
        var jobs: [Job] = []
        var deliveries: [ParcelDelivery]?
        var queriedAt = Date.distantPast
        var queryDates: [Date] = []
        var addDates: [Date] = []
        var cooldown = Date.distantPast
        var credentialID = ""
    }

    private let file: URL
    private let session: URLSession
    private let credentials: @Sendable () -> String?
    private let extract: @Sendable (String, String, String) async throws -> ExtractedShipment?
    private var state: State?
    private var worker: Task<Void, Error>?

    init(file: URL = fileURL, session: URLSession = .shared,
         credentials: @escaping @Sendable () -> String? = {
             guard ParcelKeychain.isAutomationEnabled else { return nil }
             return ParcelKeychain.load()?.trimmingCharacters(in: .whitespacesAndNewlines)
         },
         extract: @escaping @Sendable (String, String, String) async throws -> ExtractedShipment? = {
             // Submission already applied automatic filters or received a manual request.
             try await ShipmentProcessor().extractShipment(subject: $0, sender: $1, body: $2, manual: true).shipment
         }) {
        self.file = file
        self.session = session
        self.credentials = credentials
        self.extract = extract
    }

    nonisolated static func messageID(subject: String, sender: String, body: String) -> String {
        let data = (try? JSONEncoder().encode([subject, sender, body])) ?? Data()
        return digest(data)
    }

    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func submit(subject: String, sender: String, body: String, manual: Bool = false) async throws -> ShipmentResult? {
        guard manual || (!ShipmentProcessor.isIgnoredSender(sender) && ShipmentProcessor.looksLikeShipment(body)) else { return nil }
        try load()
        let id = Self.messageID(subject: subject, sender: sender, body: body)
        if !state!.jobs.contains(where: { $0.id == id }) {
            state!.jobs.append(Job(id: id, subject: subject, sender: sender, body: body))
        }
        try persist()
        try await resume()
        let job = state!.jobs.first { $0.id == id }!
        switch job.status {
        case .empty: return nil
        case .failed: throw ProcessingError.importDiscarded
        case .pending:
            throw ProcessingError.importPending(job.error ?? "Import is queued. Enable automation and save a valid Parcel key to continue.")
        case .added, .duplicate:
            guard let shipment = job.shipment else { throw ProcessingError.invalidExtraction }
            return ShipmentResult(trackingNumber: shipment.trackingNumber, carrierCode: shipment.carrierCode,
                                  carrierName: shipment.carrierName, item: shipment.item,
                                  status: job.status == .added ? .added : .duplicate)
        }
    }

    func resume() async throws {
        try load()
        if let worker { try await worker.value; return }
        let task = Task { try await drain() }
        worker = task
        do {
            try await task.value
            worker = nil
        } catch {
            worker = nil
            throw error
        }
    }

    private func load() throws {
        guard state == nil else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            // Never replace an unreadable queue with an empty one.
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            // Discard failures saved by versions that scheduled retries.
            for index in state!.jobs.indices where state!.jobs[index].status == .failed
                || (state!.jobs[index].status == .pending && state!.jobs[index].error != nil) {
                state!.jobs[index] = Job(id: state!.jobs[index].id, subject: "", sender: "", body: "", status: .failed)
            }
            try persist()
        } else {
            state = State()
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state!).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func drain() async throws {
        while let key = credentials(), !key.isEmpty,
              let index = state!.jobs.firstIndex(where: { $0.status == .pending }) {
            try Task.checkCancellation()
            let credentialID = Self.digest(Data(key.utf8))
            if state!.credentialID != credentialID {
                state!.credentialID = credentialID
                state!.deliveries = nil
                // Keep rate-limit history when keys change; they may belong to the same account.
            }
            var job = state!.jobs[index]
            do {
                if job.shipment == nil {
                    job.shipment = try await extract(job.subject, job.sender, job.body)
                    state!.jobs[index] = job
                    try persist()
                }
                guard let shipment = job.shipment else {
                    job.status = .empty
                    job.body = ""
                    state!.jobs[index] = job
                    try persist()
                    continue
                }
                guard credentials() == key else { break }
                let client = ParcelClient(apiKey: key, session: session)
                let now = Date()
                guard state!.cooldown <= now else { throw ProcessingError.rateLimited(state!.cooldown) }
                if state!.deliveries == nil || now.timeIntervalSince(state!.queriedAt) >= 180 {
                    state!.queryDates.removeAll { now.timeIntervalSince($0) >= 3_600 }
                    if state!.queryDates.count >= 20 {
                        throw ProcessingError.rateLimited(state!.queryDates[0].addingTimeInterval(3_600))
                    }
                    state!.queryDates.append(now)
                    try persist() // Reserve quota before sending, including across process termination.
                    state!.deliveries = try await client.activeDeliveries()
                    state!.queriedAt = Date()
                    try persist()
                }
                guard credentials() == key else { break }
                var deliveries = state!.deliveries ?? []
                let normalized = shipment.trackingNumber.uppercased().filter { $0.isLetter || $0.isNumber }
                if deliveries.contains(where: {
                    $0.carrier_code == shipment.carrierCode && $0.tracking_number.uppercased().filter { $0.isLetter || $0.isNumber } == normalized
                }) {
                    job.status = .duplicate
                } else {
                    state!.addDates.removeAll { now.timeIntervalSince($0) >= 86_400 }
                    if state!.addDates.count >= 20 {
                        throw ProcessingError.rateLimited(state!.addDates[0].addingTimeInterval(86_400))
                    }
                    state!.addDates.append(now)
                    // An interrupted submission must refresh duplicates before trying again.
                    state!.deliveries = nil
                    try persist()
                    let added = try await client.add(tracking: shipment.trackingNumber, carrier: shipment.carrierCode, item: shipment.item)
                    job.status = added ? .added : .duplicate
                    deliveries.append(ParcelDelivery(tracking_number: shipment.trackingNumber, carrier_code: shipment.carrierCode))
                    state!.deliveries = deliveries
                }
                job.error = nil
                job.body = "" // Completed imports retain identifiers, never the email body.
            } catch {
                if case ProcessingError.rateLimited(let date) = error {
                    state!.cooldown = max(state!.cooldown, date)
                }
                // Keep only the fingerprint so Mail cannot submit this failed message again.
                job = Job(id: job.id, subject: "", sender: "", body: "", status: .failed)
            }
            state!.jobs[index] = job
            try persist()
        }
    }

}
