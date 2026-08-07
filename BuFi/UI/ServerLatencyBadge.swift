import SwiftUI

struct ServerLatencyBadge: View {
    let client: OpenSubsonicClient?

    @State private var latencyMilliseconds: Double?
    @State private var isMeasuring = false
    @State private var measurementFailed = false

    var body: some View {
        Button {
            Task { await measure() }
        } label: {
            VStack(alignment: .trailing, spacing: 5) {
                statusIcon
                HStack(spacing: 4) {
                    if isMeasuring {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "network")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(latencyText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(measurementFailed ? .secondary : BuFiTheme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(client == nil || isMeasuring)
        .accessibilityLabel("서버 Ping 측정")
        .accessibilityValue(latencyText)
        .task(id: clientIdentifier) {
            await measure()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if measurementFailed {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("서버 Ping 실패")
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BuFiTheme.accent)
                .accessibilityLabel("서버 연결됨")
        }
    }

    private var latencyText: String {
        if isMeasuring { return "Ping" }
        if measurementFailed { return "재시도" }
        guard let latencyMilliseconds else { return "Ping" }
        return "\(Int(latencyMilliseconds.rounded())) ms"
    }

    private var clientIdentifier: ObjectIdentifier? {
        client.map(ObjectIdentifier.init)
    }

    @MainActor
    private func measure() async {
        guard !isMeasuring, let client else {
            if client == nil {
                latencyMilliseconds = nil
                measurementFailed = true
            }
            return
        }

        isMeasuring = true
        measurementFailed = false
        defer { isMeasuring = false }

        do {
            latencyMilliseconds = try await client.measuredServerLatency()
            measurementFailed = false
        } catch is CancellationError {
            return
        } catch {
            latencyMilliseconds = nil
            measurementFailed = true
        }
    }
}
