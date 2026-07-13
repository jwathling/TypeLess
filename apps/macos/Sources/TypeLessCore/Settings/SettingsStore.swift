import Foundation

/// Die wenigen Einstellungen, die M3 braucht. Ein Settings-Fenster kommt erst in M7.
public protocol SettingsStore: Sendable {
    var engineDirectory: String { get set }
    var socketPath: String { get set }
    var uvPath: String { get set }
}

public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var engineDirectory: String {
        get { defaults.string(forKey: "engineDirectory") ?? Self.defaultEngineDirectory }
        set { defaults.set(newValue, forKey: "engineDirectory") }
    }

    public var socketPath: String {
        get { defaults.string(forKey: "socketPath") ?? Self.defaultSocketPath }
        set { defaults.set(newValue, forKey: "socketPath") }
    }

    public var uvPath: String {
        get { defaults.string(forKey: "uvPath") ?? Self.defaultUvPath }
        set { defaults.set(newValue, forKey: "uvPath") }
    }

    // MARK: - Defaults

    /// Muss zum Default in ``engine/typeless_engine/config.py`` passen (dort:
    /// `Path.home() / "Library" / "Application Support" / "TypeLess" / "typeless.sock"`).
    static var defaultSocketPath: String {
        NSHomeDirectory() + "/Library/Application Support/TypeLess/typeless.sock"
    }

    /// Im Dev-Betrieb das Repo. Wird in M8 durch einen gebündelten Sidecar ersetzt.
    static var defaultEngineDirectory: String {
        NSHomeDirectory() + "/Projekte/TypeLess/engine"
    }

    /// uv liegt nach der Standardinstallation hier. Der PATH einer .app-Umgebung enthält
    /// ~/.local/bin nicht — deshalb der absolute Pfad.
    static var defaultUvPath: String {
        NSHomeDirectory() + "/.local/bin/uv"
    }
}

/// Für Tests und Previews.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    public var engineDirectory: String
    public var socketPath: String
    public var uvPath: String

    public init(engineDirectory: String, socketPath: String, uvPath: String) {
        self.engineDirectory = engineDirectory
        self.socketPath = socketPath
        self.uvPath = uvPath
    }
}
