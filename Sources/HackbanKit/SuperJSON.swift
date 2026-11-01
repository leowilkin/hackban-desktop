import Foundation

/// The subset of superjson (https://github.com/flightcontrolhq/superjson) Hackban's tRPC API needs.
///
/// Inputs: `{"json": <value>, "meta": {"values": {"<path>": ["Date"]}}}`, where dates are ISO strings
/// and every date's path (keys joined by ".") is listed in `meta.values`.
/// Outputs: the server wraps values the same way. Dates arrive as ISO strings in `json`, so decoding
/// `json` with an ISO date strategy is enough and `meta` can be ignored.
public enum SuperJSON {
    public static func serialize(_ value: JSONValue) -> JSONValue {
        var dates: [String] = []
        collectDates(value, path: [], into: &dates)
        guard !dates.isEmpty else { return ["json": value] }
        var values: [String: JSONValue] = [:]
        for p in dates { values[p] = ["Date"] }
        return ["json": value, "meta": ["values": .object(values)]]
    }

    public static func encode(_ value: JSONValue) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(serialize(value))
    }

    private static func collectDates(_ v: JSONValue, path: [String], into out: inout [String]) {
        switch v {
        case .date: out.append(path.map(escape).joined(separator: "."))
        case .array(let a): for (i, x) in a.enumerated() { collectDates(x, path: path + [String(i)], into: &out) }
        case .object(let o): for k in o.keys.sorted() { collectDates(o[k]!, path: path + [k], into: &out) }
        default: break
        }
    }

    /// superjson escapes literal dots in keys with a backslash.
    private static func escape(_ key: String) -> String {
        key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ".", with: "\\.")
    }
}

/// Decodes `{"json": T}`. A missing `json` (superjson's encoding of `undefined`) decodes as nil.
struct SuperJSONEnvelope<T: Decodable>: Decodable {
    let json: T?
}
