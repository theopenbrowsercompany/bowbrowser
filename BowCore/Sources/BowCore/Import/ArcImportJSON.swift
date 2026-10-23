import Foundation

/// A loosely typed JSON value. Arc's sidebar format is undocumented, so the importer reads it
/// tolerantly instead of decoding it into fixed types that one unexpected key would break.
enum ArcJSON: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ArcJSON])
    case object([String: ArcJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ArcJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ArcJSON].self))
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var array: [ArcJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: ArcJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> ArcJSON? {
        object?[key]
    }

    /// The name of a Swift-style enum value: a plain string (`"pinned"`) or an object with one
    /// case key (`{"unpinned": {...}}`). Several keys resolve to the smallest, so results are stable.
    var caseName: String? {
        if let string { return string }
        return object?.keys.min()
    }

    /// A string or number found at this value or, for wrapper objects, in its first nested value.
    var scalarText: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .object(let object):
            guard let key = object.keys.min() else { return nil }
            return object[key]?.scalarText
        default: return nil
        }
    }

    /// Pairs a flat alternating key, value array into entries.
    /// `droppedTail` is true when the array had an odd length and its last element was ignored.
    func keyValuePairs() -> (pairs: [(key: ArcJSON, value: ArcJSON)], droppedTail: Bool)? {
        guard let elements = array else { return nil }
        var pairs: [(key: ArcJSON, value: ArcJSON)] = []
        var index = 0
        while index + 1 < elements.count {
            pairs.append((elements[index], elements[index + 1]))
            index += 2
        }
        return (pairs, elements.count % 2 != 0)
    }
}
