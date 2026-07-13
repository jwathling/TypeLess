import Foundation
import Testing

@testable import TypeLessCore

@Test func liefertDefaultsWennNichtsGesetztIst() {
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    let store = UserDefaultsSettingsStore(defaults: defaults)

    #expect(store.socketPath.hasSuffix("/Library/Application Support/TypeLess/typeless.sock"))
    #expect(store.engineDirectory.hasSuffix("/engine"))
    #expect(store.uvPath.hasSuffix("/uv"))
}

@Test func merktSichGeaenderteWerte() {
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    let store = UserDefaultsSettingsStore(defaults: defaults)

    store.engineDirectory = "/woanders/engine"

    let wieder = UserDefaultsSettingsStore(defaults: defaults)
    #expect(wieder.engineDirectory == "/woanders/engine")
}

@Test func inMemoryStoreFunktioniertFuerTests() {
    let store = InMemorySettingsStore(engineDirectory: "/a", socketPath: "/b", uvPath: "/c")

    store.engineDirectory = "/x"

    #expect(store.engineDirectory == "/x")
    #expect(store.socketPath == "/b")
}
