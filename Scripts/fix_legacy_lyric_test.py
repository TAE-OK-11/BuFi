from pathlib import Path
p = Path('BuFiTests/LyricIntelligenceTests.swift')
s = p.read_text()
old = '''        XCTAssertTrue(signature.hasStoredLyricAnalysis)\n        XCTAssertFalse(signature.hasStoredSoundAnalysis)'''
new = '''        // Legacy lexical JSON must remain decodable for migration, but it is\n        // intentionally not a completed lyric analysis anymore.\n        XCTAssertFalse(signature.hasStoredLyricAnalysis)\n        XCTAssertFalse(signature.hasStoredSoundAnalysis)'''
if s.count(old) != 1:
    raise SystemExit(f'expected one legacy assertion, got {s.count(old)}')
p.write_text(s.replace(old, new, 1))
