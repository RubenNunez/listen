import Foundation

struct MCPTool: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var inputSchema: [String: HarnessValue]
    var title: String?
    var annotations: DisplayAnnotations?

    /// Only display metadata is retained, never annotation-based permissions.
    struct DisplayAnnotations: Codable, Equatable, Sendable {
        var title: String?
    }

    var displayName: String {
        Self.displayLabel(title) ?? Self.displayLabel(annotations?.title) ?? Self.displayLabel(name) ?? "Tool"
    }

    private static func displayLabel(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 512, raw.count <= 120,
              raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func read(_ value: HarnessValue) throws -> Self {
        guard let object = value.object, let name = object["name"]?.string,
              !name.isEmpty, name.utf8.count <= 128, let schema = object["inputSchema"]?.object else { throw MCPFailure.invalidResponse }
        var tool = Self(name: name, description: String((object["description"]?.string ?? "").prefix(1000)), inputSchema: schema)
        tool.title = Self.displayLabel(object["title"]?.string)
        if let annotations = object["annotations"]?.object {
            tool.annotations = .init(title: Self.displayLabel(annotations["title"]?.string))
        }
        if tool.needsExplicitDomain, tool.fields != nil {
            tool.inputSchema["required"] = .array(tool.required.sorted().map(HarnessValue.string))
        }
        return tool
    }

    /// A deliberately bounded schema subset; unsupported tools remain visible but unavailable.
    var fields: [String: ConversationToolField]? {
        guard name.wholeMatch(of: /[A-Za-z0-9_.-]{1,100}/) != nil,
              inputSchema["type"] == .string("object"),
              Set(inputSchema.keys).isSubset(of: ["type", "properties", "required", "additionalProperties", "description", "title", "$schema"]),
              let properties = inputSchema["properties"]?.object, properties.count <= 32 else { return nil }
        var result: [String: ConversationToolField] = [:]
        for (name, value) in properties {
            guard name.wholeMatch(of: /[A-Za-z0-9_.-]{1,100}/) != nil, let schema = value.object,
                  let field = Self.field(schema) else { return nil }
            result[name] = field
        }
        if let required = inputSchema["required"] {
            guard case .array(let values) = required, values.allSatisfy({ $0.string != nil && properties[$0.string!] != nil }),
                  Set(values.compactMap(\.string)).count == values.count else { return nil }
        }
        return result
    }

    private static func field(_ schema: [String: HarnessValue], allowArray: Bool = true) -> ConversationToolField? {
        let scalarKeys: Set<String> = ["type", "description", "title", "default", "enum", "minimum", "maximum", "minLength", "maxLength"]
        let isArray = schema["type"] == .string("array")
        let allowed = isArray ? Set(["type", "description", "title", "default", "enum", "items", "minItems", "maxItems", "uniqueItems"]) : scalarKeys
        guard Set(schema.keys).isSubset(of: allowed) else { return nil }
        if let enumeration = schema["enum"] {
            guard case .array = enumeration else { return nil }
        }
        for key in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"] {
            if let bound = schema[key] {
                guard let n = bound.numeric, n.isFinite else { return nil }
                if key != "minimum" && key != "maximum", n < 0 || n.rounded() != n { return nil }
            }
        }
        switch schema["type"]?.string {
        case "string": return .string
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "array":
            guard allowArray, let items = schema["items"]?.object,
                  let item = field(items, allowArray: false) else { return nil }
            if let unique = schema["uniqueItems"], unique != .bool(true) && unique != .bool(false) { return nil }
            return .array(item)
        default: return nil
        }
    }

    /// Home Assistant's generic on/off tools otherwise accept an empty object,
    /// which can fail or imply every device. Require an explicit device domain;
    /// never infer a global scope or manufacture a default target in the executor.
    private var needsExplicitDomain: Bool {
        ["HassTurnOn", "HassTurnOff"].contains(name)
            && inputSchema["properties"]?.object?["domain"]?.object?["type"] == .string("array")
    }

    var required: Set<String> {
        let declared: Set<String>
        if case .array(let values) = inputSchema["required"] { declared = Set(values.compactMap(\.string)) }
        else { declared = [] }
        return needsExplicitDomain ? declared.union(["domain"]) : declared
    }

    func accepts(_ arguments: [String: ConversationValue]) -> Bool {
        if needsExplicitDomain {
            guard case .array(let domains) = arguments["domain"], !domains.isEmpty else { return false }
        }
        guard let fields, required.isSubset(of: Set(arguments.keys)), Set(arguments.keys).isSubset(of: Set(fields.keys)) else { return false }
        for (name, value) in arguments {
            guard fields[name]?.accepts(value) == true, let schema = inputSchema["properties"]?.object?[name]?.object else { return false }
            guard Self.accepts(value, schema: schema) else { return false }
        }
        return true
    }

    private static func accepts(_ value: ConversationValue, schema: [String: HarnessValue]) -> Bool {
        if case .array(let allowed) = schema["enum"], !allowed.contains(value.harness) { return false }
        if let number = value.harness.numeric {
            if !number.isFinite { return false }
            if let minimum = schema["minimum"]?.numeric, number < minimum { return false }
            if let maximum = schema["maximum"]?.numeric, number > maximum { return false }
        }
        if case .string(let text) = value {
            if let minimum = schema["minLength"]?.numeric, Double(text.count) < minimum { return false }
            if let maximum = schema["maxLength"]?.numeric, Double(text.count) > maximum { return false }
        }
        if case .array(let values) = value {
            guard let items = schema["items"]?.object else { return false }
            if let minimum = schema["minItems"]?.numeric, Double(values.count) < minimum { return false }
            if let maximum = schema["maxItems"]?.numeric, Double(values.count) > maximum { return false }
            if schema["uniqueItems"] == .bool(true) {
                for index in values.indices where values[..<index].contains(values[index]) { return false }
            }
            if !values.allSatisfy({ accepts($0, schema: items) }) { return false }
        }
        return true
    }
}

extension MCPTool {
    private enum CodingKeys: String, CodingKey { case name, description, inputSchema, title, annotations }

    /// Old cached descriptors have no display fields. Malformed optional hints
    /// must not invalidate an otherwise unchanged tool or its saved identity.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decode(String.self, forKey: .description)
        inputSchema = try values.decode([String: HarnessValue].self, forKey: .inputSchema)
        title = try? values.decodeIfPresent(String.self, forKey: .title)
        annotations = try? values.decodeIfPresent(DisplayAnnotations.self, forKey: .annotations)
    }
}

extension MCPTool.DisplayAnnotations {
    private enum CodingKeys: String, CodingKey { case title }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try? values.decodeIfPresent(String.self, forKey: .title)
    }
}

extension HarnessValue {
    var numeric: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .unsigned(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }
}
