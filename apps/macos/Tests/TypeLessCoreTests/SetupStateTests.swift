import Testing
@testable import TypeLessCore

@Test func downloadingIstSichtbarMitAnteil() {
    let s = SetupState(models: ModelsStatus(state: "downloading", downloadedBytes: 1950,
                                            totalBytes: 3900, error: nil))
    #expect(s == .downloading(fraction: 0.5, downloadedBytes: 1950, totalBytes: 3900))
}

@Test func failedIstSichtbarMitGrund() {
    let s = SetupState(models: ModelsStatus(state: "failed", downloadedBytes: 0, totalBytes: 3900,
                                            error: "kein Netz"))
    #expect(s == .failed("kein Netz"))
}

@Test func readyUndMissingSindVersteckt() {
    // Nie ein Fenster bei vollem Cache (ready) oder im kurzen Anlauf (missing).
    #expect(SetupState(models: ModelsStatus(state: "ready", downloadedBytes: 0, totalBytes: 0, error: nil)) == .hidden)
    #expect(SetupState(models: ModelsStatus(state: "missing", downloadedBytes: 0, totalBytes: 0, error: nil)) == .hidden)
}

@Test func downloadingOhneGesamtgroesseHatAnteilNull() {
    // total_bytes == 0 darf nicht durch Null teilen.
    let s = SetupState(models: ModelsStatus(state: "downloading", downloadedBytes: 0, totalBytes: 0, error: nil))
    #expect(s == .downloading(fraction: 0.0, downloadedBytes: 0, totalBytes: 0))
}
