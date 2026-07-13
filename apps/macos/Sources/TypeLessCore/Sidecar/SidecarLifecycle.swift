import Foundation

/// Wer den Sidecar besitzt.
public enum SidecarOwnership: Sendable, Equatable {
    /// Es lief bereits einer — wir haben ihn übernommen und fassen ihn nicht an.
    case adopted
    /// Wir haben ihn gestartet und beenden ihn auch wieder.
    case spawned
}

public enum LifecycleError: Error, Equatable, Sendable {
    case engineDirectoryMissing(String)
    case uvMissing(String)
    case readyTimeout
    /// Der Sidecar ist hochgekommen, meldet aber ``failed`` (z. B. STT-Modell kaputt).
    case failed(String)
}

/// Ein gestarteter Kindprozess.
public protocol ProcessHandle: Sendable {
    var isRunning: Bool { get }
    func terminate()
}

/// Startet Prozesse. Als Protokoll, damit Tests keinen echten Prozess starten müssen.
public protocol ProcessRunner: Sendable {
    func run(executable: String, arguments: [String], workingDirectory: String) throws -> ProcessHandle
}

/// Bringt den Sidecar hoch.
public protocol SidecarLifecycle: Sendable {
    func start() async throws -> SidecarOwnership
    func stop() async
}

public actor DefaultSidecarLifecycle: SidecarLifecycle {
    private let client: SidecarClient
    private let runner: ProcessRunner
    private let engineDirectory: String
    private let uvPath: String
    private let readyTimeout: Duration
    private let pollInterval: Duration

    /// Nur gesetzt, wenn **wir** den Prozess gestartet haben.
    private var ownProcess: ProcessHandle?

    public init(client: SidecarClient, runner: ProcessRunner, engineDirectory: String,
                uvPath: String, readyTimeout: Duration = .seconds(90),
                pollInterval: Duration = .seconds(1)) {
        self.client = client
        self.runner = runner
        self.engineDirectory = engineDirectory
        self.uvPath = uvPath
        self.readyTimeout = readyTimeout
        self.pollInterval = pollInterval
    }

    public func start() async throws -> SidecarOwnership {
        // 1. Lauscht schon jemand? Dann übernehmen — spart beim Entwickeln das Warm-up.
        if let existing = try? await client.health() {
            if existing.status == "failed" {
                throw LifecycleError.failed(existing.error ?? "unbekannter Fehler")
            }
            if existing.status == "ready" {
                return .adopted
            }
            // "starting": Eine fremde Instanz fährt gerade hoch — abwarten, nicht dazwischenfunken.
            try await waitForReady()
            return .adopted
        }

        // 2. Niemand da: selbst starten.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: engineDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LifecycleError.engineDirectoryMissing(engineDirectory)
        }
        guard FileManager.default.isExecutableFile(atPath: uvPath) else {
            throw LifecycleError.uvMissing(uvPath)
        }

        ownProcess = try runner.run(
            executable: uvPath,
            arguments: ["run", "python", "-m", "typeless_engine.server"],
            workingDirectory: engineDirectory)

        do {
            try await waitForReady()
        } catch {
            // Nur hier, im Spawn-Zweig: Was wir selbst gestartet haben, beenden wir auch selbst
            // wieder — egal ob Timeout, `failed`-Meldung oder Abbruch (`CancellationError`).
            // Sonst bleibt ein MLX-Prozess als Zombie im Speicher stehen (Finding 1, Review
            // Task 4). Im Adopt-Zweig (oben) ist `ownProcess` nie gesetzt, dort passiert also
            // strukturell nichts — die eiserne Regel bleibt unangetastet.
            ownProcess?.terminate()
            ownProcess = nil
            throw error
        }
        return .spawned
    }

    /// Beendet **nur**, was wir selbst gestartet haben.
    public func stop() async {
        ownProcess?.terminate()
        ownProcess = nil
    }

    /// Pollt ``/health``, bis ``ready`` gemeldet wird. Ohne feste Wartezeit: Der Timeout ist
    /// die Reißleine, nicht die Taktung.
    ///
    /// Finding 2 (Review, Task 4): `try?` verschluckte früher *jeden* Fehler aus
    /// `client.health()` und `Task.sleep` — auch einen kooperativen Task-Abbruch. Der
    /// `SidecarClient` reicht `CancellationError` bewusst unverpackt nach oben (siehe
    /// `SidecarClient.swift`), damit Aufrufer ihn erkennen können; diese Schleife muss ihn also
    /// durchreichen statt als Busy-Spin bis zum vollen `readyTimeout` weiterzulaufen.
    private func waitForReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: readyTimeout)

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            do {
                let state = try await client.health()
                switch state.status {
                case "ready":
                    return
                case "failed":
                    throw LifecycleError.failed(state.error ?? "unbekannter Fehler")
                default:
                    break  // "starting" — weiter warten
                }
            } catch let error as CancellationError {
                throw error
            } catch let error as LifecycleError {
                throw error
            } catch {
                // Sonstiger Fehler aus `client.health()` (z. B. SidecarError.unreachable/
                // .timedOut) — der Sidecar antwortet noch nicht wie erwartet, einfach weiter
                // pollen, bis der Timeout oben greift.
            }

            try await Task.sleep(for: pollInterval)
        }
        throw LifecycleError.readyTimeout
    }
}

/// Die echte Implementierung über ``Foundation.Process``.
public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    public func run(executable: String, arguments: [String],
                    workingDirectory: String) throws -> ProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        try process.run()
        return FoundationProcessHandle(process: process)
    }
}

/// Kapselt ``Foundation.Process``, das selbst nicht ``Sendable`` ist. Der Prozess wird nach dem
/// Start nur noch über die threadsichere `isRunning`/`terminate()`-Oberfläche angesprochen, die
/// von `Foundation.Process` bereits synchronisiert wird — daher `@unchecked Sendable`.
final class FoundationProcessHandle: ProcessHandle, @unchecked Sendable {
    private let process: Process

    init(process: Process) { self.process = process }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()   // SIGTERM — der Sidecar fährt sauber herunter (siehe M2)
    }
}
