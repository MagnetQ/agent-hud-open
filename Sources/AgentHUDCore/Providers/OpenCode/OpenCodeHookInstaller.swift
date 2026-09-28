import AgentHUDSupport
import Foundation

/// OpenCode's plugin SDK (`@opencode-ai/plugin`) exposes a `permission.ask` hook that mirrors Claude Code's
/// `PermissionRequest` payload, so Agent HUD reuses its `--permission-hook opencode` subprocess to forward a request to
/// its running socket.
///
/// Settings are not written: OpenCode does not carry a hooks block, it loads any `.js` file under `plugins/`. Agent HUD
/// drops a plugin file there when hooks are enabled and removes it when they are not.
public enum OpenCodeHookInstaller {
    public static let pluginFileName = "agent-hud.js"
    public static let pluginMarker = "// Installed by Agent HUD Open — do not edit by hand."

    public static func pluginDirectory(home: URL,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let configRoot = URL(fileURLWithPath: environment["XDG_CONFIG_HOME"]
                             ?? home.appendingPathComponent(".config").path)
        return configRoot.appendingPathComponent("opencode/plugins", isDirectory: true)
    }

    public static func pluginURL(home: URL,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        pluginDirectory(home: home, environment: environment).appendingPathComponent(pluginFileName)
    }

    /// `Bun.spawn` is the OpenCode plugin runtime; the subprocess reads the Claude Code style payload from stdin and
    /// writes a JSON decision to stdout. With no decision the HUD leaves the request alone, so OpenCode falls back to
    /// its own permission dialog.
    static let pluginSource: String = #"""
    import type { Plugin } from "@opencode-ai/plugin"

    const HUD_EXECUTABLE = "__HUD_PATH__"
    // Installed by Agent HUD Open — do not edit by hand.

    export default (async () => ({
      "permission.ask": async (input, output) => {
        const payload = JSON.stringify({
          session_id: input.sessionID ?? "",
          cwd: input.cwd ?? "",
          tool_name: input.tool ?? "",
          tool_input: input.args ?? {},
        })
        const proc = Bun.spawn({
          cmd: [HUD_EXECUTABLE, "--permission-hook", "opencode"],
          stdin: "pipe",
          stdout: "pipe",
          stderr: "inherit",
        })
        const writer = proc.stdin.getWriter()
        await writer.write(new TextEncoder().encode(payload))
        await writer.close()
        const text = await new Response(proc.stdout).text()
        let parsed
        try { parsed = JSON.parse(text) } catch { return }
        const behavior = parsed?.hookSpecificOutput?.decision?.behavior
        if (behavior === "allow") output.decision = "allow"
        else if (behavior === "deny") output.decision = "deny"
      },
    })) satisfies Plugin
    """#

    public static func install(executable: URL, home: URL,
                               environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let directory = pluginDirectory(home: home, environment: environment)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let quoted = executable.path.replacingOccurrences(of: "'", with: "'\\''")
        let body = pluginSource.replacingOccurrences(of: "__HUD_PATH__", with: quoted)
        let url = pluginURL(home: home, environment: environment)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != body else { return }
        try body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    public static func uninstall(home: URL,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        let url = pluginURL(home: home, environment: environment)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Keep the plugin around if it was edited by hand; only remove the one we wrote.
        if let content = try? String(contentsOf: url, encoding: .utf8), content.contains(pluginMarker) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func isInstalled(home: URL,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let url = pluginURL(home: home, environment: environment)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(pluginMarker)
    }
}
