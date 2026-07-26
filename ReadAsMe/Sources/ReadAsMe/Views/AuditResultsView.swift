import SwiftUI

struct AuditResultsView: View {
    @ObservedObject var controller: AudiobookController
    let report: AuditReport
    let onShowLogs: () -> Void

    @State private var filter: ResultsFilter = .all
    @State private var confirmRepairAll = false

    private var visibleFindings: [AuditFinding] {
        switch filter {
        case .all: report.findings
        case .critical: report.findings.filter { $0.severity == .critical }
        case .safe: report.findings.filter { $0.repairSafety == .safe }
        case .review: report.findings.filter { $0.repairSafety == .review }
        case .unresolved: report.findings.filter { $0.repairStatus == .pending || $0.repairStatus == .failed }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.summary.status)
                        .font(.title2.weight(.semibold))
                    Text("\(report.summary.findingCount) findings · \(duration(report.summary.durationSeconds))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onShowLogs) {
                    Label("Logs", systemImage: "text.alignleft")
                }
                Button {
                    controller.openAuditReport()
                } label: {
                    Label("Report", systemImage: "doc.text")
                }
            }
            .padding(20)

            Divider()

            HStack {
                Picker("Filter", selection: $filter) {
                    ForEach(ResultsFilter.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Spacer()

                Button("Repair Selected") {
                    controller.repair(ids: controller.selectedFindingIDs)
                }
                .disabled(controller.selectedFindingIDs.isEmpty || controller.auditState.isBusy)

                Button("Repair All Safe") {
                    controller.repairAllSafe()
                }
                .disabled(!report.findings.contains(where: { $0.repairSafety == .safe }) || controller.auditState.isBusy)

                Button("Repair All") {
                    confirmRepairAll = true
                }
                .disabled(!report.findings.contains(where: { $0.repairSafety != .unrepairable }) || controller.auditState.isBusy)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if visibleFindings.isEmpty {
                ContentUnavailableView(
                    "No Findings",
                    systemImage: "checkmark.seal",
                    description: Text("Nothing matches the current filter.")
                )
            } else {
                List(visibleFindings) { finding in
                    FindingRow(controller: controller, finding: finding)
                }
                .listStyle(.inset)
            }

            if controller.auditState.isBusy {
                VStack(spacing: 6) {
                    ProgressView(value: controller.progressFraction)
                    HStack {
                        Text(controller.progressTitle)
                        Spacer()
                        Button("Cancel") {
                            controller.cancelQualityOperation()
                        }
                    }
                    .font(.caption)
                }
                .padding(12)
                .background(.bar)
            } else if controller.latestRepairedOutputURL != nil {
                HStack {
                    Label("Verified repaired copy saved", systemImage: "checkmark.seal")
                    Spacer()
                    Button("Open Repaired Audio") {
                        controller.openLatestRepairedOutput()
                    }
                }
                .padding(12)
                .background(.bar)
            }
        }
        .confirmationDialog(
            "Repair every repairable finding?",
            isPresented: $confirmRepairAll,
            titleVisibility: .visible
        ) {
            Button("Repair All, Including Review Items") {
                controller.repairAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This includes lower-confidence timing and speech changes. ReadAsMe will create a new file and verify the result; the original remains untouched.")
        }
    }

    private func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: seconds) ?? "\(Int(seconds)) sec"
    }
}

private enum ResultsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case critical = "Critical"
    case safe = "Safe"
    case review = "Review"
    case unresolved = "Unresolved"

    var id: String { rawValue }
}

private struct FindingRow: View {
    @ObservedObject var controller: AudiobookController
    let finding: AuditFinding

    private var isSelected: Binding<Bool> {
        Binding(
            get: { controller.selectedFindingIDs.contains(finding.id) },
            set: { selected in
                if selected {
                    controller.selectedFindingIDs.insert(finding.id)
                } else {
                    controller.selectedFindingIDs.remove(finding.id)
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: isSelected)
                .labelsHidden()
                .disabled(finding.repairSafety == .unrepairable || finding.repairStatus == .repaired)

            Button {
                controller.playFinding(finding)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .help("Play this timestamp with context")

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(finding.type.title)
                        .font(.headline)
                    SeverityBadge(severity: finding.severity)
                    RepairBadge(safety: finding.repairSafety)
                    if finding.repairStatus == .repaired {
                        Label("Repaired", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text(finding.message)
                    .fixedSize(horizontal: false, vertical: true)
                if let expected = finding.expectedText {
                    Text("Expected: \(expected)")
                        .font(.caption)
                }
                if let observed = finding.observedText {
                    Text("Heard: \(observed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(timestamp(finding.timeRange.start))–\(timestamp(finding.timeRange.end)) · \(Int((finding.confidence * 100).rounded()))% confidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct SeverityBadge: View {
    let severity: FindingSeverity

    var body: some View {
        Text(severity.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch severity {
        case .critical: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

private struct RepairBadge: View {
    let safety: RepairSafety

    var body: some View {
        Text(safety.rawValue.capitalized)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
