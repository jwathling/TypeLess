import AppKit
import Testing
@testable import TypeLessCore

// MARK: - Electron-Einfügen, Abschluss-Review (Minor #3): Aufwecker beim App-Wechsel

/// Der App-Wechsel-Weg ist der HAUPTPFAD des Aufweckers — der Fn-Druck-Weg ist bereits über
/// `fnDruckWecktDieVordersteApp` in `DictationCoordinatorTests.swift` geprüft, dieser hier bisher
/// nicht. Ein Tippfehler im Notification-Namen oder im `userInfo`-Schlüssel würde weiterhin
/// fehlerfrei kompilieren und im Betrieb einfach nie wecken — der ohnehin vorhandene stille
/// Rückfall auf die Zwischenablage würde das verdecken, bis jemand es an einer Electron-App von
/// Hand bemerkt. Diese Probe postet dieselbe ECHTE `NSWorkspace`-Notification mit demselben
/// `userInfo`-Schlüssel, den macOS im Betrieb benutzt, und prüft, dass der Aufwecker genau die
/// darin enthaltene PID an sein `InsertionTarget` weiterreicht.
///
/// `FakeTarget` wird unverändert aus `DictationCoordinatorTests.swift` mitbenutzt (gleiches
/// Testziel, `gewecktePid` ist dort bereits `internal`, keine eigene Attrappe nötig).
@MainActor
@Test(.timeLimit(.minutes(1)))
func appWechselWecktDieAktivierteApp() async {
    let target = FakeTarget()
    let aufwecker = BedienungshilfenAufwecker(target: target)
    aufwecker.starte()

    let erwartetePid = NSRunningApplication.current.processIdentifier
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didActivateApplicationNotification, object: nil,
        userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])

    // `queue: .main` liefert die Notification asynchron zu — deshalb hier abwarten statt sofort
    // zu prüfen. Kein festes `sleep`: gleiches Muster wie `warteBis` überall sonst in dieser
    // Suite, gepolltes `Task.yield()`, bis die Bedingung eintritt oder das Zeitlimit der Probe
    // abbricht (Sicherheitsbremse gegen ein echtes Hängenbleiben).
    await warteBis { target.gewecktePid == erwartetePid }

    #expect(target.gewecktePid == erwartetePid,
            "Notification-Name und userInfo-Schlüssel müssen zur echten NSWorkspace-Notification passen")
}
