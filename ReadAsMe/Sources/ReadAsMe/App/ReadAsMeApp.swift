import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ReadAsMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AudiobookController()

    var body: some Scene {
        WindowGroup("ReadAsMe") {
            ContentView(controller: controller)
                .frame(minWidth: 820, minHeight: 640)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    controller.terminateOwnedProcesses()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Audiobook") {
                Button("Choose Book") {
                    controller.chooseBook()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Convert") {
                    controller.convertSelectedBook()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!controller.canConvert)

                Divider()

                Button("Choose Voice Sample") {
                    controller.chooseVoiceSample()
                }

                Button("Choose Voice Transcript") {
                    controller.chooseVoiceTranscript()
                }

                Button("Clear Voice Selection") {
                    controller.clearVoiceSelection()
                }

                Divider()

                Button("Start Voice Engine") {
                    controller.startServer()
                }
                .disabled(controller.serverState != .stopped)

                Button("Stop Voice Engine") {
                    controller.stopServer()
                }
                .disabled(controller.serverState == .stopped)
            }
        }
    }
}
