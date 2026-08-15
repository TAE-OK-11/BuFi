import SwiftUI

struct ServerLatencyBadge: View {
    let client: OpenSubsonicClient?

    @State private var latencyMilliseconds: Double?
    @State private var isMeasuring = false
    @State private var measurementFailed = false
    @State private var measurementGeneration: UInt64 = 0
    @State private var measurementTask: Task<Void, Never>?
    @State private var lastMeasuredAt: ContinuousClock.Instant?

    var body: some View {
        Button {
            startMeasurement(force: true)
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
        .onAppear {
            startMeasurement()
        }
        .onChange(of: clientIdentifier) { _, _ in
            latencyMilliseconds = nil
            measurementFailed = false
            lastMeasuredAt = nil
            startMeasurement()
        }
        .onDisappear {
            cancelMeasurement()
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
        client.map { ObjectIdentifier($0) }
    }

    private func startMeasurement(force: Bool = false) {
        guard let client else {
            measurementTask?.cancel()
            measurementTask = nil
            latencyMilliseconds = nil
            measurementFailed = false
            lastMeasuredAt = nil
            isMeasuring = false
            return
        }

        let now = ContinuousClock().now
        if !force,
           latencyMilliseconds != nil,
           !measurementFailed,
           let lastMeasuredAt,
           lastMeasuredAt.duration(to: now) < .seconds(60) {
            return
        }

        measurementTask?.cancel()
        measurementTask = nil
        measurementGeneration &+= 1
        let generation = measurementGeneration
        isMeasuring = true
        measurementFailed = false
        measurementTask = Task {
            do {
                let latency = try await client.measuredServerLatency()
                guard !Task.isCancelled,
                      measurementGeneration == generation else { return }
                latencyMilliseconds = latency
                measurementFailed = false
                lastMeasuredAt = ContinuousClock().now
                isMeasuring = false
                measurementTask = nil
            } catch is CancellationError {
                guard measurementGeneration == generation else { return }
                isMeasuring = false
                measurementTask = nil
                return
            } catch {
                guard !Task.isCancelled,
                      measurementGeneration == generation else { return }
                latencyMilliseconds = nil
                measurementFailed = true
                lastMeasuredAt = nil
                isMeasuring = false
                measurementTask = nil
            }
        }
    }

    private func cancelMeasurement() {
        measurementGeneration &+= 1
        measurementTask?.cancel()
        measurementTask = nil
        isMeasuring = false
    }
}
