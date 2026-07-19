import Foundation

/// Die vier Werte, mit denen der ``SidecarLifecycle`` den Engine-Prozess startet. Bewusst ein
/// reiner Wert-Typ ohne Verhalten — *welche* Werte gelten (gebündelt vs. Entwicklung), entscheidet
/// ``resolve(bundledEngineDirectory:uvPath:engineDirectory:socketPath:appSupportDirectory:)``,
/// damit die Auswahl ohne echtes App-Bundle testbar bleibt.
public struct EngineLaunch: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environment: [String: String]

    public init(executable: String, arguments: [String], workingDirectory: String,
                environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// Wählt den Startbefehl. Ist ``bundledEngineDirectory`` gesetzt (die App läuft aus einem
    /// Bündel mit eingebetteter Engine), wird die Python-Umgebung mit dem mitgelieferten `uv`
    /// **extern** unter Application Support aufgebaut — das schreibgeschützte, signierte Bündel
    /// bleibt unangetastet. Sonst gilt der Entwicklungs-Start (wie bisher: `uv run` gegen das Repo).
    public static func resolve(bundledEngineDirectory: String?, uvPath: String,
                               engineDirectory: String, socketPath: String,
                               appSupportDirectory: String) -> EngineLaunch {
        guard let bundle = bundledEngineDirectory else {
            return EngineLaunch(
                executable: uvPath,
                arguments: ["run", "python", "-m", "typeless_engine.server"],
                workingDirectory: engineDirectory,
                environment: ["TYPELESS_SOCKET_PATH": socketPath])
        }
        return EngineLaunch(
            executable: bundle + "/uv",
            arguments: [
                "run", "--frozen", "--project", bundle,
                "--extra", "mlx", "--extra", "server",
                "python", "-m", "typeless_engine.server",
            ],
            workingDirectory: appSupportDirectory,
            environment: [
                "TYPELESS_SOCKET_PATH": socketPath,
                "UV_PROJECT_ENVIRONMENT": appSupportDirectory + "/runtime",
                "UV_CACHE_DIR": appSupportDirectory + "/uv-cache",
                "HF_HOME": appSupportDirectory + "/models",
                // Bytecode-Cache (__pycache__/*.pyc) beim Modul-Import extern ablegen — sonst
                // schreibt Python sie ins signierte, schreibgeschützte Bündel und bricht dessen
                // Code-Signatur (nicht PYTHONDONTWRITEBYTECODE, das schaltete den Cache ganz ab).
                "PYTHONPYCACHEPREFIX": appSupportDirectory + "/pycache",
            ])
    }
}
