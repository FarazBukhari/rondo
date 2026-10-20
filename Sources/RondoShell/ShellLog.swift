import os

/// Shared logger for the shell (status item, HUD, settings, actions, Float shelf, hotkey).
enum ShellLog {
    static let logger = Logger(subsystem: "com.farazbukhari.rondo", category: "shell")
}
