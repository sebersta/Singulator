import Foundation

enum EmailText {
    // Bound raw input before decoding, including headers and attachments.
    static let maximumMessageBytes = 1_048_576

    private enum Kind { case plain, html, fallback }
    private struct Candidate {
        let kind: Kind
        let text: String
        var links: [String] = []
    }

    static func extract(from data: Data) -> String {
        guard data.count <= maximumMessageBytes else { return "" }
        let raw = normalized(data)
        let candidates = parse(raw)
        let meaningful = candidates.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let preferred = meaningful.filter { $0.kind == .plain }
        let selected = preferred.isEmpty ? meaningful.filter { $0.kind == .html } : preferred
        let usable = selected.isEmpty ? meaningful : selected
        return (usable.map(\.text) + candidates.flatMap(\.links)).joined(separator: "\n")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func header(_ name: String, from data: Data) -> String? {
        guard data.count <= maximumMessageBytes else { return nil }
        return split(normalized(data)).0[name.lowercased()]
    }

    static func trackingURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<URL>()
        return text.components(separatedBy: "\n").flatMap { line -> [URL] in
            guard line.range(of: #"(?i)unsubscribe|opt.?out|preferences|privacy"#, options: .regularExpression) == nil,
                  line.localizedCaseInsensitiveContains("track") || line.localizedCaseInsensitiveContains("shipment") else { return [] }
            return detector.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url).inserted else { return nil }
                return url
            }
        }
    }

    private static func normalized(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func parse(_ part: String) -> [Candidate] {
        let (headers, body) = split(part)
        let rawContentType = headers["content-type"] ?? "text/plain"
        let contentType = rawContentType.lowercased()

        if contentType.hasPrefix("multipart/"), let boundary = parameter("boundary", in: rawContentType) {
            return body.components(separatedBy: "--\(boundary)").dropFirst().flatMap { section in
                let content = section.drop(while: { $0 == "\n" })
                let marker = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return marker.hasPrefix("--") || marker.isEmpty ? [] : parse(String(content))
            }
        }

        let disposition = headers["content-disposition"]?.lowercased() ?? ""
        guard !disposition.contains("attachment"), !contentType.contains("name=") else { return [] }
        guard contentType.hasPrefix("text/") || headers.isEmpty else { return [] }

        let decoded = decode(body, transferEncoding: headers["content-transfer-encoding"], charset: parameter("charset", in: contentType))
        if contentType.hasPrefix("text/html") {
            return [Candidate(kind: .html, text: stripHTML(decoded), links: trackingLinks(in: decoded))]
        }
        return [Candidate(kind: contentType.hasPrefix("text/plain") ? .plain : .fallback, text: decoded)]
    }

    private static func split(_ part: String) -> ([String: String], String) {
        guard let range = part.range(of: "\n\n") else { return ([:], part) }
        let unfolded = part[..<range.lowerBound].replacingOccurrences(of: #"\n[ \t]+"#, with: " ", options: .regularExpression)
        var headers: [String: String] = [:]
        for line in unfolded.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return (headers, String(part[range.upperBound...]))
    }

    private static func parameter(_ name: String, in value: String) -> String? {
        let pattern = "(?:^|;)\\s*\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]+)\"|([^;\\s]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            if let range = Range(match.range(at: index), in: value) { return String(value[range]) }
        }
        return nil
    }

    private static func decode(_ body: String, transferEncoding: String?, charset: String?) -> String {
        let encoding = transferEncoding?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data
        if encoding == "base64" {
            data = Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data(body.utf8)
        } else if encoding == "quoted-printable" {
            data = quotedPrintable(body)
        } else {
            data = Data(body.utf8)
        }
        return String(data: data, encoding: stringEncoding(charset))
            ?? String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func quotedPrintable(_ value: String) -> Data {
        let bytes = Array(value.replacingOccurrences(of: "=\n", with: "").utf8)
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 61, index + 2 < bytes.count,
               let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                output.append(high * 16 + low)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return Data(output)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func stringEncoding(_ charset: String?) -> String.Encoding {
        switch charset?.lowercased() {
        case "iso-8859-1", "latin1": .isoLatin1
        case "windows-1252", "cp1252": .windowsCP1252
        case "us-ascii": .ascii
        default: .utf8
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
            .replacingOccurrences(of: #"(?is)<(script|style)\b.*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</tr>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, character) in entities { text = text.replacingOccurrences(of: entity, with: character) }
        return text
    }

    private static func trackingLinks(in html: String) -> [String] {
        let html = html.replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style)\b.*?</\1>"#, with: " ", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<a\b[^>]*?\s+href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = (1...3).compactMap({ Range(match.range(at: $0), in: html) }).first,
                  let labelRange = Range(match.range(at: 4), in: html) else { return nil }
            let link = embeddedDestination(in: decodeLinkEntities(String(html[range])))
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            let label = stripHTML(String(html[labelRange]))
            let isTrackingLabel = label.range(of: #"(?i)\b(?:track(?:ing)?|shipment|delivery\s+status)\b"#, options: .regularExpression) != nil
            let isTrackingURL = link.range(of: #"(?i)[/?&=_-](?:track(?:ing)?(?:[_-]?(?:number|numbers|id|nums))?|fedextrack|tlabels|trknbr|trknumbers)(?:[/?&=_-]|$)"#, options: .regularExpression) != nil
            guard "\(label) \(link)".range(of: #"(?i)unsubscribe|opt.?out|preferences|privacy"#, options: .regularExpression) == nil,
                  isTrackingLabel || isTrackingURL,
                  seen.insert(link).inserted else { return nil }
            return "Tracking link: \(link)"
        }.prefix(20).map { $0 }
    }

    private static func embeddedDestination(in link: String) -> String {
        var destination = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // ponytail: unwrap at most five query redirects; deeper wrappers go through the network resolver.
        for _ in 0..<5 {
            let parameters = URLComponents(string: destination)?.queryItems ?? []
            let nested = parameters.compactMap { parameter -> String? in
                guard ["url", "u", "target", "redirect", "redirect_url", "redirect_uri", "destination", "link"].contains(parameter.name.lowercased()),
                      var value = parameter.value else { return nil }
                for _ in 0..<2 where !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
                    value = value.removingPercentEncoding ?? value
                }
                guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil else { return nil }
                return value
            }.first
            guard let nested, nested != destination else { break }
            destination = nested
        }
        return destination
    }

    private static func decodeLinkEntities(_ value: String) -> String {
        var text = value
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-f]+|[0-9]+);"#, options: .caseInsensitive) {
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let digits = Range(match.range(at: 1), in: text), let range = Range(match.range, in: text) else { continue }
                let number = String(text[digits]).lowercased()
                guard let code = UInt32(number.hasPrefix("x") ? String(number.dropFirst()) : number, radix: number.hasPrefix("x") ? 16 : 10),
                      let scalar = UnicodeScalar(code) else { continue }
                text.replaceSubrange(range, with: String(scalar))
            }
        }
        return text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

struct CodeShipment {
    let trackingNumber: String?
    let carrierCode: String?
    let carrierName: String?
    let item: String?

    var isComplete: Bool {
        trackingNumber != nil && carrierCode != nil && carrierName != nil && item != nil
    }
}

enum ShipmentCodeExtractor {
    private static let carriers = [
        (code: "ups", name: "UPS", pattern: #"\bups\b|united parcel service"#),
        (code: "usps", name: "USPS", pattern: #"\busps\b|united states postal service"#),
        (code: "fedex", name: "FedEx", pattern: #"\bfedex\b|federal express"#),
        (code: "dhl", name: "DHL", pattern: #"\bdhl(?:global|express|ecommerce)?\b"#),
        (code: "ont", name: "OnTrac", pattern: #"\bontrac\b"#),
        (code: "laser", name: "LaserShip", pattern: #"\blasership\b"#),
    ]

    static func extract(subject: String, sender: String, body: String) -> CodeShipment {
        let email = "\(sender)\n\(subject)\n\(body)"
        let tracking = trackingNumber(in: email)
        let carrier = carrier(in: email, trackingNumber: tracking)
        return CodeShipment(
            trackingNumber: tracking,
            carrierCode: carrier?.code,
            carrierName: carrier?.name,
            item: item(subject: subject, body: body)
        )
    }

    private static func trackingNumber(in text: String) -> String? {
        let patterns = [
            #"\b(1Z[0-9A-Z]{16})\b"#,
            #"(?:tracking(?:\s+(?:number|no\.?|id))?|track(?:ing)?(?:\s+id)?)\s*(?:(?:is|:|#|-)\s*)?((?!is\b|unavailable\b)[A-Z0-9][A-Z0-9-]{5,49})"#,
            #"[?&](?:tracking(?:[_-]?(?:number|numbers|id))?|track(?:[_-]?(?:id|num|number|numbers|nums))?|tlabels|trknbr|trknumbers|tn)=([A-Z0-9-]{6,50})(?=[&#\s]|$)"#,
            #"/(?:track|tracking)/([A-Z0-9-]{6,50})(?:[/?#&]|$)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let candidate = text[range].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}"))
                if candidate.contains(where: \Character.isNumber) { return candidate }
            }
        }
        return nil
    }

    private static func carrier(in text: String, trackingNumber: String?) -> (code: String, name: String)? {
        if trackingNumber?.uppercased().hasPrefix("1Z") == true { return ("ups", "UPS") }
        if trackingNumber?.uppercased().hasPrefix("JD") == true { return ("dhl", "DHL") }
        if let trackingNumber, let range = text.range(of: trackingNumber, options: .caseInsensitive) {
            let start = text.index(range.lowerBound, offsetBy: -200, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
            let nearby = carriers.filter { firstMatch($0.pattern, in: String(text[start..<end])) != nil }
            if nearby.count == 1 { return (nearby[0].code, nearby[0].name) }
        }
        let matches = carriers.filter { firstMatch($0.pattern, in: text) != nil }
        return matches.count == 1 ? (matches[0].code, matches[0].name) : nil
    }

    private static func item(subject: String, body: String) -> String? {
        let patterns = [
            #"^(?:shipping update:\s*)?(?:your\s+)?(.+?)\s+(?:has\s+|was\s+|is\s+)?shipped[.!]?$"#,
            #"^(?:your\s+)?(.+?)\s+is on (?:its|the) way[.!]?$"#,
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: subject), let item = cleanedItem(value) { return item }
        }
        let bodyPatterns = [
            #"^(?:item|product|shipment contents?)\s*:\s*([^\n]{3,100})$"#,
            #"^your\s+([^\n]{3,100}?)\s+(?:has\s+|was\s+|is\s+)?shipped[.!]?$"#,
        ]
        for pattern in bodyPatterns {
            if let value = firstCapture(pattern, in: body, anchorsMatchLines: true), let item = cleanedItem(value) { return item }
        }
        return nil
    }

    private static func cleanedItem(_ value: String) -> String? {
        let item = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let generic = ["order", "package", "parcel", "shipment", "delivery", "item", "items", "order update"]
        guard item.count >= 3, item.count <= 100, !generic.contains(item.lowercased()),
              item.range(of: #"(?i)\b(order|package|parcel|shipment|delivery|tracking)\b"#, options: .regularExpression) == nil else { return nil }
        return item
    }

    private static func firstCapture(_ pattern: String, in text: String, anchorsMatchLines: Bool = false) -> String? {
        let options: NSRegularExpression.Options = anchorsMatchLines ? [.caseInsensitive, .anchorsMatchLines] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
