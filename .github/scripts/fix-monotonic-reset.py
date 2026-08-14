from pathlib import Path

path = Path('BuFi/App/AppModel.swift')
text = path.read_text()
text = text.replace('lastFullRefresh = .distantPast', 'lastFullRefresh = nil')
text = text.replace('lastHomeSnapshotSave = .distantPast', 'lastHomeSnapshotSave = nil')
if 'lastFullRefresh = .distantPast' in text or 'lastHomeSnapshotSave = .distantPast' in text:
    raise SystemExit('legacy Date sentinel remains')
path.write_text(text)
print('fixed monotonic clock reset sentinels')
