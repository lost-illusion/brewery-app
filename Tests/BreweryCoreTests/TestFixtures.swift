import Foundation

func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

func fixtureData(_ name: String) -> Data {
    try! Data(contentsOf: fixtureURL(name))
}
