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
9. Purpose-lifetime deterministic jitter

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
unknown song, hidden gem, new artist로 나눈 뒤 구성 비율을 결정한다. 비율은
모든 purpose에서 `0...1`을 그대로 사용한다. Discovery purpose도 최소값을
강제하지 않으므로 0은 가능한 한 known song만, 1은 가능한 한 unknown song만
선택하며, 한쪽 후보가 부족할 때만 반대쪽 후보로 제한 개수를 채운다.

## 중복·다양성

중복 키 우선순위는 MBID, ISRC, `normalizedArtist + canonicalTitle`이다.
canonical title은 괄호 또는 접미사의 live/remaster/deluxe/version/edit/mix를
제거해 동일 녹음의 과다 노출을 줄인다.

동일 아티스트와 앨범의 반복 계수는 첫 등장 1.0, 두 번째 0.90,
세 번째 0.75, 네 번째부터 0.55다. 상위 후보에는 작은 결정적 jitter를
적용한다. jitter seed는 아래 목적별 캐시 lifetime과
같은 시간 bucket을 사용하므로 장기 캐시 목적이 30분마다 무효화되지 않는다.

점수 합산은 enum에 선언된 고정 feature 순서로 수행한다. 행동 dictionary는
song ID, 마지막 재생 시각 순으로 정렬한 뒤 프로필을 만들고, 정규화 map의
key도 정렬한다. 따라서 Swift dictionary의 임의 순회 순서나 프로세스별 hash
seed가 부동소수점 누적 순서와 최종 순위를 바꾸지 않는다. 문자열 정규화에는
고정 POSIX locale을 사용한다.

## 캐시

- Home/Daylist/Taste/Frequent/Autoplay: 30분
- Artist mix: 6시간
- Discovery: 24시간
- SwiftUI의 개인화 믹스: 동일한 전체 스냅샷·선택 아티스트·날짜 구간은
  직전 결과를 재사용한다.

캐시 키는 실제 후보 목록별 경계와 순서, 결과 또는 점수에 영향을 줄 수 있는
`Song`의 전체 metadata, 행동 snapshot의 전체 집계값과 recent-song 순서,
목적, limit, 정확한 IEEE-754 사용자 가중치, calendar/time-zone, 목적별 시간
bucket을 포함한다. 따라서 동일 ID의 title, favorite, cover art, play count,
BPM, mood, genre, MBID/ISRC 등이 바뀌어도 오래된 `Song` 값이나 점수를
재사용하지 않는다. 0.001보다 작은 가중치 변경도 별도 항목이다.

재생·스킵·좋아요·대기열 제거 등 행동이 기록되면 revision이 증가해 기존
entry와 분리된다. revision이 잘못 재사용되더라도 전체 행동 fingerprint가
달라지면 캐시는 분리된다. 캐시 lifetime과 jitter bucket은 같은
purpose-specific 값을 사용한다.
시간 감쇠와 time-awareness도 해당 bucket 시작 시각을 평가 기준으로 사용해,
같은 cache key를 eviction 후 다시 계산해도 동일한 순위를 만든다.

## 계산 비용과 취소

개인화 믹스는 한 snapshot에서 deduplicated song corpus를 한 번 만들고,
searchable text, normalized artist/genre, artist별 곡, genre별 곡을 함께
indexing한다. 아티스트 믹스마다 전체 후보 풀을 다시 스캔하지 않고 이 index로
primary/related 후보를 구성한다. 각 믹스에 필요한 deterministic order는 전체
풀을 매번 정렬하지 않고 최대 `limit` 또는 fallback용 `2 × limit` 항목만
유지하는 bounded max-heap으로 구한다. 이 방식은 기존 stable-hash 순서의
prefix와 동등하면서 임시 메모리를 후보 수가 아닌 출력 제한에 맞춘다.
Discovery allocation도 한 번의 partition pass에서 known/unknown 배열을 만든다.

fingerprint 생성, rank map 생성, profile 집계, candidate scoring, discovery
partition, diversity reranking, personalized corpus/ordering의 긴 loop는 주기적으로
`Task.isCancelled`를 확인한다. 취소를 관찰하면 부분 결과를 cache/publish하지
않고 빈 결과로 종료한다.

## Swift 유지 결정

현재 후보 수는 수백 곡이며 병목은 네트워크와 JSON 디코딩이다. 점수 계산은
`O(n log n)`이고 한 번의 홈 갱신 또는 autoplay 보충 때만 실행된다.
Rust로 옮기면 Swift/Rust FFI, Codable 변환 복사, 별도 toolchain과
XCFramework, CI 캐시 및 iOS 27 ABI 검증 비용이 생기지만 측정 가능한 연산
이득은 거의 없다. 따라서 v2는 Swift actor와 값 타입을 유지한다.

Rust/Accelerate 전환은 로컬 audio embedding을 수만 곡 단위로 생성하거나
벡터 검색이 실제 Instruments 병목으로 확인될 때 Candidate Provider
하나로 추가한다.
