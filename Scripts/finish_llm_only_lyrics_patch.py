from pathlib import Path

path = Path("BuFi/Core/LyricIntelligence.swift")
text = path.read_text()

old = '''        case .onDevice, .applePrivateCloud:\n            result = await onDevice(lyrics: lyrics, settings: settings)\n            if result == nil {\n                result = await groqAnalysis(lyrics: lyrics, settings: settings)\n            }'''
new = '''        case .onDevice, .applePrivateCloud:\n            result = await onDevice(lyrics: lyrics, settings: settings)'''
assert text.count(old) == 1
text = text.replace(old, new, 1)

old = '''        if let validated = validatedLLMAnalysis(result) {\n            return validated\n        }\n        return await fallbackLLMAnalysis('''
new = '''        if let validated = validatedLLMAnalysis(result) {\n            return validated\n        }\n        guard settings.provider != .off else { return nil }\n        return await fallbackLLMAnalysis('''
assert text.count(old) == 1
text = text.replace(old, new, 1)

text = text.replace(
    '''        guard var analysis = await remote(''',
    '''        guard let analysis = await remote(''',
    1,
)
path.write_text(text)
