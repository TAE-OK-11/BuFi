from pathlib import Path

path = Path(__file__).resolve().parents[1] / "BuFi/Core/OpenSubsonicClient.swift"
text = path.read_text(encoding="utf-8")

old = '''    private func clearResponseCache() {
        clearResponseCache()
        responseCacheBytes = 0
    }
'''
new = '''    private func clearResponseCache() {
        responseCache.removeAll(keepingCapacity: false)
        responseCacheOrder.removeAll(keepingCapacity: false)
        responseCacheBytes = 0
    }
'''
if old not in text:
    raise SystemExit("recursive clear block not found")
text = text.replace(old, new, 1)

old = '''    func trimTransientNetworkCaches() {
        inFlightResponses.values.forEach { $0.task.cancel() }
        inFlightResponses.removeAll(keepingCapacity: false)
        responseCache.removeAll(keepingCapacity: false)
        responseCacheOrder.removeAll(keepingCapacity: false)
    }
'''
new = '''    func trimTransientNetworkCaches() {
        inFlightResponses.values.forEach { $0.task.cancel() }
        inFlightResponses.removeAll(keepingCapacity: false)
        clearResponseCache()
    }
'''
if old not in text:
    raise SystemExit("trim cache block not found")
text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
