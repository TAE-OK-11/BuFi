from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"{path}: expected one match for {old[:80]!r}, got {text.count(old)}")
    file.write_text(text.replace(old, new, 1))


components = "BuFi/UI/Components.swift"
replace_once(
    components,
    "struct BuFiScreenBackground: View {",
    '''struct BuFiScreenHeader: View {
    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(BuFiTheme.accentSoft)
                    .textCase(.uppercase)
                    .tracking(1.2)
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-1.1)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [BuFiTheme.accentSoft, BuFiTheme.deezerGlow],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 48, height: 48)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
                }
        }
        .padding(.horizontal, 17)
        .accessibilityElement(children: .combine)
    }
}

struct BuFiEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(BuFiTheme.accentSoft)
                .frame(width: 62, height: 62)
                .background(BuFiTheme.elevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(title)
                .font(.system(size: 18, weight: .bold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .padding(.horizontal, 20)
    }
}

struct BuFiScreenBackground: View {'''
)

home = "BuFi/UI/HomeView.swift"
replace_once(
    home,
    '''                LazyVStack(alignment: .leading, spacing: 28) {
                    filterBar
                    filteredContent
                }
                .padding(.top, 24)
''',
    '''                LazyVStack(alignment: .leading, spacing: 24) {
                    BuFiScreenHeader(
                        eyebrow: "BuFi",
                        title: "홈",
                        subtitle: "최근 음악과 라이브러리 추천을 한곳에서 만나보세요.",
                        symbol: "waveform.path"
                    )
                    filterBar
                    filteredContent
                }
                .padding(.top, 18)
'''
)
replace_once(
    home,
    '''            .background(BuFiScreenBackground())
            .refreshable { await model.refresh() }
''',
    '''            .scrollIndicators(.hidden)
            .background(BuFiScreenBackground())
            .refreshable { await model.refresh() }
'''
)
replace_once(
    home,
    '''        // 필터가 바뀔 때 컨텐츠가 뚝 끊기지 않고 부드럽게
        // 사라졌다 나타나도록 identity 전환 + transition을 부여.
        // filterBar의 withAnimation(.interactiveSpring)이 그대로 이 전환에도 적용됨.
        .id(filter)
        .transition(
            .opacity.combined(with: .move(edge: .leading))
        )
''',
    '''        .id(filter)
        .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
        .animation(BuFiMotion.selection, value: filter)
'''
)

search = "BuFi/UI/SearchView.swift"
replace_once(
    search,
    '''                LazyVStack(alignment: .leading, spacing: 14) {
                    searchField
''',
    '''                LazyVStack(alignment: .leading, spacing: 16) {
                    BuFiScreenHeader(
                        eyebrow: "Discover",
                        title: "검색",
                        subtitle: "앨범, 아티스트, 플레이리스트와 좋아요 음악을 빠르게 찾아보세요.",
                        symbol: "sparkle.magnifyingglass"
                    )
                    searchField
'''
)
replace_once(
    search,
    '''            .scrollDismissesKeyboard(.interactively)
            .background(BuFiScreenBackground())
''',
    '''            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .background(BuFiScreenBackground())
'''
)
replace_once(search, '.animation(.easeOut(duration: 0.22), value: focused)', '.animation(BuFiMotion.selection, value: focused)')
replace_once(search, 'withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.82)) {', 'withAnimation(BuFiMotion.page) {')
replace_once(
    search,
    '''            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("검색어를 입력하세요")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 54)
''',
    '''            BuFiEmptyState(
                title: "검색어를 입력하세요",
                message: "띄어쓰기와 대소문자를 자연스럽게 처리해 가장 가까운 결과를 보여드려요.",
                symbol: "magnifyingglass"
            )
'''
)

library = "BuFi/UI/LibraryView.swift"
replace_once(
    library,
    '''                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    filters
                    content
                }
                .padding(.top, 18)
''',
    '''                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    BuFiScreenHeader(
                        eyebrow: "Collection",
                        title: "내 라이브러리",
                        subtitle: "저장한 음악을 플레이리스트, 앨범, 아티스트와 곡으로 정리했어요.",
                        symbol: "rectangle.stack.fill"
                    )
                    filters
                    content
                        .id(filter)
                        .transition(.opacity.combined(with: .scale(scale: 0.99, anchor: .top)))
                }
                .padding(.top, 18)
                .animation(BuFiMotion.selection, value: filter)
'''
)
replace_once(
    library,
    '''            .background(BuFiScreenBackground())
            .refreshable { await model.refresh() }
''',
    '''            .scrollIndicators(.hidden)
            .background(BuFiScreenBackground())
            .refreshable { await model.refresh() }
'''
)
replace_once(
    library,
    '''        .padding(.horizontal, 17)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
''',
    '''        .padding(.horizontal, 17)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 8)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
'''
)
