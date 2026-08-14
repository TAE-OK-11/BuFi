from pathlib import Path

path = Path("BuFi/Core/OfflineStore.swift")
text = path.read_text(encoding="utf-8")
old = '''        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func loadEntries(indexURL: URL, directory: URL) -> [String: Entry] {
'''
new = '''        return try await withTaskCancellationHandler {
            let staged = try await worker.value
            do {
                try Task.checkCancellation()
                return staged
            } catch {
                try? FileManager.default.removeItem(at: staged.url)
                throw error
            }
        } onCancel: {
            worker.cancel()
        }
    }

    private static func loadEntries(indexURL: URL, directory: URL) -> [String: Entry] {
'''
if text.count(old) != 1:
    raise RuntimeError(f"expected one staging return block, found {text.count(old)}")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
