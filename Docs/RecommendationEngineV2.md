# BuFi Recommendation Engine v2

## 목표

BuFi v2 추천 엔진은 서버를 교체하지 않고 OpenSubsonic/Navidrome가 제공하는
후보와 기기에서 관찰한 재생 행동을 결합한다. 추천은 다음 단계로 분리한다.

1. Candidate generation
2. 0...1 normalization
3. Purpose-aware scoring
4. Metadata/source confidence
5. Negative-preference penalty
6. Canonical deduplication
7. Discovery allocation
8. Artist/album diversity re-ranking
9. Small deterministic shuffle

`RecommendationCandidateProviding`이 후보 생성 경계다. 추후 CLAP, MERT,
Sonic 대체 엔진이나 서버 임베딩을 추가할 때 점수·다양성 코드를 변경하지
않고 provider만 추가할 수 있다.

## 입력 신호

### OpenSubsonic

- `getSonicSimilarTracks`: `sonicSimilarity` 확장을 광고하는 서버의 정규화된
  음향 유사도 후보
- `getSimilarSongs2`: 아티스트 기반 유사곡
- `getSongsByGenre`: 좋아요 장르와 서버 상위 장르 후보
- `getTopSongs`: 좋아요 아티스트 인기곡. `topSongsByArtistId` 확장이 있으면
  이름 대신 아티스트 ID를 우선 사용한다.
- `getAlbumList2`: `newest`, `highest`, `frequent`, `random`, `recent`
- `getPlaylist`: 최대 3개 플레이리스트에서 함께 등장한 횟수
- `getOpenSubsonicExtensions`: Sonic, artist-ID top songs, playback report
  기능 협상
- `reportPlayback`: 지원 서버에 시작/재생/일시정지/종료 상태 변화만 전송한다.
  주기적 폴링은 하지 않는다.

전체 홈 새로고침에서만 제한된 앨범·아티스트·플레이리스트 상세 정보를
병렬 요청한다. 증분 동기화와 저전력/고온 상태에서는 기존 캐시를 재사용해
네트워크 및 배터리 비용을 제한한다.

### 외부·로컬

- Last.fm `track.getSimilar`
- ListenBrainz collaborative-filter recommendation
- MusicBrainz ID, ISRC, artist/title/album matching confidence
- 장르(복수 장르 포함), BPM, mood, 생성 시각, 서버 play count/played
- 좋아요, 플레이리스트 추가, 직접 재생, 검색 재생, 앨범 선택, 자동 재생
- 완료율, 반복 횟수, 조기/연속 스킵, 대기열 제거

## 행동 집계

`ListeningHistoryStore`는 계정별 v2 JSON을 저장한다. 기존 v1의
`song/playCount/lastPlayed` 데이터는 최초 활성화 시 손실 없이 마이그레이션한다.

완료율:

```text
completion = clamp(playedSeconds / duration, 0, 1)
```

완료율은 0~10%, 10~40%, 40~70%, 70~90%, 90~100% 구간을 각각
0, 0.25, 0.5, 0.75, 1로 정규화한다. 반복 횟수는
`log(1 + repeatCount)`로 완화한다. 한 번의 스킵은 강한 부정 프로필로
사용하지 않고, 조기 스킵·연속 스킵·대기열 제거가 누적될 때 감점한다.

## 프로필과 시간 감쇠

- Short-term: 최근 14일
- Long-term: 최근 365일
- Daylist/autoplay: short-term 비중 70% 이상
- Taste mix: short-term 30%, long-term 70%

감쇠 기준점은 오늘 1.0, 7일 0.9, 30일 0.7, 90일 0.5,
180일 0.3, 365일 0.15이며 구간 사이를 선형 보간한다.

## 점수와 신뢰도

각 feature는 먼저 0...1로 정규화된다.

```text
normalizedWeightedScore =
    Σ(featureScore × purposePreset × userWeight)
    / Σ(purposePreset × userWeight)

confidence =
    historyConfidence
    × metadataConfidence
    × sourceConfidence

finalScore =
    normalizedWeightedScore × (0.55 + 0.45 × confidence)
    - repeatedNegativePenalty
    + smallShuffleJitter
```

외부 소스 신뢰도는 Last.fm 또는 ListenBrainz 단독 0.45, 양쪽 일치 0.75,
양쪽 일치와 좋아요 장르까지 일치하면 0.90이다. MBID/ISRC는 1.0,
artist+title은 0.95, 정규화 title은 0.85, title 단독은 0.40이다.

## 프리셋

- Home/Daylist: history 35%, favorites 20%, recent 20%, Last.fm 10%,
  ListenBrainz 10%, discovery 5%를 중심으로 행동·완료율·context 보조 신호를
  더한다.
- Artist mix: server/similar artist와 local metadata를 우선한다.
- Discovery: discovery 35%, Last.fm 25%, ListenBrainz 25%, history 15%.
- Frequent: play count 40%, completion 20%, repeat 20%, favorite 20%.
- Autoplay: 최근 20곡 context와 Sonic/similar 결과를 우선한다.

사용자의 discovery ratio는 점수 배수가 아니다. 최종 후보를 known song,
unknown song, hidden gem, new artist로 나눈 뒤 구성 비율을 결정한다.

## 중복·다양성

중복 키 우선순위는 MBID, ISRC, `normalizedArtist + canonicalTitle`이다.
canonical title은 괄호 또는 접미사의 live/remaster/deluxe/version/edit/mix를
제거해 동일 녹음의 과다 노출을 줄인다.

동일 아티스트와 앨범의 반복 계수는 첫 등장 1.0, 두 번째 0.90,
세 번째 0.75, 네 번째부터 0.55다. 상위 후보에는 30분 단위의 작은
결정적 jitter를 적용해 화면 재렌더링 때 순서가 흔들리지는 않으면서
추천이 영구히 고정되지 않게 한다.

## 캐시

- Home/Daylist/Autoplay: 30분
- Artist mix: 6시간
- Discovery: 24시간

캐시 키는 후보 ID 해시, 목적, 사용자 가중치, 행동 revision, 시간 bucket을
포함한다. 재생·스킵·좋아요·대기열 제거 등 행동이 기록되면 revision이
증가하고 메모리 캐시를 즉시 무효화한다.

## Swift 유지 결정

현재 후보 수는 수백 곡이며 병목은 네트워크와 JSON 디코딩이다. 점수 계산은
`O(n log n)`이고 한 번의 홈 갱신 또는 autoplay 보충 때만 실행된다.
Rust로 옮기면 Swift/Rust FFI, Codable 변환 복사, 별도 toolchain과
XCFramework, CI 캐시 및 iOS 27 ABI 검증 비용이 생기지만 측정 가능한 연산
이득은 거의 없다. 따라서 v2는 Swift actor와 값 타입을 유지한다.

Rust/Accelerate 전환은 로컬 audio embedding을 수만 곡 단위로 생성하거나
벡터 검색이 실제 Instruments 병목으로 확인될 때 Candidate Provider
하나로 추가한다.
