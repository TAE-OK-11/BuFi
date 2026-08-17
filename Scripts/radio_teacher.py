#!/usr/bin/env python3
"""Shared parser for the Spotify radio-teacher captures.

The source pages mix explicit seeds, repeated `세트 N` groups, long ranked
recommendation runs, and screenshot-derived `첫 번째 재생 곡` headings. Keep
those boundaries intact so Create ML sees independent radio sessions instead
of one giant popularity list.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import re
import unicodedata
import urllib.request

PAGES = [
    "3bef030e-09cf-8010-a650-f4b906e8e91f",
    "3bef030e-09cf-8004-968b-e79de61a4528",
]

# These are the top-level seed headings in page order. A seed title can also
# appear later as a recommendation (for example Style), so title membership
# alone is not enough to start a new teacher block.
EXPECTED_SEEDS_BY_PAGE = [
    ["style", "cruel summer", "hey! hey!", "blue valentine"],
    [
        "karma",
        "so high school",
        "anti-hero",
        "the one that got away",
        "dance the night away",
        "ode to love",
    ],
]
PAGE_MARKER = "__BUFI_TEACHER_PAGE__"

SET_RE = re.compile(r"^세트\s*\d+\s*$", re.IGNORECASE)
PLAYBACK_RE = re.compile(
    r"(?:첫\s*번째|두\s*번째|세\s*번째)\s*재생\s*곡\s*:\s*"
    r"['‘’\"]?(.+?)['‘’\"]?\s*\((.+?)\)\s*$",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class TeacherTrack:
    title: str
    artist: str


@dataclass(frozen=True)
class ParsedLine:
    track: TeacherTrack
    explicit_seed: bool


# These three sequences are present in the first Notion page as screenshot-
# derived "재생 곡" sections. Notion's public loadPageChunk endpoint currently
# omits those blocks even though the connected Notion API exposes them. Keep a
# reviewed snapshot so CI and local training do not silently lose this teacher
# evidence when the public endpoint is incomplete. If the live parser starts
# returning a seed later, de-duplication below prevents a second copy.
STATIC_PLAYBACK_BLOCKS: list[list[TeacherTrack]] = [
    [
        TeacherTrack("갑자기", "아이오아이"),
        TeacherTrack("Crow", "i-dle"),
        TeacherTrack("Runaway", "RESCENE"),
        TeacherTrack("Ever2Late!", "KiiiKiii"),
        TeacherTrack("Roller Coaster", "청하"),
        TeacherTrack("ICONIC HEART", "Hearts2Hearts"),
        TeacherTrack("4 Flowers", "마마무"),
        TeacherTrack("IOI (Where My Girls At)", "아이오아이"),
        TeacherTrack("Pretty Girl", "RESCENE"),
        TeacherTrack("Drowning", "WOODZ"),
        TeacherTrack("number one rockstar", "DAYOUNG"),
        TeacherTrack("Lemon Tang", "Hearts2Hearts"),
        TeacherTrack("만찬가", "태연"),
        TeacherTrack("Less than a Lover", "제니"),
        TeacherTrack("사랑해 기억해", "아이오아이"),
        TeacherTrack("I Don't Care", "2NE1"),
        TeacherTrack("상상더하기", "라붐"),
        TeacherTrack("숲의 아이 (Bon voyage)", "유아"),
        TeacherTrack("MUSEUM", "OWIS"),
        TeacherTrack("METRONOME", "izna"),
        TeacherTrack("다섯 번째 계절 (SSFWL)", "오마이걸"),
        TeacherTrack("같은 곳에서", "소녀온탑"),
        TeacherTrack("Candy Pink Magic Hole Flip Phone", "KiiiKiii"),
        TeacherTrack("No.1", "보아"),
        TeacherTrack("LOVING U (러빙유)", "씨스타"),
        TeacherTrack("Cosmic", "Red Velvet"),
        TeacherTrack("After School", "Weeekly"),
        TeacherTrack("사랑의 배터리", "홍진영"),
        TeacherTrack("비밀정원", "오마이걸"),
        TeacherTrack("LOUD", "NMIXX"),
        TeacherTrack("사랑해", "Trisha Paytas"),
        TeacherTrack("Motto", "ITZY"),
        TeacherTrack("LEMONADE", "aespa"),
        TeacherTrack("Pop Off Pop Off", "KiiiKiii"),
        TeacherTrack("CELEBRATION", "LE SSERAFIM"),
        TeacherTrack("SWEAT", "KISS OF LIFE"),
        TeacherTrack("Do your dance", "RIIZE"),
    ],
    [
        TeacherTrack("LOVE ATTACK", "RESCENE"),
        TeacherTrack("Runaway", "RESCENE"),
        TeacherTrack("Pop Off Pop Off", "KiiiKiii"),
        TeacherTrack("상상더하기", "라붐"),
        TeacherTrack("Roller Coaster", "청하"),
        TeacherTrack("Lemon Tang", "Hearts2Hearts"),
        TeacherTrack("Pretty Girl", "RESCENE"),
        TeacherTrack("4 Flowers", "마마무"),
        TeacherTrack("Ever2Late!", "KiiiKiii"),
        TeacherTrack("사건의 지평선", "윤하"),
        TeacherTrack("IOI (Where My Girls At)", "아이오아이"),
        TeacherTrack("Deja Vu", "RESCENE"),
        TeacherTrack("ICONIC HEART", "Hearts2Hearts"),
        TeacherTrack("만찬가", "태연"),
        TeacherTrack("Hype Boy", "NewJeans"),
        TeacherTrack("LOUD", "NMIXX"),
        TeacherTrack("LUV", "Apink"),
        TeacherTrack("MUSEUM", "OWIS"),
        TeacherTrack("Glow Up", "RESCENE"),
        TeacherTrack("캐치 캐치", "YENA"),
        TeacherTrack("내 마음 한 조각", "AtHeart"),
        TeacherTrack("Underwater", "KWON EUNBI"),
        TeacherTrack("Bubble", "STAYC"),
        TeacherTrack("FOCUS", "Hearts2Hearts"),
        TeacherTrack("Candy Pink Magic Hole Flip Phone", "KiiiKiii"),
        TeacherTrack("SMILEY (Feat. BIBI)", "YENA, 비비"),
        TeacherTrack("Ah-Choo", "러블리즈"),
        TeacherTrack("나랑 사귈래", "DIA"),
        TeacherTrack("No Tears On The Dancefloor", "이채연"),
        TeacherTrack("STYLE", "Hearts2Hearts"),
    ],
    [
        TeacherTrack("LEMONADE", "aespa"),
        TeacherTrack("CELEBRATION", "LE SSERAFIM"),
        TeacherTrack("KISS N TELL", "aespa"),
        TeacherTrack("Motto", "ITZY"),
        TeacherTrack("SWEAT", "KISS OF LIFE"),
        TeacherTrack("Pop Off Pop Off", "KiiiKiii"),
        TeacherTrack("MOTION (feat. Juicy J)", "CORTIS, Juicy J"),
        TeacherTrack("WDA (Whole Different Animal)", "aespa, G-DRAGON"),
        TeacherTrack("Do your dance", "RIIZE"),
        TeacherTrack("Lemon Tang", "Hearts2Hearts"),
        TeacherTrack("ddok ddok ddok", "BOYNEXTDOOR"),
        TeacherTrack("Ever2Late!", "KiiiKiii"),
        TeacherTrack("Serenade (KARINA & WINTER)", "aespa"),
        TeacherTrack("Crow", "i-dle"),
        TeacherTrack("Runaway", "RESCENE"),
        TeacherTrack("ICONIC HEART", "Hearts2Hearts"),
        TeacherTrack("SWIM", "방탄소년단"),
        TeacherTrack("Whiplash", "aespa"),
        TeacherTrack("4 Flowers", "마마무"),
        TeacherTrack("Good Thing", "i-dle"),
        TeacherTrack("XOXZ", "IVE"),
        TeacherTrack("HYPNOTIZE", "XG"),
        TeacherTrack("GO!", "CORTIS"),
        TeacherTrack("Hey Hi", "KiiiKiii"),
        TeacherTrack("Cosmic", "Red Velvet"),
        TeacherTrack("LOUD", "NMIXX"),
        TeacherTrack("Hold On Tight", "aespa"),
        TeacherTrack("SOMETHING AIN'T RIGHT", "XG"),
        TeacherTrack("IOI (Where My Girls At)", "아이오아이"),
        TeacherTrack("Candy Pink Magic Hole Flip Phone", "KiiiKiii"),
        TeacherTrack("만찬가", "태연"),
        TeacherTrack("Switchblade (feat. Ty Dolla $ign)", "aespa, Ty Dolla $ign"),
        TeacherTrack("YOUNGCREATORCREW", "CORTIS"),
        TeacherTrack("Less than a Lover", "제니"),
        TeacherTrack("MAGO", "여자친구"),
        TeacherTrack("SWEET SOUR", "KiiiKiii"),
        TeacherTrack("Armageddon", "aespa"),
    ],
]

# Manually captured Spotify runs supplied after the public third Notion page
# failed to expose its blocks through loadPageChunk. The first four headings are
# new seeds. Ode to Love is an additional run for the already-known seed, so it
# intentionally remains a separate sequence instead of being merged by title.
MANUAL_SEQUENCE_BLOCKS: list[list[TeacherTrack]] = [
    [
        TeacherTrack("Vitamin ME", "프로미스나인"),
        TeacherTrack("잔혹한 천사의 테제", "HANRORO"),
        TeacherTrack("Ever2Late!", "KiiiKiii"),
        TeacherTrack("Lemon Tang", "Hearts2Hearts"),
        TeacherTrack("4 Flowers", "마마무"),
        TeacherTrack("LOVE BOMB", "프로미스나인"),
        TeacherTrack("만찬가", "태연"),
        TeacherTrack("상상더하기", "라붐"),
        TeacherTrack("Hey Hi", "KiiiKiii"),
        TeacherTrack("갑자기", "아이오아이"),
        TeacherTrack("LIKE YOU BETTER", "프로미스나인"),
        TeacherTrack("SMILEY (Feat. BIBI)", "YENA, 비비"),
        TeacherTrack("Pretty Girl", "카라"),
        TeacherTrack("FOCUS", "Hearts2Hearts"),
        TeacherTrack("Candy Pink Magic Hole Flip Phone", "KiiiKiii"),
        TeacherTrack("WE GO", "프로미스나인"),
        TeacherTrack("Say It", "AtHeart"),
        TeacherTrack("캐치 캐치", "YENA"),
        TeacherTrack("Deja Vu", "RESCENE"),
        TeacherTrack("Underwater", "KWON EUNBI"),
        TeacherTrack("유리구두", "프로미스나인"),
        TeacherTrack("MUSEUM", "OWIS"),
        TeacherTrack("내 마음 한 조각", "AtHeart"),
        TeacherTrack("SWEET SOUR", "KiiiKiii"),
        TeacherTrack("101 (Where My Girls At)", "AtHeart"),
        TeacherTrack("You, You", "투어스"),
        TeacherTrack("SIGN", "izna"),
        TeacherTrack("Bittersweet", "Baby DONT Cry"),
        TeacherTrack("Talk & Talk", "프로미스나인"),
        TeacherTrack("LOVE ATTACK", "RESCENE"),
        TeacherTrack("No Tears On The Dancefloor", "이채연"),
        TeacherTrack("Surfin' Boy", "Red Velvet"),
        TeacherTrack("SODA SODA", "투어스"),
    ],
    [
        TeacherTrack("MANIAC", "VIVIZ"),
        TeacherTrack("After School", "Weeekly"),
        TeacherTrack("HOT", "LE SSERAFIM"),
        TeacherTrack("Cosmic", "Red Velvet"),
        TeacherTrack("다시 만난 세계 (Into The New World)", "소녀시대"),
        TeacherTrack("Cheshire", "ITZY"),
        TeacherTrack("Underwater", "KWON EUNBI"),
        TeacherTrack("BOP BOP!", "VIVIZ"),
        TeacherTrack("EASY", "LE SSERAFIM"),
        TeacherTrack("Bubble", "STAYC"),
        TeacherTrack("마지막처럼", "BLACKPINK"),
        TeacherTrack("DUMB DUMB", "전소미"),
        TeacherTrack("Dun Dun Dance", "오마이걸"),
        TeacherTrack("Imaginary Friend", "ITZY"),
        TeacherTrack("UNFORGIVEN (feat. Nile Rodgers)", "LE SSERAFIM, Nile Rodgers"),
        TeacherTrack("Don't", "이채연"),
    ],
    [
        TeacherTrack("Feel My Rhythm", "Red Velvet"),
        TeacherTrack("러시안 룰렛 (Russian Roulette)", "Red Velvet"),
        TeacherTrack("SUN", "TeenageGirls"),
        TeacherTrack("HOT", "LE SSERAFIM"),
        TeacherTrack("NEKKOYA (PICK ME)", "PRODUCE 48"),
        TeacherTrack("After School", "Weeekly"),
        TeacherTrack("Cosmic", "Red Velvet"),
        TeacherTrack("상상더하기", "라붐"),
        TeacherTrack("Cheshire", "ITZY"),
        TeacherTrack("LOVE BOMB", "프로미스나인"),
        TeacherTrack("Close To Me - Red Velvet Remix", "Ellie Goulding, Diplo, Red Velvet"),
        TeacherTrack("빨간 맛 (Red Flavor)", "Red Velvet"),
        TeacherTrack("If I'm S, Can You Be My N?", "투어스"),
        TeacherTrack("No Celestial", "LE SSERAFIM"),
        TeacherTrack("마지막처럼", "BLACKPINK"),
        TeacherTrack("왜요 왜요", "샤넌"),
        TeacherTrack("Psycho", "Red Velvet"),
        TeacherTrack("Bubble", "STAYC"),
        TeacherTrack("Underwater", "KWON EUNBI"),
        TeacherTrack("ANTIFRAGILE", "LE SSERAFIM"),
        TeacherTrack("Lion Heart", "소녀시대"),
        TeacherTrack("Bad Boy", "Red Velvet"),
        TeacherTrack("Hype Boy", "NewJeans"),
    ],
    [
        TeacherTrack("Feel Special", "TWICE"),
        TeacherTrack("FANCY", "TWICE"),
        TeacherTrack("HOT", "LE SSERAFIM"),
        TeacherTrack("Cosmic", "Red Velvet"),
        TeacherTrack("Whiplash", "aespa"),
        TeacherTrack("NEKKOYA (PICK ME)", "PRODUCE 48"),
        TeacherTrack("YES or YES", "TWICE"),
        TeacherTrack("After School", "Weeekly"),
        TeacherTrack("If I'm S, Can You Be My N?", "투어스"),
        TeacherTrack("Deja Vu", "RESCENE"),
        TeacherTrack("마지막처럼", "BLACKPINK"),
        TeacherTrack("TT", "TWICE"),
        TeacherTrack("Cheshire", "ITZY"),
        TeacherTrack("UNFORGIVEN (feat. Nile Rodgers)", "LE SSERAFIM, Nile Rodgers"),
        TeacherTrack("캐치 캐치", "YENA"),
        TeacherTrack("LOVE BOMB", "프로미스나인"),
    ],
    [
        TeacherTrack("Ode to Love", "NCT WISH"),
        TeacherTrack("Lucky to be loved", "투어스"),
        TeacherTrack("YOUNGCREATORCREW", "CORTIS"),
        TeacherTrack("Ever2Late!", "KiiiKiii"),
        TeacherTrack("Lemon Tang", "Hearts2Hearts"),
        TeacherTrack("ddok ddok ddok", "BOYNEXTDOOR"),
        TeacherTrack("BOY MEETS GIRL", "NCT WISH"),
        TeacherTrack("If I'm S, Can You Be My N?", "투어스"),
        TeacherTrack("TNT", "CORTIS"),
        TeacherTrack("LOUD", "NMIXX"),
        TeacherTrack("Hype Boy", "NewJeans"),
        TeacherTrack("Surf", "NCT WISH"),
        TeacherTrack("FOCUS", "Hearts2Hearts"),
        TeacherTrack("You, You", "투어스"),
        TeacherTrack("SWEET SOUR", "KiiiKiii"),
        TeacherTrack("JoyRide", "CORTIS"),
        TeacherTrack("poppop", "NCT WISH"),
        TeacherTrack("101 (Where My Girls At)", "아이오아이"),
        TeacherTrack("Deja Vu", "RESCENE"),
        TeacherTrack("Here For You", "투어스"),
        TeacherTrack("iffy iffy", "LE SSERAFIM"),
        TeacherTrack("프린스핑송", "NCT WISH"),
        TeacherTrack("Surfin' Boy", "Red Velvet"),
        TeacherTrack("MUSEUM", "OWIS"),
        TeacherTrack("body", "DAYOUNG"),
        TeacherTrack("hey! hey!", "투어스"),
        TeacherTrack("COLOR", "NCT WISH"),
        TeacherTrack("갑자기", "아이오아이"),
        TeacherTrack("Heavy Serenade", "NMIXX"),
        TeacherTrack("Shut The Door", "Young K"),
        TeacherTrack("그곳에서 다시 만나기로 해 (Rendezvous)", "AHOF"),
    ],
]


def normalize(text: str) -> str:
    value = unicodedata.normalize("NFKC", text or "").lower()
    value = re.sub(r"\(.*?\)", "", value)
    return re.sub(r"[^0-9a-z가-힣]+", "", value)


def item_key(title: str, artist: str) -> str:
    # Keep this identical to RadioCoreMLTransition.normalize: parenthetical
    # text is removed but every non-parenthetical artist token is retained.
    return f"{normalize(title)}|{normalize(artist)}"


def clean_line(raw: str) -> str:
    text = (raw or "").replace("\u2060", "").strip()
    text = text.replace("<br>", "").replace("<br/>", "")
    text = text.replace("\\[", "").replace("\\]", "")
    text = text.replace("**", "")
    text = re.sub(r"^[-•]\s*", "", text)
    return re.sub(r"\s+", " ", text).strip()


def is_set_marker(raw: str) -> bool:
    return SET_RE.match(clean_line(raw)) is not None


def parse_line(raw: str) -> ParsedLine | None:
    text = clean_line(raw)
    if not text or is_set_marker(text) or text.startswith(PAGE_MARKER):
        return None
    if any(
        marker in text
        for marker in (
            "스크린샷",
            "전체 목록",
            "복사하여",
            "화면 흐름",
            "서브 그룹",
            "맨 처음 올려",
        )
    ):
        return None

    playback = PLAYBACK_RE.search(text)
    if playback:
        return ParsedLine(
            TeacherTrack(playback.group(1).strip(), playback.group(2).strip()),
            True,
        )

    explicit_seed = "시드:" in text
    text = re.sub(r"^\d+\.\s*", "", text).strip()
    text = re.sub(r"^시드\s*:\s*", "", text, flags=re.IGNORECASE).strip()

    recommendation_heading = "추천 트랙" in text
    if recommendation_heading:
        text = re.sub(r"\s*추천 트랙.*$", "", text).strip()

    if " - " not in text:
        return None
    title, artist = text.rsplit(" - ", 1)
    title = title.strip(" \t'‘’\"")
    artist = artist.strip(" \t'‘’\"")
    if not title or not artist:
        return None

    return ParsedLine(
        TeacherTrack(title, artist),
        explicit_seed or recommendation_heading,
    )


def teacher_blocks(lines: list[str]) -> list[list[TeacherTrack]]:
    blocks: list[list[TeacherTrack]] = []
    seed: TeacherTrack | None = None
    current: list[TeacherTrack] = []
    page_index = -1
    expected_index = 0

    def flush() -> None:
        nonlocal current
        if seed is not None and len(current) >= 3:
            # Preserve order but remove exact repeated recordings inside a set.
            unique: list[TeacherTrack] = []
            seen: set[str] = set()
            for track in current:
                key = item_key(track.title, track.artist)
                if key in seen:
                    continue
                seen.add(key)
                unique.append(track)
            if len(unique) >= 3:
                blocks.append(unique)
        current = []

    def expected_seed(track: TeacherTrack) -> bool:
        nonlocal expected_index
        if page_index < 0 or page_index >= len(EXPECTED_SEEDS_BY_PAGE):
            return False
        expected = EXPECTED_SEEDS_BY_PAGE[page_index]
        if expected_index >= len(expected):
            return False
        title_key = normalize(track.title)
        wanted = normalize(expected[expected_index])
        if title_key != wanted:
            return False
        expected_index += 1
        return True

    def advance_expected_for_explicit(track: TeacherTrack) -> None:
        nonlocal expected_index
        if page_index < 0 or page_index >= len(EXPECTED_SEEDS_BY_PAGE):
            return
        expected = EXPECTED_SEEDS_BY_PAGE[page_index]
        title_key = normalize(track.title)
        for index in range(expected_index, len(expected)):
            if normalize(expected[index]) == title_key:
                expected_index = index + 1
                return

    for raw in lines:
        clean = clean_line(raw)
        if clean.startswith(PAGE_MARKER):
            flush()
            seed = None
            current = []
            try:
                page_index = int(clean.split(":", 1)[1])
            except (IndexError, ValueError):
                page_index += 1
            expected_index = 0
            continue

        if is_set_marker(raw):
            flush()
            if seed is not None:
                current = [seed]
            continue

        parsed = parse_line(raw)
        if parsed is None:
            continue

        starts_seed = parsed.explicit_seed or expected_seed(parsed.track)
        if starts_seed:
            flush()
            seed = parsed.track
            current = [seed]
            if parsed.explicit_seed:
                advance_expected_for_explicit(parsed.track)
            continue

        if seed is not None:
            current.append(parsed.track)

    flush()

    live_seed_keys = {item_key(block[0].title, block[0].artist) for block in blocks if block}
    for static_block in STATIC_PLAYBACK_BLOCKS:
        static_seed = item_key(static_block[0].title, static_block[0].artist)
        if static_seed not in live_seed_keys:
            blocks.append(static_block)
            live_seed_keys.add(static_seed)

    # Manual runs are observations, not fallback seeds. Keep multiple runs for
    # the same seed (notably Ode to Love), while preventing an exact duplicate
    # if the public third page starts exposing the same capture later.
    block_signatures = {
        tuple(item_key(track.title, track.artist) for track in block)
        for block in blocks
    }
    for manual_block in MANUAL_SEQUENCE_BLOCKS:
        signature = tuple(item_key(track.title, track.artist) for track in manual_block)
        if signature not in block_signatures:
            blocks.append(manual_block)
            block_signatures.add(signature)
    return blocks


def fetch_lines() -> list[str]:
    """Read the public Notion pages using the same endpoint as the old exporter."""
    url = "https://www.notion.so/api/v3/loadPageChunk"
    lines: list[str] = []

    def post(payload: dict) -> dict:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())

    def plain(prop) -> str:
        if not prop:
            return ""
        return "".join(str(run[0]) for run in prop if isinstance(run, list) and run)

    for page_index, page in enumerate(PAGES):
        lines.append(f"{PAGE_MARKER}:{page_index}")
        blocks: dict = {}
        cursor: list = []
        chunk = 0
        while True:
            data = post(
                {
                    "page": {"id": page},
                    "limit": 100,
                    "cursor": {"stack": cursor},
                    "chunkNumber": chunk,
                    "verticalColumns": False,
                }
            )
            blocks.update(data.get("recordMap", {}).get("block", {}))
            cursor = data.get("cursor", {}).get("stack", [])
            chunk += 1
            if not cursor or chunk > 60:
                break

        def walk(block_id: str) -> None:
            rec = blocks.get(block_id, {})
            value = rec.get("value", {}).get("value", rec.get("value", {})) or {}
            title = plain((value.get("properties") or {}).get("title"))
            for piece in title.splitlines():
                if piece.strip():
                    lines.append(piece.strip())
            for child in value.get("content") or []:
                walk(child)

        walk(page)
    return lines
