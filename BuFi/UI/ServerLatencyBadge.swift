import SwiftUI

struct ServerLatencyBadge: View {
    let client: OpenSubsonicClient?

    @Environment(\.scenePhase) private var scenePhase
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
        .buttonStyle(BuFiPressStyle())
        .disabled(client == nil || isMeasuring)
        .accessibilityLabel("서버 Ping 측정")
        .accessibilityValue(accessibilityLatencyValue)
        .onAppear {
            startMeasurement()
        }
        .onChange(of: clientIdentifier) { _, _ in
            resetMeasurementState()
            startMeasurement()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
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
                .accessibilityLabel("서버 Ping 측정 불안정")
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BuFiTheme.accent)
                .accessibilityLabel("서버 연결됨")
        }
    }

    private var latencyText: String {
        // Keep the last healthy value visible while a refresh is in progress.
        // This avoids replacing useful information with a transient “Ping”.
        if let latencyMilliseconds {
            return "\(Int(latencyMilliseconds.rounded())) ms"
        }
        if isMeasuring { return "Ping" }
        if measurementFailed { return "재시도" }
        return "Ping"
    }

    private var accessibilityLatencyValue: String {
        if isMeasuring, latencyMilliseconds != nil {
            return "\(latencyText), 새로 측정 중"
        }
        if measurementFailed, latencyMilliseconds != nil {
            return "\(latencyText), 마지막 정상 측정값"
        }
        return latencyText
    }

    private var clientIdentifier: ObjectIdentifier? {
        client.map { ObjectIdentifier($0) }
    }

    private func startMeasurement(force: Bool = false) {
        guard let client else {
            resetMeasurementState()
            return
        }

        let now = ContinuousClock().now
        if !force, isMeasuring {
            return
        }
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
        measurementTask = Task(priority: .userInitiated) {
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
            } catch {
                guard !Task.isCancelled,
                      measurementGeneration == generation else { return }
                // Preserve the last known-good number. A single transient probe
                // failure should not erase useful state or make Settings flicker.
                measurementFailed = true
                lastMeasuredAt = nil
                isMeasuring = false
                measurementTask = nil
            }
        }
    }

    private func resetMeasurementState() {
        measurementGeneration &+= 1
        measurementTask?.cancel()
        measurementTask = nil
        latencyMilliseconds = nil
        measurementFailed = false
        lastMeasuredAt = nil
        isMeasuring = false
    }

    private func cancelMeasurement() {
        measurementGeneration &+= 1
        measurementTask?.cancel()
        measurementTask = nil
        isMeasuring = false
    }
}
