import Foundation

public enum Fixtures {
    public static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    public static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    public static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    public static var all: [URL] {
        let urls = try! FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return urls.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
