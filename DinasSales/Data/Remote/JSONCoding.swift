import Foundation

/// Coders JSON compartidos para hablar con el middleware.
///
/// Fechas en ISO-8601 (contrato `format: date-time`). Se aceptan con y sin fracción
/// de segundo, porque distintos backends serializan de una u otra forma.
enum JSONCoding {

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            if let date = iso8601WithFraction.date(from: raw) ?? iso8601Plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: d.codingPath, debugDescription: "Fecha ISO-8601 inválida: \(raw)")
            )
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, e in
            var container = e.singleValueContainer()
            try container.encode(iso8601WithFraction.string(from: date))
        }
        return encoder
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
