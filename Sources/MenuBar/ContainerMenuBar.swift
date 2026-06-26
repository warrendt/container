//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import AppKit
import Foundation

@main
final class ContainerMenuBarApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let commandRunner = ContainerCommandRunner()
    private var containers: [MenuContainer] = []
    private var statusMessage = "Loading…"
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "▣"
        statusItem.button?.toolTip = "Container"
        rebuildMenu()
        refresh()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 10,
            target: self,
            selector: #selector(refreshFromTimer),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func refreshFromTimer() {
        refresh()
    }

    @objc private func refreshMenuItem() {
        refresh()
    }

    @objc private func startSystem() {
        runCommand(["system", "start"], successMessage: "Container services started")
    }

    @objc private func stopSystem() {
        runCommand(["system", "stop"], successMessage: "Container services stopped")
    }

    @objc private func runNewContainer() {
        let alert = NSAlert()
        alert.messageText = "Run Container"
        alert.informativeText = "Enter an OCI image or repository URL to run detached."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = "ghcr.io/example/image:latest"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let image = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else {
            showMessage("Image or repo URL is required")
            return
        }

        runCommand(["run", "--detach", image], successMessage: "Started \(image)")
    }

    @objc private func startContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        runCommand(["start", id], successMessage: "Started \(id)")
    }

    @objc private func stopContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        runCommand(["stop", id], successMessage: "Stopped \(id)")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        statusMessage = "Refreshing…"
        rebuildMenu()

        Task {
            do {
                let statusResult = try await commandRunner.run(["system", "status", "--format", "json"])
                let systemStatus = SystemStatus(json: statusResult.stdout).status
                let listResult = try await commandRunner.run(["list", "--all", "--format", "json"])
                let decoded = try JSONDecoder().decode([MenuContainer].self, from: Data(listResult.stdout.utf8))

                await MainActor.run {
                    containers = decoded.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
                    statusMessage = "System: \(systemStatus)"
                    updateStatusTitle()
                    rebuildMenu()
                }
            } catch {
                await MainActor.run {
                    containers = []
                    statusMessage = "System: not running"
                    updateStatusTitle()
                    rebuildMenu(error: commandRunner.display(error))
                }
            }
        }
    }

    private func runCommand(_ arguments: [String], successMessage: String) {
        statusMessage = "Running \(arguments.joined(separator: " "))…"
        rebuildMenu()

        Task {
            do {
                _ = try await commandRunner.run(arguments)
                await MainActor.run {
                    showMessage(successMessage)
                    refresh()
                }
            } catch {
                await MainActor.run {
                    showMessage(commandRunner.display(error))
                    refresh()
                }
            }
        }
    }

    private func updateStatusTitle() {
        let runningCount = containers.filter { $0.isRunning }.count
        statusItem.button?.title = runningCount > 0 ? "▣ \(runningCount)" : "▣"
    }

    private func rebuildMenu(error: String? = nil) {
        let menu = NSMenu()

        let title = NSMenuItem(title: "Container", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let status = NSMenuItem(title: statusMessage, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let error {
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Start Services", action: #selector(startSystem), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop Services", action: #selector(stopSystem), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Run Image/Repo URL…", action: #selector(runNewContainer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshMenuItem), keyEquivalent: "r"))
        menu.addItem(.separator())

        if containers.isEmpty {
            let empty = NSMenuItem(title: "No containers", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for container in containers {
                menu.addItem(menuItem(for: container))
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func menuItem(for container: MenuContainer) -> NSMenuItem {
        let item = NSMenuItem(title: container.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let image = NSMenuItem(title: container.imageReference, action: nil, keyEquivalent: "")
        image.isEnabled = false
        submenu.addItem(image)

        let state = NSMenuItem(title: "Status: \(container.status.state)", action: nil, keyEquivalent: "")
        state.isEnabled = false
        submenu.addItem(state)
        submenu.addItem(.separator())

        let start = NSMenuItem(title: "Start", action: #selector(startContainer(_:)), keyEquivalent: "")
        start.representedObject = container.id
        start.isEnabled = !container.isRunning
        submenu.addItem(start)

        let stop = NSMenuItem(title: "Stop", action: #selector(stopContainer(_:)), keyEquivalent: "")
        stop.representedObject = container.id
        stop.isEnabled = container.isRunning
        submenu.addItem(stop)

        item.submenu = submenu
        return item
    }

    private func showMessage(_ message: String) {
        statusMessage = message
        rebuildMenu()
    }
}

private struct MenuContainer: Decodable {
    let id: String
    let configuration: Configuration
    let status: Status

    var isRunning: Bool {
        status.state == "running"
    }

    var imageReference: String {
        configuration.image.reference
    }

    var title: String {
        "\(isRunning ? "●" : "○") \(id)"
    }

    struct Configuration: Decodable {
        let image: Image
    }

    struct Image: Decodable {
        let reference: String
    }

    struct Status: Decodable {
        let state: String
    }
}

private struct SystemStatus: Decodable {
    let status: String

    init(json: String) {
        guard
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(SystemStatus.self, from: data)
        else {
            status = "unknown"
            return
        }
        status = decoded.status
    }
}

private struct CommandResult {
    let stdout: String
    let stderr: String
}

private enum CommandError: LocalizedError {
    case failed(arguments: [String], status: Int32, stdout: String, stderr: String)

    var errorDescription: String? {
        switch self {
        case let .failed(arguments, status, stdout, stderr):
            let message = stderr.isEmpty ? stdout : stderr
            return "\(arguments.joined(separator: " ")) failed (\(status)): \(message)"
        }
    }
}

private struct ContainerCommandRunner {
    func run(_ arguments: [String]) async throws -> CommandResult {
        try await Task.detached {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let command = Self.command(arguments)

            process.executableURL = command.executable
            process.arguments = command.arguments
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let result = CommandResult(
                stdout: stdoutText.trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            guard process.terminationStatus == 0 else {
                throw CommandError.failed(
                    arguments: arguments,
                    status: process.terminationStatus,
                    stdout: result.stdout,
                    stderr: result.stderr
                )
            }
            return result
        }.value
    }

    func display(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return message.isEmpty ? "Command failed" : message
    }

    private static func command(_ arguments: [String]) -> (executable: URL, arguments: [String]) {
        if let override = ProcessInfo.processInfo.environment["CONTAINER_CLI_PATH"],
            FileManager.default.isExecutableFile(atPath: override)
        {
            return (URL(fileURLWithPath: override), arguments)
        }

        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let sibling = executableDirectory.appendingPathComponent("container").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return (URL(fileURLWithPath: sibling), arguments)
        }

        for path in ["/usr/local/bin/container", "/opt/homebrew/bin/container"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return (URL(fileURLWithPath: path), arguments)
            }
        }

        return (URL(fileURLWithPath: "/usr/bin/env"), ["container"] + arguments)
    }
}
