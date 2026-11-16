import Foundation

/// Installing the `marko` command: the app runs the script it ships with, the same one as
/// scripts/install-cli.sh in the repository, so there is one way of doing it.
enum CommandLineTool {
    /// Links the tool into `directory`, or into the script's own choice of folder. Returns whether
    /// that worked and what the script said.
    static func install(in directory: String? = nil) -> (isInstalled: Bool, output: String) {
        guard let script = Bundle.main.url(forResource: "install-cli", withExtension: "sh") else {
            return (false, "This copy of Marko has no install script.")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + (directory.map { [$0] } ?? [])
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return (false, error.localizedDescription) }
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus == 0, said.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the script said with "~" for the home folder, where a path starts with it: the folder
    /// as it is named and as it is reached through links, which the script's paths may be either of.
    static func abbreviated(_ output: String, home: String = NSHomeDirectory()) -> String {
        let homes = [URL(fileURLWithPath: home).resolvingSymlinksInPath().path, home].map(NSRegularExpression.escapedPattern(for:))
        return output.replacingOccurrences(of: "(?<![^\\s\"])(\(homes.joined(separator: "|")))(?=[/\\s]|$)", with: "~", options: .regularExpression)
    }
}
