import Foundation

extension HarnessConfiguration {
    func validate() throws {
        guard version == 2 else { throw HarnessProblem("version", "unsupported configuration version") }
        guard revision > 0 else { throw HarnessProblem("revision", "must be positive") }
        for (name, keys) in [
            ("connections", Array(connections.keys)), ("models", Array(models.keys)),
            ("prompts", Array(prompts.keys)), ("roles", Array(roles.keys)),
            ("flows", Array(flows.keys)), ("profiles", Array(profiles.keys)),
        ] {
            guard keys.count <= 256 else { throw HarnessProblem(name, "too many entries") }
            for key in keys { try Self.identifier(key, path: name) }
        }
        guard profiles[activeProfile] != nil else { throw HarnessProblem("activeProfile", "missing profile") }
        for (id, connection) in connections.sorted(by: { $0.key < $1.key }) {
            try connection.validate(path: "connections.\(id)")
        }
        for (id, model) in models.sorted(by: { $0.key < $1.key }) {
            let path = "models.\(id)"
            guard let connection = connections[model.connection],
                  let operation = connection.operations[model.operation] else {
                throw HarnessProblem(path, "missing connection or operation")
            }
            guard !model.label.isEmpty, !model.upstreamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  model.upstreamID.utf8.count <= 512 else { throw HarnessProblem(path, "missing label or upstream model ID") }
            try Self.unique(model.capabilities, path: path + ".capabilities")
            let maximum: Set<HarnessCapability>
            switch operation.adapter {
            case .chat, .responses, .messages: maximum = [.text, .stream, .jsonSchema, .sources, .webSearch]
            case .systemOne, .decisions: maximum = [.noul, .choice, .probabilities]
            case .apple: maximum = [.text, .stream, .jsonSchema]
            case .chatGPT: maximum = [.text, .stream, .sources, .webSearch]
            case .router: maximum = [.text, .stream, .topicSession]
            }
            guard Set(model.capabilities).isSubset(of: maximum) else {
                throw HarnessProblem(path + ".capabilities", "not supported by the adapter contract")
            }
            let decisionAdapter = operation.adapter == .systemOne || operation.adapter == .decisions
            guard (model.kind == .decision) == decisionAdapter,
                  model.kind != .generation || model.capabilities.contains(.text) else {
                throw HarnessProblem(path + ".kind", "incompatible with adapter or capabilities")
            }
            if model.execution == .onDevice && connection.endpoint.kind != .inProcess {
                throw HarnessProblem(path + ".execution", "a local socket or CLI is not an on-device model")
            }
            if connection.endpoint.kind == .inProcess && model.execution != .onDevice {
                throw HarnessProblem(path + ".execution", "in-process model must be on-device")
            }
            if operation.adapter == .chatGPT && model.execution != .providerCloud {
                throw HarnessProblem(path + ".execution", "managed account uses provider infrastructure")
            }
        }
        for (id, prompt) in prompts {
            try Self.unique(prompt.inputs, path: "prompts.\(id).inputs")
            for input in prompt.inputs { try Self.identifier(input, path: "prompts.\(id).inputs") }
        }
        for (id, role) in roles.sorted(by: { $0.key < $1.key }) {
            let path = "roles.\(id)"
            guard !role.label.isEmpty, (1...300_000).contains(role.timeoutMilliseconds),
                  role.maxOutputTokens.map({ (1...128_000).contains($0) }) ?? true else {
                throw HarnessProblem(path, "missing label or invalid deadline/token limit")
            }
            guard !role.prompts.isEmpty, role.prompts.allSatisfy({ prompts[$0] != nil }) else {
                throw HarnessProblem(path + ".prompts", "missing prompt reference")
            }
            try Self.unique(role.prompts, path: path + ".prompts")
            try Self.unique(role.context, path: path + ".context")
            try Self.unique(role.requires, path: path + ".requires")
            try Self.unique([role.model] + role.fallbacks, path: path + ".fallbacks")
            guard role.fallbacks.count <= 4 else { throw HarnessProblem(path + ".fallbacks", "too many fallbacks") }
            for modelID in [role.model] + role.fallbacks {
                guard let model = models[modelID], model.kind == role.kind,
                      Set(role.requires).isSubset(of: model.capabilities) else {
                    throw HarnessProblem(path + ".model", "missing model or incompatible kind/capabilities")
                }
                if role.kind == .decision {
                    guard let policy = role.decisionPolicy else {
                        throw HarnessProblem(path + ".decisionPolicy", "decision semantics must be explicit")
                    }
                    let needed: HarnessCapability = policy == .providerProbabilities ? .probabilities : .judgement
                    guard model.capabilities.contains(needed) else {
                        throw HarnessProblem(path + ".decisionPolicy", "model cannot provide the selected semantics")
                    }
                } else if role.decisionPolicy != nil {
                    throw HarnessProblem(path + ".decisionPolicy", "generation is not a typed decision")
                }
            }
        }
        for id in flows.keys.sorted() { _ = try HarnessFlowCompiler.compile(id, in: self) }
        for (id, profile) in profiles.sorted(by: { $0.key < $1.key }) {
            let path = "profiles.\(id)"
            try Self.unique(profile.allowedExecution, path: path + ".allowedExecution")
            guard !profile.allowedExecution.isEmpty, !profile.label.isEmpty else {
                throw HarnessProblem(path, "missing label or execution policy")
            }
            if let limits = profile.limits {
                guard (1...8).contains(limits.concurrentCalls), (1...10_000).contains(limits.callsPerSession),
                      (0...4).contains(limits.fallbacksPerRequest) else {
                    throw HarnessProblem(path + ".limits", "invalid call limits")
                }
            }
            for flowID in [profile.evidenceFlow, profile.actionFlow, profile.endFlow].compactMap({ $0 }) {
                guard let flow = flows[flowID] else { throw HarnessProblem(path, "missing flow") }
                let legacy = flow.nodes.values.contains { $0.kind == .currentListen }
                guard legacy || profile.limits != nil else { throw HarnessProblem(path + ".limits", "required for configurable flows") }
                for node in flow.nodes.values {
                    guard let roleID = node.role, let role = roles[roleID] else { continue }
                    guard role.fallbacks.count <= (profile.limits?.fallbacksPerRequest ?? 0) else {
                        throw HarnessProblem(path, "role exceeds profile fallback limit")
                    }
                    for modelID in [role.model] + role.fallbacks {
                        guard let model = models[modelID], profile.allowedExecution.contains(model.execution) else {
                            throw HarnessProblem(path, "model execution is excluded by profile policy")
                        }
                    }
                }
            }
        }
    }

    static func identifier(_ value: String, path: String) throws {
        guard value.range(of: #"\A[A-Za-z][A-Za-z0-9._-]{0,95}\z"#, options: .regularExpression) != nil else {
            throw HarnessProblem(path, "invalid identifier; use a separate display label")
        }
    }

    static func unique<T: Hashable>(_ values: [T], path: String) throws {
        guard Set(values).count == values.count else { throw HarnessProblem(path, "duplicate entries") }
    }
}

extension HarnessConnection {
    func validate(path: String) throws {
        guard !label.isEmpty, !vendor.isEmpty, !operations.isEmpty, operations.count <= 16 else {
            throw HarnessProblem(path, "missing label, vendor or operations")
        }
        if let slot = authentication.slot { try HarnessConfiguration.identifier(slot, path: path + ".authentication.slot") }
        guard (authentication.kind == .none) == (authentication.slot == nil) else {
            throw HarnessProblem(path + ".authentication", "only local slot references are accepted")
        }
        switch endpoint.kind {
        case .http:
            guard let text = endpoint.baseURL, let url = URLComponents(string: text),
                  let host = url.host, !host.isEmpty, url.url != nil, ["https", "http"].contains(url.scheme),
                  url.port.map({ (1...65535).contains($0) }) ?? true,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  endpoint.runtime == nil, endpoint.bindingSlot == nil,
                  authentication.kind == .none || authentication.kind == .apiKey else {
                throw HarnessProblem(path + ".endpoint", "invalid HTTP endpoint or authentication; no URL credentials/query/fragment")
            }
            let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
            guard url.scheme == "https" || loopback else { throw HarnessProblem(path + ".endpoint", "non-loopback HTTP requires TLS") }
            try Self.safePath(url.percentEncodedPath, path: path + ".endpoint")
        case .inProcess:
            guard endpoint.runtime == "apple.foundation", endpoint.baseURL == nil, endpoint.bindingSlot == nil,
                  authentication.kind == .none else { throw HarnessProblem(path + ".endpoint", "unsupported native runtime binding") }
        case .managedAccount:
            guard endpoint.runtime == "chatgpt.plan", endpoint.baseURL == nil, endpoint.bindingSlot == nil,
                  authentication.kind == .managedAccount else { throw HarnessProblem(path + ".endpoint", "managed service uses its official account binding") }
        case .pairedRouter:
            guard let slot = endpoint.bindingSlot, endpoint.baseURL == nil, endpoint.runtime == nil,
                  authentication.kind == .routerPairing, authentication.slot == slot else {
                throw HarnessProblem(path + ".endpoint", "router requires its local pairing binding")
            }
            try HarnessConfiguration.identifier(slot, path: path + ".endpoint.bindingSlot")
        }
        for (id, operation) in operations {
            try HarnessConfiguration.identifier(id, path: path + ".operations")
            let expected: Endpoint.Kind
            switch operation.adapter {
            case .apple: expected = .inProcess
            case .chatGPT: expected = .managedAccount
            case .router: expected = .pairedRouter
            default: expected = .http
            }
            guard endpoint.kind == expected else { throw HarnessProblem(path + ".operations.\(id)", "adapter does not match endpoint kind") }
            if expected == .http {
                guard let relative = operation.path, !relative.isEmpty, !relative.hasPrefix("/") else {
                    throw HarnessProblem(path + ".operations.\(id).path", "relative API path required")
                }
                try Self.safePath(relative, path: path + ".operations.\(id).path")
            } else if operation.path != nil { throw HarnessProblem(path + ".operations.\(id).path", "native adapters do not take HTTP paths") }
        }
    }

    private static func safePath(_ value: String, path: String) throws {
        guard value.range(of: #"\A[A-Za-z0-9_./-]*\z"#, options: .regularExpression) != nil,
              !value.contains("//"), !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw HarnessProblem(path, "unsafe endpoint path")
        }
    }
}

/// Structural compilation only: no tasks, discovery, account reads or model requests.
enum HarnessFlowCompiler {
    enum Port: Hashable, Sendable { case context, text, decision, boolean, candidates, publication }

    static func compile(_ id: String, in config: HarnessConfiguration) throws -> [String] {
        let path = "flows.\(id)"
        guard let flow = config.flows[id], !flow.nodes.isEmpty, flow.nodes.count <= 64 else {
            throw HarnessProblem(path, "flow needs between 1 and 64 nodes")
        }
        for key in flow.nodes.keys { try HarnessConfiguration.identifier(key, path: path + ".nodes") }
        if flow.nodes.values.contains(where: { $0.kind == .currentListen }) {
            guard config.compatibility != nil, flow.nodes.count == 1, let node = flow.nodes.values.first,
                  node.role == nil, node.inputs.isEmpty, node.after.isEmpty, node.context.isEmpty,
                  node.condition == nil, node.join == nil else {
                throw HarnessProblem(path, "legacy facade cannot be mixed with new flow execution")
            }
            return Array(flow.nodes.keys)
        }
        var ports: [String: Port] = [:]
        for (nodeID, node) in flow.nodes {
            try HarnessConfiguration.identifier(nodeID, path: path + ".nodes")
            switch node.kind {
            case .context: ports[nodeID] = .context
            case .invoke:
                guard let role = node.role.flatMap({ config.roles[$0] }) else {
                    throw HarnessProblem(path + ".nodes.\(nodeID).role", "missing role")
                }
                ports[nodeID] = role.kind == .generation ? .text : .decision
            case .branch: ports[nodeID] = .boolean
            case .join: ports[nodeID] = .candidates
            case .publish: ports[nodeID] = .publication
            case .currentListen: break
            }
        }
        // One native publisher owns a flow's updates. Multiple writers feed that owner.
        guard flow.nodes.values.filter({ $0.kind == .publish }).count <= 1 else {
            throw HarnessProblem(path, "multiple publication owners")
        }
        var dependencies: [String: Set<String>] = [:]
        for (nodeID, node) in flow.nodes.sorted(by: { $0.key < $1.key }) {
            let here = path + ".nodes.\(nodeID)"
            try HarnessConfiguration.unique(node.after, path: here + ".after")
            try HarnessConfiguration.unique(node.context, path: here + ".context")
            if node.kind != .invoke && node.role != nil { throw HarnessProblem(here + ".role", "only invocation nodes select a role") }
            if node.kind != .context && !node.context.isEmpty { throw HarnessProblem(here + ".context", "only context nodes select snapshot fields") }
            if (node.kind == .join) != (node.join != nil) { throw HarnessProblem(here + ".join", "join policy required only for joins") }
            var required: [String: Set<Port>] = [:]
            var optional: [String: Set<Port>] = [:]
            switch node.kind {
            case .context: break
            case .invoke:
                required = ["context": [.context]]
                if ports[nodeID] == .decision { optional = ["candidate": [.text]] }
            case .branch:
                guard node.condition != nil else { throw HarnessProblem(here + ".condition", "branch requires a typed condition") }
            case .join:
                guard !node.inputs.isEmpty else { throw HarnessProblem(here + ".inputs", "join has no candidates") }
                for name in node.inputs.keys { required[name] = [.text] }
            case .publish:
                required = ["candidate": [.text, .candidates]]
                optional = ["approval": [.decision]]
            case .currentListen: break
            }
            for name in required.keys where node.inputs[name] == nil { throw HarnessProblem(here + ".inputs.\(name)", "required input missing") }
            for (name, source) in node.inputs {
                guard let allowed = required[name] ?? optional[name], let port = ports[source], allowed.contains(port) else {
                    throw HarnessProblem(here + ".inputs.\(name)", "missing source, unsupported input or incompatible port")
                }
                if name == "approval", let roleID = flow.nodes[source]?.role,
                   config.roles[roleID]?.onUnavailable != .discardCandidate {
                    throw HarnessProblem(here + ".inputs.approval", "unavailable review must discard its candidate")
                }
            }
            var edges = Set(node.after + Array(node.inputs.values))
            if let condition = node.condition {
                guard ports[condition.node] == .decision,
                      condition.field.range(of: #"\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*\z"#, options: .regularExpression) != nil else {
                    throw HarnessProblem(here + ".condition", "condition must inspect a typed decision field")
                }
                switch condition.value {
                case .bool, .string:
                    guard condition.comparison == .equal else { throw HarnessProblem(here + ".condition", "ordered comparison requires a number") }
                case .integer, .unsigned, .number: break
                default: throw HarnessProblem(here + ".condition", "comparison value must be scalar")
                }
                edges.insert(condition.node)
            }
            guard edges.allSatisfy({ flow.nodes[$0] != nil }) else { throw HarnessProblem(here + ".after", "missing dependency") }
            dependencies[nodeID] = edges
        }
        var order: [String] = []
        while !dependencies.isEmpty {
            let ready = dependencies.keys.filter { dependencies[$0]!.isEmpty }.sorted()
            guard !ready.isEmpty else { throw HarnessProblem(path, "cycle in dependencies or conditions") }
            order += ready
            for node in ready { dependencies.removeValue(forKey: node) }
            for node in Array(dependencies.keys) { dependencies[node]?.subtract(ready) }
        }
        return order
    }
}

/// Immutable per-conversation value. Binding/capability observations are local inputs,
/// not claims imported from JSON. This foundation does not execute the compiled graph.
struct HarnessResolvedPlan: Equatable, Sendable {
    enum Availability: String, Sendable { case disabled, unbound, untested, incompatible, ready }
    let configuration: HarnessConfiguration
    let hash: String
    let profile: HarnessProfile
    let nodeOrder: [String: [String]]
    let availability: [String: Availability]

    init(configuration: HarnessConfiguration, boundConnections: [String: String] = [:],
         testedCapabilities: [String: HarnessCapabilityObservation] = [:]) throws {
        try configuration.validate()
        self.configuration = configuration
        hash = HarnessJSON.hash(try HarnessJSON.encode(configuration))
        profile = configuration.profiles[configuration.activeProfile]!
        var orders: [String: [String]] = [:]
        var states: [String: Availability] = [:]
        for flow in [profile.evidenceFlow, profile.actionFlow, profile.endFlow].compactMap({ $0 }) {
            orders[flow] = try HarnessFlowCompiler.compile(flow, in: configuration)
            for node in configuration.flows[flow]!.nodes.values {
                guard let roleID = node.role, let role = configuration.roles[roleID] else { continue }
                for id in [role.model] + role.fallbacks {
                    let model = configuration.models[id]!, connection = configuration.connections[model.connection]!
                    if !connection.enabled { states[id] = .disabled }
                    else if boundConnections[model.connection] != (try connection.bindingFingerprint()) { states[id] = .unbound }
                    else if let tested = testedCapabilities[id], tested.fingerprint == (try model.capabilityFingerprint(in: configuration)) {
                        let required = Set(role.requires + (role.kind == .generation ? [.text] : []))
                            .union(role.decisionPolicy == .providerProbabilities ? [.probabilities] : [])
                            .union(role.decisionPolicy == .categoricalJudgement ? [.judgement] : [])
                        let state: Availability = required.isSubset(of: tested.capabilities) ? .ready : .incompatible
                        // Shared models must meet every active role, not just the last one visited.
                        states[id] = states[id] == .incompatible ? .incompatible : state
                    } else { states[id] = .untested }
                }
            }
        }
        nodeOrder = orders
        availability = states
    }
}

/// A local observation cannot be carried to a different model merely by reusing its ID.
struct HarnessCapabilityObservation: Equatable, Sendable {
    let fingerprint: String
    let capabilities: Set<HarnessCapability>
}

extension HarnessModel {
    func capabilityFingerprint(in config: HarnessConfiguration) throws -> String {
        guard let connection = config.connections[connection] else { throw HarnessProblem("models", "missing connection") }
        struct Target: Encodable {
            let binding: String
            let operation: String
            let upstreamID: String
            let kind: HarnessModelKind
        }
        return HarnessJSON.hash(try HarnessJSON.encode(Target(binding: connection.bindingFingerprint(),
            operation: operation, upstreamID: upstreamID, kind: kind)))
    }
}

extension HarnessConnection {
    /// Local grants bind the destination, authentication slot and adapter contract,
    /// not just an editable connection ID. Labels and enabled state are not authority.
    func bindingFingerprint() throws -> String {
        struct Binding: Encodable {
            let endpoint: Endpoint
            let authentication: Authentication
            let operations: [String: Operation]
        }
        return HarnessJSON.hash(try HarnessJSON.encode(Binding(endpoint: endpoint,
            authentication: authentication, operations: operations)))
    }
}
