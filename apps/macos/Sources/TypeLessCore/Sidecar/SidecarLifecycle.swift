import Darwin
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
    /// Hartes Nachfassen (SIGKILL), falls `terminate()` (SIGTERM) den Prozess nicht binnen
    /// einer angemessenen Frist beendet hat.
    func forceTerminate()
}

/// Startet Prozesse. Als Protokoll, damit Tests keinen echten Prozess starten müssen.
public protocol ProcessRunner: Sendable {
    func run(executable: String, arguments: [String], workingDirectory: String,
             environment: [String: String]) throws -> ProcessHandle
}

/// Bringt den Sidecar hoch.
public protocol SidecarLifecycle: Sendable {
    func start() async throws -> SidecarOwnership
    func stop() async
}

public actor DefaultSidecarLifecycle: SidecarLifecycle {
    private let client: SidecarClient
    private let runner: ProcessRunner
    /// Der Startbefehl (Exekutable, Argumente, Arbeitsverzeichnis, Umgebung) für den Spawn-Zweig
    /// — von außen gereicht (s. `EngineLaunch.resolve`, Composition-Root), damit dieser Typ weder
    /// weiß noch entscheiden muss, ob die Engine gebündelt oder aus dem Entwicklungs-Repo startet.
    private let launch: EngineLaunch
    /// Der Socket-Pfad, auf dem der gespawnte Sidecar lauschen soll — wird dem Kindprozess als
    /// `TYPELESS_SOCKET_PATH` mitgegeben (s. `engine/typeless_engine/config.py`). Der Lifecycle
    /// muss ihn kennen, damit derselbe Pfad, auf den `client` verbindet, auch tatsächlich beim
    /// Spawn ankommt (Finding I2, Review).
    private let socketPath: String
    private let readyTimeout: Duration
    private let pollInterval: Duration
    /// Obergrenze, wie lange ``stop()`` nach dem SIGTERM auf das tatsächliche Prozessende
    /// wartet, bevor hart nachgefasst wird (SIGKILL). Getrennt vom Start-Timeout: Ein
    /// Prozessende passiert normalerweise binnen Millisekunden (Review: ~0,22 s gemessen),
    /// nicht Sekunden.
    private let terminateTimeout: Duration
    private let terminatePollInterval: Duration

    /// Nur gesetzt, wenn **wir** den Prozess gestartet haben.
    private var ownProcess: ProcessHandle?

    public init(client: SidecarClient, runner: ProcessRunner, launch: EngineLaunch,
                socketPath: String, readyTimeout: Duration = .seconds(90),
                pollInterval: Duration = .seconds(1), terminateTimeout: Duration = .seconds(2),
                terminatePollInterval: Duration = .milliseconds(20)) {
        self.client = client
        self.runner = runner
        self.launch = launch
        self.socketPath = socketPath
        self.readyTimeout = readyTimeout
        self.pollInterval = pollInterval
        self.terminateTimeout = terminateTimeout
        self.terminatePollInterval = terminatePollInterval
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

        // 2. Niemand da: selbst starten. Das auszuführende Programm (mitgeliefertes `uv` im
        // Bündel oder das Dev-`uv`) muss vorhanden und ausführbar sein.
        guard FileManager.default.isExecutableFile(atPath: launch.executable) else {
            throw LifecycleError.uvMissing(launch.executable)
        }

        ownProcess = try runner.run(
            executable: launch.executable,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectory,
            environment: launch.environment)

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

    /// Beendet **nur**, was wir selbst gestartet haben — und kehrt erst zurück, wenn der
    /// Prozess wirklich tot ist.
    ///
    /// Finding C1 (Review): SIGTERM (`terminate()`) beendet den Sidecar nicht synchron. Der
    /// Reviewer hat gemessen: 0,05 s nach dem Signal antwortet `/health` noch mit
    /// `{"status":"ready"}`, erst nach ~0,22 s ist der Prozess tot. Kehrte `stop()` sofort
    /// zurück (altes Verhalten), hielt ein direkt anschließendes `start()` — dessen erster
    /// Schritt `client.health()` ist — den sterbenden Prozess für gesund und adoptierte ihn
    /// (`.adopted`, `ownProcess` bleibt `nil`). Sekunden später stirbt er dann wirklich, das
    /// Polling kippt auf „Verbindung zur Engine verloren" — obwohl `restart()` gerade erst
    /// gelaufen ist. Deshalb hier aktiv auf `!isRunning` warten (mit Obergrenze
    /// `terminateTimeout`) und danach nötigenfalls hart nachfassen (SIGKILL).
    public func stop() async {
        guard let process = ownProcess else { return }
        process.terminate()
        await waitUntilExited(process, timeout: terminateTimeout)
        if process.isRunning {
            process.forceTerminate()
            await waitUntilExited(process, timeout: terminateTimeout)
        }
        ownProcess = nil
    }

    /// Pollt ``ProcessHandle/isRunning`` bis zur Obergrenze `timeout` — kein fester `sleep`,
    /// sondern eine Schleife mit kurzer Taktung (`terminatePollInterval`), die endet, sobald der
    /// Prozess wirklich weg ist.
    private func waitUntilExited(_ process: ProcessHandle, timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: terminatePollInterval)
        }
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

    public func run(executable: String, arguments: [String], workingDirectory: String,
                    environment: [String: String]) throws -> ProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        // Bestehende Umgebung erben (PATH etc. — sonst findet `uv` z. B. seine eigene
        // Installation nicht mehr) und um die übergebenen Variablen ergänzen (Finding I2,
        // Review: der Sidecar braucht `TYPELESS_SOCKET_PATH`, sonst lauscht er auf seinem
        // eigenen Default statt dem vom `SettingsStore` konfigurierten Pfad).
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
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

    func forceTerminate() {
        guard process.isRunning else { return }
        // `Foundation.Process` bietet kein SIGKILL direkt an — deshalb über die PID.
        kill(process.processIdentifier, SIGKILL)
    }
}
