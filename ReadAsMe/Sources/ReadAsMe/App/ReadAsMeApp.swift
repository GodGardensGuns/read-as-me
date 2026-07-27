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
                .frame(minWidth: 1080, minHeight: 700)
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
                .disabled(controller.conversionState.isBusy)

                Button("Convert") {
                    controller.convertSelectedBook()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!controller.canConvert)

                Button("Choose Voice Sample") {
                    controller.chooseVoiceSample()
                }
                .disabled(controller.conversionState.isBusy)

                Button("Choose Voice Transcript") {
                    controller.chooseVoiceTranscript()
                }
                .disabled(controller.conversionState.isBusy)

                Button("Clear Voice Selection") {
                    controller.clearVoiceSelection()
                }
                .disabled(controller.conversionState.isBusy)

                Divider()

                Button("Start Voice Engine") {
                    controller.startServer()
                }
                .disabled(controller.serverState != .stopped || controller.conversionState.isBusy)

                Button("Stop Voice Engine") {
                    controller.stopServer()
                }
                .disabled(
                    controller.serverState == .stopped
                        || controller.serverState == .external
                        || controller.conversionState.isBusy
                )
            }
        }
    }
}
