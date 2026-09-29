import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// OpenCode carries no hooks block, so the permission request arrives through a plugin file rather than an entry
/// edited into a settings file. These cover where that file lands, what is written into it, and what is taken back out.
final class OpenCodeHookTests: XCTestCase, @unchecked Sendable {
    private let executable = URL(fileURLWithPath: "/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open")

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The plugin path the real process would use. `isInstalled` reads the same variables, so a test that drives the
    /// observer has to agree with it rather than assume an unset environment.
    private func pluginURL(_ home: URL) -> URL { OpenCodeHookInstaller.pluginURL(home: home) }

    func testThePluginLandsWhereOpenCodeLoadsIt() throws {
        let home = try directory()
        // Compared by path: a directory built with `isDirectory: true` carries a trailing slash in `absoluteString`.
        XCTAssertEqual(OpenCodeHookInstaller.pluginDirectory(home: home, environment: [:]).path,
                       home.appendingPathComponent(".config/opencode/plugins").path)
        XCTAssertEqual(OpenCodeHookInstaller.pluginURL(home: home, environment: [:]).path,
                       home.appendingPathComponent(".config/opencode/plugins/agent-hud.js").path)
        // XDG_CONFIG_HOME moves the whole config root, and the plugin follows it.
        XCTAssertEqual(OpenCodeHookInstaller.pluginDirectory(home: home, environment: ["XDG_CONFIG_HOME": "/xdg"]).path,
                       "/xdg/opencode/plugins")
    }

    func testThePluginForwardsToTheHandlerAndCarriesNothingElse() throws {
        let home = try directory()
        try OpenCodeHookInstaller.install(executable: executable, home: home, environment: [:])

        let body = try String(contentsOf: OpenCodeHookInstaller.pluginURL(home: home, environment: [:]), encoding: .utf8)
        XCTAssertTrue(body.contains(OpenCodeHookInstaller.pluginMarker), "uninstall only removes a file that says it is ours")
        XCTAssertTrue(body.contains("\"permission.ask\""), "the request arrives on that hook")
        XCTAssertTrue(body.contains("\"--permission-hook\", \"opencode\""), "the same subprocess every other client uses")
        XCTAssertTrue(body.contains(executable.path), "the path is the app that answers")
        XCTAssertFalse(body.contains("__HUD_PATH__"), "the placeholder is replaced, not shipped")
        // The payload carries what the HUD needs to answer and nothing a credential would ride out in.
        for field in ["session_id", "cwd", "tool_name", "tool_input"] {
            XCTAssertTrue(body.contains(field), field)
        }
        for absent in ["token", "apiKey", "api_key", "Authorization", "prompt"] {
            XCTAssertFalse(body.contains(absent), "\(absent) has no place in a permission request")
        }
    }

    func testThePathIsWrittenAsAJavaScriptLiteralAndNothingMore() throws {
        let home = try directory()
        // `Bun.spawn` starts no shell, so a single quote is an ordinary character there. Escaping it would hand the
        // command line a quote the path never had.
        for path in ["/Applications/It's Here.app/Contents/MacOS/Agent HUD Open",
                     #"/Applications/The "Best" App/x"#,
                     #"/Applications/back\slash.app/x"#] {
            try OpenCodeHookInstaller.install(executable: URL(fileURLWithPath: path), home: home, environment: [:])
            let body = try String(contentsOf: OpenCodeHookInstaller.pluginURL(home: home, environment: [:]), encoding: .utf8)
            let assignment = try XCTUnwrap(body.split(separator: "\n").first { $0.contains("HUD_EXECUTABLE =") })
            let expected = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            XCTAssertEqual(assignment, "const HUD_EXECUTABLE = \"\(expected)\"", path)
        }
    }

    func testMovingTheApplicationMovesThePlugin() throws {
        let home = try directory(), other = try directory()
        try OpenCodeHookInstaller.install(executable: executable, home: home, environment: [:])
        let url = OpenCodeHookInstaller.pluginURL(home: home, environment: [:])
        let elsewhere = other.appendingPathComponent("Moved.app/Contents/MacOS/Agent HUD Open")
        try OpenCodeHookInstaller.install(executable: elsewhere, home: home, environment: [:])
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains(elsewhere.path), "the handler has to point at where the app is now")
        XCTAssertFalse(body.contains(executable.path), "and at nowhere it was")
    }

    func testOnlyTheFileWeWroteIsTakenOut() throws {
        let home = try directory()
        try OpenCodeHookInstaller.install(executable: executable, home: home, environment: [:])
        let url = OpenCodeHookInstaller.pluginURL(home: home, environment: [:])
        XCTAssertTrue(OpenCodeHookInstaller.isInstalled(home: home, environment: [:]))

        OpenCodeHookInstaller.uninstall(home: home, environment: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(OpenCodeHookInstaller.isInstalled(home: home, environment: [:]))
        // Taking out nothing creates nothing: a machine with no plugin must not gain an OpenCode folder.
        let untouched = try directory()
        OpenCodeHookInstaller.uninstall(home: untouched, environment: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: OpenCodeHookInstaller.pluginDirectory(home: untouched, environment: [:]).path),
                       "no folder is created on the way out")

        // A file of the same name that a user wrote is not ours to remove.
        try Data("export default () => ({})".utf8).write(to: url)
        XCTAssertFalse(OpenCodeHookInstaller.isInstalled(home: home, environment: [:]), "without our marker it is not ours")
        OpenCodeHookInstaller.uninstall(home: home, environment: [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a plugin edited by hand stays where it is")
    }

    func testTheSourceIsWiredForAPluginAndOffersNoRules() throws {
        let home = try directory()
        XCTAssertEqual(PermissionHooks.Source.opencode.vendor, "OpenCode")
        XCTAssertEqual(PermissionHooks.Source.opencode.sessionID("s"), "opencode:s",
                       "the request is matched to the client's own sessions")
        XCTAssertEqual(PermissionHooks.Source.opencode.configuration(home: home), pluginURL(home),
                       "the hook points at the plugin file, not at a settings file")
        XCTAssertFalse(PermissionHooks.Source.opencode.supportsPermissionUpdates,
                       "OpenCode offers no rule suggestion, so allow-once and deny are all the HUD gives")
        XCTAssertEqual(PermissionHooks.Source.opencode.matcher, Optional(""), "every tool the client would ask about")
    }

    func testTheObserverInstallsAndRemovesThePluginWithoutWritingSettings() throws {
        let home = try directory()
        // The source counts as installed when OpenCode's own data or config folder is on this Mac. Both are made so
        // the test does not depend on which XDG variables the machine running it happens to set.
        for folder in [".local/share/opencode", ".config/opencode"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        XCTAssertTrue(PermissionHooks.Source.opencode.isInstalled(home: home))
        let url = pluginURL(home)

        SessionObservers.configure(executable: executable, enabled: true, home: home)
        XCTAssertTrue(OpenCodeHookInstaller.isInstalled(home: home), "the plugin is written where OpenCode loads it")
        // `directory` is what a settings-writing client would use, so an install that went that way would leave a file.
        for folder in ["opencode", ".opencode"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("\(folder)/settings.json").path),
                           "no settings file is created for \(folder)")
        }

        SessionObservers.configure(executable: executable, enabled: false, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "turning hooks off takes the plugin back out")
    }
}
