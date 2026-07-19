import Testing
@testable import TypeLessCore

@Test func resolveWaehltEntwicklungWennNichtGebuendelt() {
    let launch = EngineLaunch.resolve(
        bundledEngineDirectory: nil,
        uvPath: "/opt/uv",
        engineDirectory: "/repo/engine",
        socketPath: "/sock/typeless.sock",
        appSupportDirectory: "/AS/TypeLess")

    #expect(launch.executable == "/opt/uv")
    #expect(launch.arguments == ["run", "python", "-m", "typeless_engine.server"])
    #expect(launch.workingDirectory == "/repo/engine")
    #expect(launch.environment == ["TYPELESS_SOCKET_PATH": "/sock/typeless.sock"])
}

@Test func resolveWaehltGebuendeltMitExternerUmgebung() {
    let launch = EngineLaunch.resolve(
        bundledEngineDirectory: "/App/Contents/Resources/engine",
        uvPath: "/opt/uv",                 // im gebündelten Fall ignoriert
        engineDirectory: "/repo/engine",   // im gebündelten Fall ignoriert
        socketPath: "/sock/typeless.sock",
        appSupportDirectory: "/AS/TypeLess")

    #expect(launch.executable == "/App/Contents/Resources/engine/uv")
    #expect(launch.arguments == [
        "run", "--frozen", "--project", "/App/Contents/Resources/engine",
        "--extra", "mlx", "--extra", "server",
        "python", "-m", "typeless_engine.server",
    ])
    // Arbeitsverzeichnis MUSS beschreibbar sein — niemals das read-only Bundle.
    #expect(launch.workingDirectory == "/AS/TypeLess")
    #expect(launch.environment == [
        "TYPELESS_SOCKET_PATH": "/sock/typeless.sock",
        "UV_PROJECT_ENVIRONMENT": "/AS/TypeLess/runtime",
        "UV_CACHE_DIR": "/AS/TypeLess/uv-cache",
        "HF_HOME": "/AS/TypeLess/models",
        "PYTHONPYCACHEPREFIX": "/AS/TypeLess/pycache",
    ])
}
