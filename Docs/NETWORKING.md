# BuFi networking policy

BuFi uses Apple's URL Loading System and AVFoundation rather than embedding a
third-party QUIC stack. This keeps transport security, connection migration,
radio scheduling, and background behavior integrated with iOS.

## Enabled transport behavior

- API, artwork, analysis, and offline requests leave HTTP/3 discovery to
  CFNetwork. `assumesHTTP3Capable` is not forced because a user-configured
  OpenSubsonic endpoint is not known in advance to support HTTP/3; the property
  is intended only for known-capable endpoints and otherwise starts an
  unnecessary QUIC race. HTTP/3 remains available through normal DNS/Alt-Svc
  discovery, with system-managed HTTP/2 and HTTP/1.1 fallback.
- Last.fm and ListenBrainz follow the same system discovery policy.
  Public metadata may use the small protocol cache; requests carrying an API key
  or token stay on the ephemeral no-cache path. The public request policy keeps
  `useProtocolCachePolicy` intact so the configured memory cache is actually
  reachable, while zstd compatibility retries always bypass it. Transient
  transport failures, 408/425/429, and selected temporary 5xx statuses use the
  same bounded retry policy as first-party reads, including a capped
  `Retry-After` delay.
- TLS is negotiated by the system. App Transport Security and the HTTPS-only
  redirect delegate reject cleartext downgrade redirects. TLS/certificate
  failures are terminal instead of being hidden behind repeated retries.
- OpenSubsonic JSON requests advertise `zstd, br, gzip`. BuFi's zstd decoder is
  bounded to 64 MiB, uses a known frame content size for preallocation when
  available, rejects known oversized frames before decompression, and falls back
  to `br, gzip` when zstd negotiation or decoding is incompatible.
- Artwork requests use the system HTTP negotiation and Brotli/gzip decoder. Nuke forwards
  redirect handling through BuFi's HTTPS-only delegate. zstd is not advertised
  for image requests because those bytes do not pass through BuFi's zstd decoder.
- Offline media downloads and audio-analysis range samples explicitly request
  `identity` content coding and use background network service priority. Audio is
  already compressed, and byte identity keeps range/seek offsets deterministic.
  Offline media is serialized per origin so a bulk album download cannot
  saturate the same server path used by active playback.
- Active AVPlayer streams use byte-identical compressed audio. AVPlayer owns its
  transport connection and forward-buffer duration. BuFi uses AVPlayer's default
  system-managed buffer (`preferredForwardBufferDuration == 0`), starts with
  `play()` while automatic stall minimization is enabled, and never reloads or
  seeks an item during AVFoundation's buffering-rate/stall-minimization waits.
  BuFi observes those states only for UI and prefetch cancellation. Explicit
  item/transport failures retain bounded same-format recovery before a compatible
  transcoded format may be tried.
- A new play command prepares AVAudioSession alongside URL/asset resolution.
  Canonical metadata, lyrics, and lock-screen artwork wait until AVPlayer reports
  actual playback, so they cannot race the first audio connection. Optional
  next-track and offline work receives an additional stable-playback window.
- Remote high-bitrate lossless playback does not overlap the active stream with
  successor warmup, upcoming artwork/lyrics prefetch, or offline downloads. This
  preserves bandwidth and decoder headroom for ALAC and reduces radio/CPU work.
  For other codecs, speculative prefetch begins only after AVPlayer reaches the
  playing state and is cancelled again whenever playback starts waiting.
  Local lossless files retain the gapless preparation path because they do not
  compete for the network. AAC (whether encoded by Apple or FDK-AAC) continues
  through the same native Apple decode path.
  OpenSubsonic bitrate/depth/rate/size metadata is retained; M4A codec parameters
  such as `codecs=alac`/`codecs=mp4a` are honored before bitrate inference, and
  bitrate can be inferred from byte size and duration when the server omits it.
  A raw generic M4A with no codec or bitrate metadata is treated conservatively
  as lossless for network scheduling, preventing an unlabelled ALAC stream from
  accidentally enabling competing prefetch. For the
  AAC 320 setting, an already compliant AAC source is passed through bit-for-bit
  instead of AAC→AAC transcoding; this preserves Apple AAC/FDK-AAC output and
  removes avoidable server CPU, generation loss, and startup latency. Codec hints
  are deliberately excluded from AVURLAsset resource identity so late canonical
  metadata enrichment does not throw away a warmed stream.
- Periodic library synchronization pauses while playback is requested and
  resumes after playback stops. Manual refresh remains available, but background
  API bursts cannot compete with the active media path.
- Cookies, ambient credential storage, and URLSession response caches are
  disabled for authenticated API and download sessions. BuFi's scoped caches
  remain in control. Generated cover-art URLs are also bounded in memory rather
  than growing for the entire account session.
- Identical OpenSubsonic reads share both one in-flight transfer and one JSON
  decode. A 16 MiB bounded body cache absorbs overlapping view/recommendation
  bursts, while decoded values use a separate 32-entry/8 MiB response-cost
  budget so convenience caching cannot grow without a memory bound. Raw and
  decoded entries retain the same original timestamp, preventing a late decode
  from extending TTL. After TTL, ETag/Last-Modified responses are conditionally
  revalidated when the server provides validators. Transient HTTP status and
  OpenSubsonic error envelopes may use stale-if-error within the endpoint's
  bounded grace window. Mutation boundaries invalidate dependent
  representations, and stale reads are never published across a relevant
  in-flight mutation.
- OpenSubsonic/Subsonic/legacy endpoint fallback is a compatibility mechanism,
  not a transport retry mechanism. BuFi advances to an older endpoint only for
  explicit missing/unsupported endpoint responses or an incompatible response
  shape; a network failure or temporary 5xx does not multiply into calls across
  every API generation.
- Extension capability discovery caches only an actual decoded server response.
  A temporary network/auth/cancellation failure leaves capability state unresolved
  so a later healthy request can recover instead of disabling extensions for the
  rest of the session.
- HTTP/1.1 pipelining is not forced. CFNetwork chooses fallback behavior while
  HTTP/2 and HTTP/3 use their native multiplexing paths.

HTTP/3 remains opportunistic: the origin, proxy, network path, and current iOS
transport policy must all permit QUIC. Discovery and fallback stay inside the
system transport stack without changing OpenSubsonic semantics.
Debug builds log the final `URLSessionTaskMetrics.networkProtocolName` and
connection-reuse flag by host without retaining those metrics in release builds.

## System-managed streaming behavior

AVPlayer/AVURLAsset and BuFi-owned URLSession requests learn HTTP/3 through the
origin's normal system advertisement/discovery path and keep system fallback
behavior. QUIC 0-RTT,
ECH, congestion control, TLS session resumption, and the concrete AVFoundation
media transport remain system-managed rather than being emulated in app code.
