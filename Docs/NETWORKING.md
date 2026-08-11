# BuFi networking policy

BuFi uses Apple's URL Loading System and AVFoundation rather than embedding a
third-party QUIC stack. This keeps transport security, connection migration,
radio scheduling, and background behavior integrated with iOS.

## Enabled transport behavior

- API, artwork, and offline-download URL requests set `assumesHTTP3Capable` so
  CFNetwork races QUIC immediately without waiting for a previous Alt-Svc
  discovery. HTTP/2 remains the automatic fallback.
- Last.fm and ListenBrainz recommendation requests use the same HTTP/3-first,
  HTTPS-only redirect, connection-reuse, and cache policy as first-party JSON.
  They advertise zstd for JSON responses, decode it through the same bounded
  decoder, and retry once without zstd when an origin or intermediary returns
  an invalid zstd body.
- TLS 1.3 is negotiated automatically when the origin supports it. App Transport
  Security and the HTTPS-only redirect delegate keep cleartext and downgrade
  redirects out of authenticated traffic.
- OpenSubsonic JSON requests advertise `zstd, br, gzip` in that order. BuFi has a
  bounded zstd decoder and retries with `br, gzip` if a server returns malformed
  or unsupported zstd content.
- Artwork requests use HTTP/3 racing and the system Brotli/gzip decoder. Nuke's
  URLSession forwards redirects and metrics through BuFi's HTTPS-only delegate,
  so CDN redirects retain the transport policy without permitting a cleartext
  downgrade. zstd is not advertised because those bytes do not pass through
  BuFi's custom decoder.
- Offline media downloads use HTTP/3 racing but explicitly request `identity`
  content coding. Audio is already compressed, and preserving byte identity is
  necessary for reliable range requests, seeking, and resume offsets.
- Active AVPlayer streams continue to request byte-identical compressed audio;
  applying HTTP content compression to AAC, MP3, Opus, or FLAC would add CPU
  cost while breaking reliable range/seek semantics. BuFi instead reacts to
  path loss and restoration, gives the active stream priority over prefetch,
  and moves to a bandwidth-bounded compatibility format after bounded
  same-format transport retries.
- Cookies, ambient credential storage, and URLSession response caches are
  disabled for authenticated API and download sessions. BuFi's own scoped image
  and offline caches remain in control.
- Identical OpenSubsonic requests share one in-flight transfer. A 16 MiB bounded
  actor-local response cache absorbs overlapping view/recommendation bursts,
  while mutation and playback-report endpoints always bypass it. Successful
  mutations immediately invalidate cached read responses for the account, and
  only payloads that decode successfully enter the cache.
- Structured lyrics are retained for up to six hours and the next two queued
  tracks have lyrics, 360 px artwork, authenticated stream URLs, and reusable
  `AVURLAsset` metadata warmed only after the current item reaches the playing
  state. A manual skip consumes the same partially or fully prepared asset while
  the page animation runs instead of opening a duplicate request. Buffering,
  pause, constrained/expensive paths, Low Power Mode, serious thermal pressure,
  logout, and memory warnings cancel or trim speculative work immediately.
- HTTP/1.1 pipelining is enabled only as a legacy fallback optimization; modern
  HTTP/2 and HTTP/3 paths continue to use native stream multiplexing.

HTTP/3 is opportunistic: the origin, proxy, network path, and current iOS
transport policy must all permit QUIC. A failed or unavailable QUIC attempt falls
back to the system HTTP/2 or HTTP/1.1 path without changing OpenSubsonic behavior.
Debug builds log the final `URLSessionTaskMetrics.networkProtocolName` and
connection-reuse flag by host so supported origins can be verified as `h3`
without retaining metrics or emitting transport logs in release builds.

## System-managed features

AVPlayer/AVURLAsset does not expose the `assumesHTTP3Capable` switch. Streaming
therefore negotiates HTTP/3 through the server's Alt-Svc advertisement and the
system connection cache, with HTTP/2 fallback. QUIC 0-RTT, ECH, congestion
control, and TLS session resumption are also selected by CFNetwork and the OS;
there is no supported application flag to force them.
