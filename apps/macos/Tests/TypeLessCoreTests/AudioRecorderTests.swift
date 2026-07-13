import Foundation
import Testing
@testable import TypeLessCore

/// Attrappe: liefert vorgegebene Werte, ohne je ein Mikrofon anzufassen.
/// Wird von den Koordinator-Tests (Task 4) wiederverwendet.
actor FakeRecorder: AudioRecorder {
    private var samples: [Float]
    private var fehlerBeimStart: AudioRecorderError?
    private(set) var laeuft = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(samples: [Float] = [], fehlerBeimStart: AudioRecorderError? = nil) {
        self.samples = samples
        self.fehlerBeimStart = fehlerBeimStart
    }

    func setSamples(_ neue: [Float]) { samples = neue }

    func start() async throws {
        startCount += 1
        if let fehlerBeimStart { throw fehlerBeimStart }
        laeuft = true
    }

    func stop() async throws -> [Float] {
        stopCount += 1
        guard laeuft else { throw AudioRecorderError.notRecording }
        laeuft = false
        return samples
    }
}

@Test func stopOhneStartScheitertSauber() async throws {
    let recorder = FakeRecorder()

    await #expect(throws: AudioRecorderError.notRecording) {
        _ = try await recorder.stop()
    }
}

@Test func liefertDieAufgenommenenWerte() async throws {
    let recorder = FakeRecorder(samples: [0.1, 0.2, 0.3])

    try await recorder.start()
    let samples = try await recorder.stop()

    #expect(samples == [0.1, 0.2, 0.3])
    #expect(await recorder.startCount == 1)
    #expect(await recorder.stopCount == 1)
}

@Test func echterRecorderLaesstSichErzeugen() {
    // Mehr geht ohne Mikrofon-Berechtigung nicht — die Handprobe in Task 5 ist der echte Test.
    _ = AVAudioEngineRecorder()
}
