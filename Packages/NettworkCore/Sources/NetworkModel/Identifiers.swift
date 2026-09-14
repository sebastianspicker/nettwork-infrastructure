import Foundation

/// A stable, opaque identifier. Labels and asset codes are deliberately separate.
public struct ObjectID: Codable, Hashable, Sendable, Identifiable, Comparable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

/// The durable identity used by mutations, reservations, and synchronization.
///
/// UUID-backed records use `.object`; records whose natural identity is already
/// deterministic, such as a VRF-scoped IP address or an operation receipt, use
/// `.string`. Neither form is derived from a display label.
public enum ResourceKey: Hashable, Sendable, Comparable, Codable {
    case object(ObjectID)
    case string(String)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.description < rhs.description
    }

    public var description: String {
        switch self {
        case .object(let id): "object:\(id.description)"
        case .string(let value): "string:\(value)"
        }
    }

    public static func ipAddress(vrfID: ObjectID, address: String) -> Self {
        .string("ip:\(vrfID.description):\(address.lowercased())")
    }

    public static func operationReceipt(operationID: ObjectID) -> Self {
        .string("operation-receipt:\(operationID.description)")
    }

    /// Rack placement uses the device as its domain identity, but it is a
    /// separate authoritative record from that device. A typed string key
    /// prevents the two records from aliasing in CloudKit or the local mirror.
    public static func rackPlacement(deviceID: ObjectID) -> Self {
        .string("rack-placement:\(deviceID.description)")
    }

    /// One deterministic CloudKit record per authoritative resource. Creating
    /// these records with `mustNotExist` preconditions makes overlapping
    /// reservations conflict in the same atomic zone transaction.
    public static func reservationLock(for resourceKey: ResourceKey) -> Self {
        .string("reservation-lock:\(resourceKey.description)")
    }

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case object, string }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case .object:
            guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container, debugDescription: "ResourceKey object values must be canonical lowercase UUIDs.")
            }
            self = .object(ObjectID(uuid))
        case .string:
            guard !value.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "ResourceKey string values must not be empty.")
            }
            self = .string(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .object(let id):
            try container.encode(Kind.object, forKey: .kind)
            try container.encode(id.description, forKey: .value)
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public enum ObjectLink: Hashable, Sendable {
    public static let scheme = "nettwork"

    public static func url(for id: ObjectID) -> URL {
        guard let url = URL(string: "\(scheme)://object/\(id.description)") else {
            preconditionFailure("The canonical object-link URL must be valid.")
        }
        return url
    }

    /// Parses only the canonical `nettwork://object/<UUID>` route shape.
    /// Queries, fragments, credentials, additional path components, percent
    /// escapes, and case variants are rejected rather than silently normalized.
    public static func objectID(from url: URL) -> ObjectID? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "object", url.user == nil,
            url.password == nil, url.port == nil, url.query == nil,
            url.fragment == nil
        else { return nil }
        let components = url.pathComponents
        guard components.count == 2, components[0] == "/", let uuid = UUID(uuidString: components[1]) else { return nil }
        guard components[1].range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil
        else { return nil }
        return ObjectID(uuid)
    }

    public static func objectID(from value: String) -> ObjectID? {
        guard let url = URL(string: value) else { return nil }
        return objectID(from: url)
    }
}

public struct AssetCode: Codable, Hashable, Sendable, Comparable, ExpressibleByStringLiteral {
    public let value: String

    /// Codes are normalized once at the domain boundary: Unicode-normalized,
    /// trimmed, whitespace-collapsed, and uppercased using a fixed locale.
    public init(_ value: String) {
        let normalizedWhitespace = value
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
        self.value = normalizedWhitespace.uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    public init(stringLiteral value: String) { self.init(value) }
    public var isEmpty: Bool { value.isEmpty }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    private enum CodingKeys: String, CodingKey { case value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode(String.self, forKey: .value))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

/// The namespace in which an asset code must be unique. Callers choose the
/// scope explicitly; labels never participate in an asset identity.
public enum AssetCodeUniquenessScope: String, Codable, CaseIterable, Sendable {
    case workspace
    case parent
    case objectKind
}

public enum AssetCodeObjectKind: String, Codable, CaseIterable, Sendable {
    case location, rack, deviceType, device, cable
}

public struct AssetCodeClaim: Codable, Hashable, Sendable {
    public var code: AssetCode
    public var objectID: ObjectID
    public var objectKind: AssetCodeObjectKind
    public var workspaceID: ObjectID
    public var parentID: ObjectID?

    public init(code: AssetCode, objectID: ObjectID, objectKind: AssetCodeObjectKind, workspaceID: ObjectID, parentID: ObjectID? = nil) {
        self.code = code
        self.objectID = objectID
        self.objectKind = objectKind
        self.workspaceID = workspaceID
        self.parentID = parentID
    }
}

public enum AssetCodeValidationError: Error, Hashable, Sendable {
    case emptyCode(ObjectID)
    case missingParentScope(ObjectID)
    case duplicateCode(AssetCode, scope: AssetCodeUniquenessScope)
}

public enum AssetCodeValidator {
    public static func validate(_ claims: [AssetCodeClaim], scope: AssetCodeUniquenessScope) throws {
        var seen = Set<String>()
        for claim in claims {
            guard !claim.code.isEmpty else { throw AssetCodeValidationError.emptyCode(claim.objectID) }
            let namespace: String
            switch scope {
            case .workspace:
                namespace = claim.workspaceID.description
            case .parent:
                guard let parentID = claim.parentID else { throw AssetCodeValidationError.missingParentScope(claim.objectID) }
                namespace = parentID.description
            case .objectKind:
                namespace = "\(claim.workspaceID.description):\(claim.objectKind.rawValue)"
            }
            let key = "\(namespace):\(claim.code.value)"
            guard seen.insert(key).inserted else { throw AssetCodeValidationError.duplicateCode(claim.code, scope: scope) }
        }
    }
}

public struct CustomFieldValue: Codable, Hashable, Sendable {
    public enum Value: Codable, Hashable, Sendable {
        case text(String)
        case number(Double)
        case flag(Bool)
        case date(Date)

        private enum CodingKeys: String, CodingKey { case kind, text, number, flag, date }
        private enum Kind: String, Codable { case text, number, flag, date }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .text: self = .text(try container.decode(String.self, forKey: .text))
            case .number: self = .number(try container.decode(Double.self, forKey: .number))
            case .flag: self = .flag(try container.decode(Bool.self, forKey: .flag))
            case .date: self = .date(try container.decode(Date.self, forKey: .date))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let value):
                try container.encode(Kind.text, forKey: .kind)
                try container.encode(value, forKey: .text)
            case .number(let value):
                try container.encode(Kind.number, forKey: .kind)
                try container.encode(value, forKey: .number)
            case .flag(let value):
                try container.encode(Kind.flag, forKey: .kind)
                try container.encode(value, forKey: .flag)
            case .date(let value):
                try container.encode(Kind.date, forKey: .kind)
                try container.encode(value, forKey: .date)
            }
        }
    }

    public var key: String
    public var value: Value

    public init(key: String, value: Value) {
        self.key = Self.normalizedKey(key)
        self.value = value
    }

    public static func normalizedKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private enum CodingKeys: String, CodingKey { case key, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try container.decode(String.self, forKey: .key), value: try container.decode(Value.self, forKey: .value))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(value, forKey: .value)
    }
}

public enum CustomFieldKind: String, Codable, CaseIterable, Sendable {
    case text, number, flag, date, choice
}

public struct CustomFieldSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var displayName: String
    public var kind: CustomFieldKind
    public var isRequired: Bool
    public var defaultValue: CustomFieldValue.Value?
    /// Only `.choice` schemas use these values; choice values are text values.
    public var choices: [String]

    public init(
        key: String, displayName: String, kind: CustomFieldKind, isRequired: Bool = false, defaultValue: CustomFieldValue.Value? = nil, choices: [String] = []
    ) {
        self.key = CustomFieldValue.normalizedKey(key)
        self.displayName = displayName
        self.kind = kind
        self.isRequired = isRequired
        self.defaultValue = defaultValue
        self.choices = choices
    }
}

public enum CustomFieldValidationError: Error, Hashable, Sendable {
    case emptySchemaKey
    case duplicateSchemaKey(String)
    case invalidChoices(String)
    case duplicateValueKey(String)
    case unknownField(String)
    case invalidDefault(String)
    case missingRequiredField(String)
    case invalidValueType(String, expected: CustomFieldKind)
    case invalidChoice(String, value: String)
}

public enum CustomFieldValidator {
    public static func validate(values: [CustomFieldValue], against schemas: [CustomFieldSchema]) throws {
        _ = try resolvedValues(values: values, against: schemas)
    }

    /// Applies schema defaults and returns fields ordered by their schema order.
    public static func resolvedValues(values: [CustomFieldValue], against schemas: [CustomFieldSchema]) throws -> [CustomFieldValue] {
        let schemaByKey = try validatedSchemas(schemas)
        let valuesByKey = try validatedValues(values, schemas: schemaByKey)
        return try schemas.compactMap { schema in
            if let value = valuesByKey[schema.key] { return value }
            if let defaultValue = schema.defaultValue { return CustomFieldValue(key: schema.key, value: defaultValue) }
            guard !schema.isRequired else { throw CustomFieldValidationError.missingRequiredField(schema.key) }
            return nil
        }
    }

    private static func validatedSchemas(_ schemas: [CustomFieldSchema]) throws -> [String: CustomFieldSchema] {
        var schemaByKey: [String: CustomFieldSchema] = [:]
        for schema in schemas {
            guard !schema.key.isEmpty else { throw CustomFieldValidationError.emptySchemaKey }
            guard schemaByKey.updateValue(schema, forKey: schema.key) == nil else { throw CustomFieldValidationError.duplicateSchemaKey(schema.key) }
            guard (schema.kind == .choice) == !schema.choices.isEmpty else { throw CustomFieldValidationError.invalidChoices(schema.key) }
            if let defaultValue = schema.defaultValue, !isValid(defaultValue, for: schema) {
                throw CustomFieldValidationError.invalidDefault(schema.key)
            }
        }
        return schemaByKey
    }

    private static func validatedValues(_ values: [CustomFieldValue], schemas: [String: CustomFieldSchema]) throws -> [String: CustomFieldValue] {
        var valuesByKey: [String: CustomFieldValue] = [:]
        for value in values {
            let key = CustomFieldValue.normalizedKey(value.key)
            guard valuesByKey.updateValue(CustomFieldValue(key: key, value: value.value), forKey: key) == nil else {
                throw CustomFieldValidationError.duplicateValueKey(key)
            }
            guard let schema = schemas[key] else { throw CustomFieldValidationError.unknownField(key) }
            try validate(value.value, key: key, schema: schema)
        }
        return valuesByKey
    }

    private static func validate(_ value: CustomFieldValue.Value, key: String, schema: CustomFieldSchema) throws {
        guard isValid(value, for: schema) else {
            if case .choice = schema.kind, case .text(let choice) = value {
                throw CustomFieldValidationError.invalidChoice(key, value: choice)
            }
            throw CustomFieldValidationError.invalidValueType(key, expected: schema.kind)
        }
    }

    private static func isValid(_ value: CustomFieldValue.Value, for schema: CustomFieldSchema) -> Bool {
        switch (schema.kind, value) {
        case (.text, .text), (.number, .number), (.flag, .flag), (.date, .date):
            true
        case (.choice, .text(let choice)):
            schema.choices.contains(choice)
        default:
            false
        }
    }
}
