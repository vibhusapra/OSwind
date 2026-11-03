import Combine
import Foundation
import OSwindCore

enum LocalModelLibraryRole: String, CaseIterable, Identifiable {
    case answer, search
    var id: Self { self }
    var label: String { self == .answer ? "Answer server" : "Search server" }
}

struct LocalModelLibraryOperations: Sendable {
    var models: @Sendable (String) async throws -> [InstalledModel]
    var runtime: @Sendable (String) async throws -> String
    var pull: @Sendable (String, String, @escaping @Sendable (ModelPullProgress) -> Void) async throws -> Void
    var start: @MainActor @Sendable (String) async throws -> String
    var prepare: @Sendable (String, String) async throws -> LocalModelPreparation = { _, _ in
        throw OSwindError.unavailable("Model loading is unavailable")
    }

    static var live: Self {
        Self(models: { try await OllamaClient.shared.models(endpoint: $0) },
             runtime: { try await OllamaClient.shared.runtime(endpoint: $0) },
             pull: { try await OllamaClient.shared.pull($0, endpoint: $1, progress: $2) },
             start: { try await LocalModelServer.shared.start(endpoint: $0) },
             prepare: { try await OllamaClient.shared.prepare($0, endpoint: $1) })
    }
}

/// Endpoint snapshots never stand in for another server. Network work has no
/// access to captured evidence, settings persistence or the library store.
@MainActor final class LocalModelLibraryModel: ObservableObject {
    struct Listing {
        var models: [InstalledModel] = []
        var runtime = ""
        var runtimeWarning: String?
        var status = "Check this local server to discover installed models"
        var checking = false
    }
    struct Download {
        let id: UUID
        let model: String
        let endpoint: String
        var progress: ModelPullProgress?
        var cancelling = false
    }
    struct PreparationWork {
        let id: UUID
        let model: String
        let endpoint: String
        var cancelling = false
    }

    @Published private(set) var role: LocalModelLibraryRole = .answer
    @Published private(set) var endpoints: [LocalModelLibraryRole: String] = [:]
    @Published private(set) var listings: [String: Listing] = [:]
    @Published private(set) var download: Download?
    @Published private(set) var downloadOutcome: String?
    @Published private(set) var startingEndpoint: String?
    @Published private(set) var startOutcome: String?
    @Published private(set) var pendingInspections = 0
    @Published private(set) var answerModel: String?
    @Published private(set) var preparing: PreparationWork?
    @Published private(set) var prepared: LocalModelPreparation?
    @Published private(set) var preparationStatus: String?
    var allowed: () -> Bool = { true }
    private let operations: LocalModelLibraryOperations
    private var configuration = UUID()
    private var inspections: [UUID: Task<Void, Never>] = [:]
    private var latestInspection: [String: UUID] = [:]
    private var pullTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var prepareOwner: UUID?
    private var prepareCancelled = false
    private var preparationGeneration = UUID()
    private var retired = false
    private var drainers = 0

    init(operations: LocalModelLibraryOperations = .live) { self.operations = operations }
    var endpoint: String { endpoints[role] ?? "" }
    var listing: Listing { listings[endpoint] ?? Listing() }
    var busy: Bool { !inspections.isEmpty || pullTask != nil || startTask != nil || prepareOwner != nil }
    var canWork: Bool { !retired && drainers == 0 && allowed() }
    var availableRoles: [LocalModelLibraryRole] { LocalModelLibraryRole.allCases.filter { endpoints[$0] != nil } }
    var canPrepareAnswer: Bool {
        canWork && endpoints[.answer] != nil && answerModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && prepareOwner == nil && pullTask == nil && startTask == nil
    }
    func models(for role: LocalModelLibraryRole) -> [InstalledModel] {
        guard let endpoint = endpoints[role] else { return [] }
        return listings[endpoint]?.models ?? []
    }

    func configure(answer: String?, search: String, answerModel: String? = nil) {
        guard !retired else { return }
        if answer != endpoints[.answer] || answerModel != self.answerModel {
            preparationGeneration = UUID(); cancelPreparation()
            prepared = nil; preparationStatus = nil
            self.answerModel = answerModel
        }
        var next: [LocalModelLibraryRole: String] = [.search: search]
        if let answer { next[.answer] = answer }
        guard next != endpoints else { return }
        configuration = UUID()
        for task in inspections.values { task.cancel() }
        latestInspection.removeAll()
        listings = listings.filter { next.values.contains($0.key) }.mapValues { value in
            var value = value; value.checking = false; return value
        }
        endpoints = next
        if next[role] == nil { role = .search }
    }

    func select(_ role: LocalModelLibraryRole) {
        guard endpoints[role] != nil, !retired else { return }
        self.role = role
    }
    func inspect(_ role: LocalModelLibraryRole? = nil) {
        if let role { guard endpoints[role] != nil else { return }; select(role) }
        inspectEndpoint(endpoint)
    }
    private func validate(_ endpoint: String) throws {
        _ = try OllamaClient.localURL(endpoint, path: "api/tags")
    }
    private func update(_ endpoint: String, _ change: (inout Listing) -> Void) {
        var value = listings[endpoint] ?? Listing(); change(&value); listings[endpoint] = value
    }
    private func ownsInspection(_ id: UUID, endpoint: String, configuration: UUID) -> Bool {
        canWork && self.configuration == configuration && latestInspection[endpoint] == id && endpoints.values.contains(endpoint)
    }
    private func inspectEndpoint(_ endpoint: String) {
        guard canWork, endpoints.values.contains(endpoint) else { return }
        do { try validate(endpoint) }
        catch { update(endpoint) { $0 = Listing(); $0.status = error.localizedDescription }; return }
        if let old = latestInspection[endpoint] { inspections[old]?.cancel() }
        let id = UUID(), configuration = configuration, operations = operations
        latestInspection[endpoint] = id
        update(endpoint) { $0.checking = true; $0.status = "Checking local server…"; $0.runtimeWarning = nil }
        inspections[id] = Task { [weak self] in
            defer { self?.inspections.removeValue(forKey: id); self?.pendingInspections = self?.inspections.count ?? 0 }
            do {
                let models = try await operations.models(endpoint)
                guard !Task.isCancelled, self?.ownsInspection(id, endpoint: endpoint, configuration: configuration) == true else { return }
                self?.update(endpoint) { $0.models = models; $0.runtime = ""; $0.status = models.isEmpty ? "Server ready; download a model below" : "\(models.count) local models available" }
                do {
                    let runtime = try await operations.runtime(endpoint)
                    guard !Task.isCancelled, self?.ownsInspection(id, endpoint: endpoint, configuration: configuration) == true else { return }
                    self?.update(endpoint) { $0.runtime = runtime }
                } catch {
                    guard !Task.isCancelled, self?.ownsInspection(id, endpoint: endpoint, configuration: configuration) == true else { return }
                    self?.update(endpoint) { $0.runtimeWarning = "Runtime details unavailable: " + error.localizedDescription }
                }
                self?.update(endpoint) { $0.checking = false }
            } catch {
                guard !Task.isCancelled, self?.ownsInspection(id, endpoint: endpoint, configuration: configuration) == true else { return }
                self?.update(endpoint) { $0 = Listing(); $0.status = "Local server unavailable: " + error.localizedDescription }
            }
        }
        pendingInspections = inspections.count
    }

    func startServer() {
        guard canWork, startTask == nil, prepareOwner == nil else { return }
        let endpoint = endpoint, operation = operations.start
        do { try validate(endpoint) }
        catch { update(endpoint) { $0.status = error.localizedDescription }; return }
        startingEndpoint = endpoint
        startOutcome = nil
        startTask = Task { [weak self] in
            defer { self?.startTask = nil; self?.startingEndpoint = nil }
            do {
                let message = try await operation(endpoint)
                guard !Task.isCancelled, self?.canWork == true, self?.endpoints.values.contains(endpoint) == true else { return }
                self?.startOutcome = "\(endpoint): \(message)"
                self?.inspectEndpoint(endpoint)
            } catch {
                guard !Task.isCancelled, self?.canWork == true, self?.endpoints.values.contains(endpoint) == true else { return }
                self?.startOutcome = "\(endpoint): " + error.localizedDescription
            }
        }
    }

    func pull(_ model: String) {
        guard canWork, pullTask == nil, prepareOwner == nil else { return }
        let endpoint = endpoint, operation = operations.pull
        do {
            try validate(endpoint)
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OSwindError.invalid("Choose a model to download") }
            guard !model.lowercased().hasSuffix(":cloud"), !model.lowercased().hasSuffix("-cloud") else { throw OSwindError.invalid("Choose a local model; cloud model aliases are not supported in local mode") }
        } catch { downloadOutcome = error.localizedDescription; return }
        let id = UUID()
        downloadOutcome = nil
        download = Download(id: id, model: model, endpoint: endpoint)
        pullTask = Task { [weak self] in
            var outcome: String
            do {
                try await operation(model, endpoint) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.canWork, self.download?.id == id, self.download?.cancelling == false else { return }
                        self.download?.progress = progress
                    }
                }
                outcome = Task.isCancelled ? "Download request cancelled; cached layers can be resumed" : "Downloaded \(model). Choose it in the appropriate model picker; its first answer may need startup."
            } catch {
                outcome = Task.isCancelled || error is CancellationError ? "Download request cancelled; cached layers can be resumed" : error.localizedDescription
            }
            guard let self, self.download?.id == id else { return }
            self.pullTask = nil; self.download = nil
            if !self.retired { self.downloadOutcome = "\(endpoint): \(outcome)" }
            if !Task.isCancelled, self.canWork, self.endpoints.values.contains(endpoint) { self.inspectEndpoint(endpoint) }
        }
    }
    func cancelDownload() {
        guard pullTask != nil else { return }
        download?.cancelling = true
        pullTask?.cancel()
    }
    func prepareAnswer() {
        guard canPrepareAnswer, let endpoint = endpoints[.answer], let model = answerModel else { return }
        do { try validate(endpoint) }
        catch { preparationStatus = error.localizedDescription; return }
        let id = UUID(), generation = preparationGeneration, operation = operations.prepare
        prepareOwner = id; prepareCancelled = false
        prepared = nil; preparationStatus = nil
        preparing = PreparationWork(id: id, model: model, endpoint: endpoint)
        prepareTask = Task { [weak self] in
            let result: Result<LocalModelPreparation, Error>
            do { result = .success(try await operation(model, endpoint)) }
            catch { result = .failure(error) }
            self?.finishPreparation(id, generation: generation, model: model, endpoint: endpoint, result: result, cancelled: Task.isCancelled)
        }
        if prepareCancelled || !canWork { prepareTask?.cancel() }
    }
    private func finishPreparation(_ id: UUID, generation: UUID, model: String, endpoint: String, result: Result<LocalModelPreparation, Error>, cancelled: Bool) {
        guard prepareOwner == id else { return }
        preparing = nil
        if canWork, preparationGeneration == generation, endpoints[.answer] == endpoint, answerModel == model {
            if cancelled || prepareCancelled {
                preparationStatus = "Model load request cancelled"
            } else {
                switch result {
                case .success(let value):
                    let untagged = !(model.split(separator: "/").last?.contains(":") ?? true)
                    guard value.endpoint == endpoint, value.requestedModel == model,
                          value.model == model || (untagged && value.model == model + ":latest"),
                          value.observationExpiresAt > Date(), value.observedAt <= Date().addingTimeInterval(1), value.residentBytes > 0,
                          value.contextLength == AIConfiguration.localContextWindow else {
                        preparationStatus = "The server load observation did not match the selected model"
                        prepareTask = nil; prepareOwner = nil; objectWillChange.send(); return
                    }
                    prepared = value
                    preparationStatus = "Selected model load confirmed by the server"
                case .failure(let error):
                    preparationStatus = error is CancellationError ? "Model load request cancelled" : error.localizedDescription
                }
            }
        }
        prepareTask = nil; prepareOwner = nil; objectWillChange.send()
    }
    func cancelPreparation() {
        guard prepareOwner != nil else { return }
        prepareCancelled = true; preparing?.cancelling = true; prepareTask?.cancel()
    }
    func cancelAll() {
        latestInspection.removeAll()
        for task in inspections.values { task.cancel() }
        listings = listings.mapValues { value in var value = value; value.checking = false; return value }
        cancelDownload(); startTask?.cancel(); cancelPreparation()
    }
    func retire() {
        retired = true; cancelAll(); listings.removeAll(); downloadOutcome = nil; startOutcome = nil; prepared = nil; preparationStatus = nil
    }
    func cancelAndWait() async {
        drainers += 1
        defer { drainers -= 1 }
        cancelAll()
        let tasks = Array(inspections.values), pull = pullTask, start = startTask, prepare = prepareTask
        for task in tasks { await task.value }
        await pull?.value; await start?.value; await prepare?.value
    }
}
