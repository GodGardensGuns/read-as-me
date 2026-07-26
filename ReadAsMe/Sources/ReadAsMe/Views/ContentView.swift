import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: AudiobookController
    @State private var isShowingLogs = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("Workflow", selection: $controller.workflowMode) {
                            ForEach(WorkflowMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        switch controller.workflowMode {
                        case .generate:
                            BookPickerView(controller: controller)
                            VoicePickerView(controller: controller)
                        case .auditExisting:
                            AuditSetupView(controller: controller)
                        }

                        OutputPickerView(controller: controller)

                        if controller.workflowMode == .generate {
                            ServerControlView(controller: controller)
                            ConversionControlView(controller: controller)
                        }
                    }
                    .padding(20)
                }
                .frame(width: 390)

                Divider()

                Group {
                    if let report = controller.auditReport {
                        AuditResultsView(controller: controller, report: report) {
                            isShowingLogs = true
                        }
                    } else {
                        ProgressSummaryView(controller: controller) {
                            isShowingLogs = true
                        }
                        .padding(20)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingLogs) {
            LogsSheetView(controller: controller) {
                isShowingLogs = false
            }
            .frame(minWidth: 720, minHeight: 520)
        }
        .sheet(isPresented: $controller.isShowingSourceReview) {
            SourceTextReviewView(controller: controller)
                .frame(minWidth: 760, minHeight: 560)
                .interactiveDismissDisabled()
        }
        .onChange(of: controller.workflowMode) { _, _ in
            controller.workflowDidChange()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("ReadAsMe")
                    .font(.title2.weight(.semibold))
                Text(controller.auditState.isBusy || controller.auditReport != nil
                     ? controller.auditState.label
                     : controller.conversionState.label)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            Spacer()
            StatusPill(title: controller.serverState.rawValue, systemImage: "server.rack")
            if let report = controller.auditReport {
                StatusPill(title: report.summary.status, systemImage: report.summary.criticalCount > 0 ? "exclamationmark.triangle" : "checkmark.seal")
            }
            if case .complete = controller.conversionState {
                Button {
                    controller.openLatestOutput()
                } label: {
                    Label("Open Audio", systemImage: "play.circle")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

private struct StatusPill: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
