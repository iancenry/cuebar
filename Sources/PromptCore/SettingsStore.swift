import Foundation

/// Persistence for `CueSettings`. Separate from the model because this is a
/// different job: one reads the settings, this one owns when they hit disk.
@MainActor
@Observable
public final class SettingsStore {
    public var settings: CueSettings {
        didSet { scheduleSave() }
    }
    private let defaultsKey = "Cuebar.settings.v5"
    private var saveTask: Task<Void, Never>?

    public init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(CueSettings.self, from: data) {
            settings = decoded
        } else {
            settings = CueSettings()
        }
    }

    public init(inMemory settings: CueSettings) {
        self.settings = settings
    }

    public func reset() { settings = CueSettings() }

    /// Coalesced persistence. Sliders write settings at drag rate (60+
    /// mutations a second); encoding the whole struct and hitting
    /// UserDefaults for each one is pure churn, so writes collapse into
    /// the latest state a beat after the last change.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        saveTask = nil
        try? UserDefaults.standard.set(JSONEncoder().encode(settings), forKey: defaultsKey)
    }
}
