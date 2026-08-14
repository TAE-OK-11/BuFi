from pathlib import Path


def replace_exact(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    if old not in text:
        raise SystemExit(f"missing expected block in {path}: {old[:120]!r}")
    file.write_text(text.replace(old, new, 1))


replace_exact(
    "BuFi/UI/RootView.swift",
    '''        .onChange(of: scenePhase) { _, phase in\n            guard phase != .active else { return }\n            Task(priority: .utility) {\n                await OfflineStore.shared.flushPendingWrites()\n                await ListeningHistoryStore.shared.flushPendingWrites()\n            }\n        }\n''',
    '''        .task(id: scenePhase == .active) {\n            guard scenePhase != .active else { return }\n            await OfflineStore.shared.flushPendingWrites()\n            await ListeningHistoryStore.shared.flushPendingWrites()\n        }\n''',
)

replace_exact(
    "BuFi/UI/LibraryView.swift",
    '''        BuFiGroupedSurface {\n            VStack(spacing: 0) {\n                ForEach(items) { item in\n''',
    '''        BuFiGroupedSurface {\n            LazyVStack(spacing: 0) {\n                ForEach(items) { item in\n''',
)

replace_exact(
    "BuFi/UI/SearchView.swift",
    '''            BuFiGroupedSurface {\n                VStack(spacing: 0) {\n                    content()\n                }\n            }\n''',
    '''            BuFiGroupedSurface {\n                LazyVStack(spacing: 0) {\n                    content()\n                }\n            }\n''',
)

replace_exact(
    "BuFi/UI/ServerLatencyBadge.swift",
    '''    @State private var measurementGeneration: UInt64 = 0\n    @State private var measurementTask: Task<Void, Never>?\n''',
    '''    @State private var measurementGeneration: UInt64 = 0\n    @State private var measurementTask: Task<Void, Never>?\n    @State private var lastMeasuredAt: ContinuousClock.Instant?\n''',
)
replace_exact(
    "BuFi/UI/ServerLatencyBadge.swift",
    '''        Button {\n            startMeasurement()\n''',
    '''        Button {\n            startMeasurement(force: true)\n''',
)
replace_exact(
    "BuFi/UI/ServerLatencyBadge.swift",
    '''        .onChange(of: clientIdentifier) { _, _ in\n            startMeasurement()\n        }\n''',
    '''        .onChange(of: clientIdentifier) { _, _ in\n            latencyMilliseconds = nil\n            measurementFailed = false\n            lastMeasuredAt = nil\n            startMeasurement()\n        }\n''',
)
replace_exact(
    "BuFi/UI/ServerLatencyBadge.swift",
    '''    private func startMeasurement() {\n        measurementTask?.cancel()\n        measurementTask = nil\n        measurementGeneration &+= 1\n        let generation = measurementGeneration\n\n        guard let client else {\n            latencyMilliseconds = nil\n            measurementFailed = false\n            isMeasuring = false\n            return\n        }\n\n        isMeasuring = true\n''',
    '''    private func startMeasurement(force: Bool = false) {\n        guard let client else {\n            measurementTask?.cancel()\n            measurementTask = nil\n            latencyMilliseconds = nil\n            measurementFailed = false\n            lastMeasuredAt = nil\n            isMeasuring = false\n            return\n        }\n\n        let now = ContinuousClock().now\n        if !force,\n           latencyMilliseconds != nil,\n           !measurementFailed,\n           let lastMeasuredAt,\n           lastMeasuredAt.duration(to: now) < .seconds(60) {\n            return\n        }\n\n        measurementTask?.cancel()\n        measurementTask = nil\n        measurementGeneration &+= 1\n        let generation = measurementGeneration\n        isMeasuring = true\n''',
)
replace_exact(
    "BuFi/UI/ServerLatencyBadge.swift",
    '''                latencyMilliseconds = latency\n                measurementFailed = false\n                isMeasuring = false\n''',
    '''                latencyMilliseconds = latency\n                measurementFailed = false\n                lastMeasuredAt = ContinuousClock().now\n                isMeasuring = false\n''',
)
replace_exact(
    "BuFi/UI/ServerLatencyBadge.swift",
    '''                latencyMilliseconds = nil\n                measurementFailed = true\n                isMeasuring = false\n''',
    '''                latencyMilliseconds = nil\n                measurementFailed = true\n                lastMeasuredAt = nil\n                isMeasuring = false\n''',
)

# Structural checks for the final runtime path.
root = Path("BuFi/UI/RootView.swift").read_text()
if ".onChange(of: scenePhase)" in root:
    raise SystemExit("unstructured scenePhase flush remains")
if "Task.detached" in "\n".join(path.read_text() for path in Path("BuFi").rglob("*.swift")):
    raise SystemExit("Task.detached remains")
if "LazyVStack(spacing: 0)" not in Path("BuFi/UI/LibraryView.swift").read_text():
    raise SystemExit("library list is not lazy")
if "lastMeasuredAt" not in Path("BuFi/UI/ServerLatencyBadge.swift").read_text():
    raise SystemExit("latency freshness cache missing")

print("UI energy refinement applied")
