# Bufi Tunnel v1

Bufi Tunnel is a standalone, standard WireGuard client. It does not use Bufi's
music networking and has no dependency on a Bufi server. Its peer is any normal
WireGuard endpoint, including Linux kernel WireGuard.

## Architecture

```text
Settings → TunnelManager → NETunnelProviderManager
                           │ profile UUID only
                           ▼
                  PacketTunnelProvider
                    ├─ network settings/routes
                    ├─ TunnelDNSResolver
                    ├─ NWPathMonitor lifecycle
                    └─ RustTunnelAdapter (one startup call, lifecycle + metrics)
                                      ▼
                              GotaTun Device
                           utun fd ↔ UDP sockets
```

- `BuFi/Tunnel/Shared` contains Codable profiles, strict validation, `.conf`
  parsing, non-secret app-group persistence, diagnostics, and capability-aware
  Keychain access.
- `BuFi/Tunnel/App` contains the SwiftUI profile/client experience and
  `NETunnelProviderManager` ownership.
- `BuFiTunnelExtension` contains the packet-tunnel provider, routes, resolver
  implementations, endpoint resolution, and the narrow Swift/Rust adapter.
- `RustTunnel` is a static library with a small C ABI around upstream GotaTun.
  Packet buffers remain inside Rust for the data path; Swift/Rust crossings are
  limited to start/stop, network lifecycle operations, and on-demand metrics.

## Profiles and secrets

The app-group profile record includes names, addresses, public keys, routing,
endpoints, MTU, DNS choices, opaque Keychain references, and a secret-ownership
scope. It never contains an interface private key or preshared key. Secrets use
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and are not synchronizable.

Following WireGuard Apple's iOS design, both targets use their shared
application-group entitlement as the Keychain access group. A separate
`keychain-access-groups` entitlement is not required or requested. Normal
Xcode/App Store signing uses `group.cloud.tae00217.BuFi`. AltStore and SideStore
can remap that identifier for the active team and write the actually signed
value to each bundle's `ALTAppGroups` metadata; Bufi resolves the one exact or
unambiguous suffixed match and verifies it with Security before use. It also
reads the embedded appex's signed bundle identifier/`ALTBundleIdentifier`, avoiding a
hardcoded provider identifier after re-signing. Ambiguous or unusable values
fail closed. The previous prefixed custom group remains only as a runtime read
fallback for migrating keys from an older properly provisioned Bufi build.

If a re-signed build lacks the shared group, newly generated keys are stored in
the main app's normal default Keychain group with no explicit access-group
attribute. Profile creation therefore remains secure and does not fail with
`errSecMissingEntitlement`, while the profile is marked `mainAppOnly`. When the
user manually connects, Bufi reads that item and any preshared keys, validates
them, and passes their raw 32-byte `NSData` values only in
`startVPNTunnel(options:)`. The non-secret profile JSON is a separate option;
neither the secrets nor that launch envelope enter `providerConfiguration`, a
database, UserDefaults, or a file. The extension verifies the profile ID, key
sizes, derived public key, and required preshared keys before starting GotaTun.
Launch values are process memory owned by the OS IPC and are not retained in
the provider's runtime profile.

This fallback permits a manual connection only if the final signature still
contains a usable Packet Tunnel Network Extension entitlement. It cannot and
does not bypass Apple's capability checks. Because iOS cannot reconstruct the
one-time secret options after independently relaunching the provider, automatic
tunnel restart is unavailable for `mainAppOnly` profiles; the user reconnects
from Bufi. Correctly provisioned builds continue to use shared Keychain access
and support normal provider relaunch.

When a SideStore update introduces a usable remapped group, the repository
copies legacy profile metadata from the configured suite into that group. The
main app then migrates its `mainAppOnly` key into the verified group and deletes
the old item only after both copies and the profile scope update succeed.

The original `-34018` failure came from the first `SecItemUpdate` in
`TunnelKeychain.save`: every query unconditionally supplied an Info.plist value
that had already become `cloud.tae00217.BuFi.tunnel` in the unsigned artifact.
SideStore re-signing cannot re-expand Xcode build settings, so that value did
not match any access group granted by the final signer. The stale Info.plist
key has been removed from both targets.

Keypairs are generated locally with CryptoKit X25519. The public key can be
copied from the editor. The UI never reveals an existing private key.

Extension-only key generation was evaluated but is not used in v1. Before a
Packet Tunnel configuration exists, the app has no supported direct channel to
launch that extension solely to provision a key. The capability-checked App
Group remains preferred for properly signed builds, with the manual in-memory
delivery boundary as the narrow fallback for re-signed builds.

The profile actions are kept above diagnostics so they remain reachable above
Bufi's persistent mini player. **Add manually** opens the full editor for client
addresses, peer server IP/hostname and key, port, AllowedIPs, keepalive, MTU,
and every DNS mode. Standard `.conf` import remains available separately. The
tunnel screen, editor, validation messages, and entitlement guidance are
localized in Korean.

## Network settings

Client IPv4/IPv6 addresses become interface settings. Each peer's `AllowedIPs`
becomes an included route, so `0.0.0.0/0` and/or `::/0` produce a full tunnel
and narrower networks produce a split tunnel. IPv6 interface prefixes are
clamped to `/120` to match the proven WireGuard Apple workaround for iOS utun
behavior. The default MTU is 1280; explicit validated values are supported.

Endpoint hostnames are resolved before tunnel settings are installed and again
after meaningful path changes. Extension-owned WireGuard UDP sockets bypass
the utun route as required by NetworkExtension.

## DNS

All DNS modes implement `TunnelDNSResolver`:

- System leaves `dnsSettings` unset.
- Plain uses `NEDNSSettings` with IPv4/IPv6 server addresses on standard port
  53. Apple owns UDP/TCP fallback.
- DoH uses `NEDNSOverHTTPSSettings` and a configurable HTTPS URL.
- DoT uses `NEDNSOverTLSSettings`, bootstrap addresses, SNI name, and the
  platform's encrypted resolver implementation.
- DoQ starts loopback UDP and TCP DNS listeners on port 53. In accordance with
  RFC 9250, one raw DNS message is sent per authenticated Network.framework
  QUIC stream with ALPN `doq`; no DNS-over-TCP length prefix is placed on a DoQ
  stream. Streams are multiplexed over one lifecycle-owned `NWConnectionGroup`,
  avoiding a new QUIC handshake and UDP socket per query. A bounded five-second
  retry gate prevents handshake loops when QUIC is unavailable, while queries
  continue over DoT. Local TCP and DoT retain their required two-octet framing.
  All local and upstream connections are cancelled atomically when the resolver
  stops. The component remains replaceable without touching GotaTun.

### Lightweight DNS protection

Each profile can optionally enable Bufi DNS protection in Balanced or Family
mode. The user's System/Plain/DoH/DoT/DoQ resolver configuration is retained as
the base configuration and restored without loss when protection is disabled.
While protection is active, Bufi selects AdGuard's documented public filtering
resolver through `NEDNSOverHTTPSSettings`:

- Balanced blocks ads, trackers, phishing, and malicious domains.
- Family additionally blocks adult content and requests Safe Search where the
  upstream supports it.

The architecture follows the resolver/filter separation used by the Apache-2.0
AdGuard DnsLibs project, but deliberately does not embed that larger C++ engine
or a GPL blocklist. There is no list download, parser, query database,
background refresh timer, or per-query Swift/Rust FFI call. Built-in filtering
happens at the selected upstream and Bufi stores no DNS query history.

Users may add a small set of block and allow domains in the app. Exact domains,
subdomains, hosts-style entries, comma/newline lists, and basic
`||domain.example^` rules are normalized and deduplicated. Allow rules take
precedence over a blocked parent domain. When custom rules are non-empty, the
isolated resolver boundary applies them locally and returns an NXDOMAIN response
without forwarding the query. Allowed traffic uses authenticated DoQ to the
selected AdGuard endpoint with DoT fallback on networks that block QUIC. Only
the user-owned rules are resident in memory; the maintained large lists remain
upstream. Custom rules are compiled once into a compact reverse-label suffix
index, so hot-path matches do not allocate a String for every parent domain.
The editor also caches normalized results instead of reparsing the entire rule
text repeatedly during one SwiftUI render. Diagnostics expose only an aggregate
blocked-query count, never domain names. Custom block and allow rules are capped
at 4,096 combined to preserve the Network Extension's memory budget; bulk
maintained lists belong at the upstream.

## Optional OpenSubsonic endpoint routing

Bufi Tunnel remains a general-purpose VPN and does not depend on Bufi music
networking. The main app has a separate optional route selector for an existing
OpenSubsonic account: one primary address, additional addresses that can be
promoted to primary, and one tunnel-only address. The endpoint metadata is
stored atomically with the existing credentials in the app's normal Keychain;
it is never sent to the Packet Tunnel extension.

When the selected VPN reaches `connected` or `reasserting`, the app probes the
tunnel-only OpenSubsonic address and swaps clients only after a successful API
ping. When the VPN disconnects it similarly restores the primary address. A
failed probe leaves the existing client and playback session in place. The
account/cache identity is pinned to the original account address, so changing
between public, LAN, IPv4/IPv6, or WireGuard-only endpoints does not split
offline data, history, artwork, queue, or library caches into a second account.

The Tunnel screen shows this server connection card first. Separate action
buttons then open manual WireGuard setup, `.conf` import, selected-profile
editing, and the dedicated System/Plain/DoH/DoT/DoQ DNS editor.

## Lifecycle and performance

`NWPathMonitor` observes all path updates, including Wi-Fi/cellular handoffs.
The recovery fingerprint includes interface identity, gateways, IP-family/DNS
support, and constrained/expensive flags, so changes within the same interface
are not hidden by the short UI description. `.requiresConnection` is treated as
potentially usable, matching WireGuard Apple. Short unsatisfied transitions are
debounced. A sustained offline state suspends GotaTun, which tears down packet
and timer tasks. A restored or changed path re-resolves peer hostnames, updates
peer endpoints in place, recycles UDP sockets, and forces a fresh handshake.
One failed hostname retains its previous address without preventing other peers
from recovering. Full runtime/utun reconstruction is used only as the bounded
recovery path if in-place reconfiguration fails. Session generations prevent a
late path callback from resurrecting an adapter after disconnect.
Sleep suspends the engine and wake performs the same recovery. Normal WireGuard
timers plus `PersistentKeepalive` handle server restarts and idle NAT mappings;
there is no STUN, traversal, relay, DERP, mesh, or coordination layer.

The GotaTun runtime uses two workers, pooled packet buffers, vectored utun
writes, a duplicated nonblocking fd, and 4 MiB UDP buffers. Network changes send
only public peer identity and resolved endpoints across FFI; private and
preshared keys are not reloaded or serialized again. There is no Swift
per-packet callback, metrics timer in the extension, or reconnect polling loop.
The app requests metrics every second during transitions and every five seconds
after connection, reducing steady-state wakeups.
Rust release builds and the iOS Release configuration both use ThinLTO.

## GitHub validation

The workflows install Rust 1.95, build the pinned GotaTun static library for
the simulator and physical-device target, run `TunnelConfigurationTests`, and
build/package the complete app plus Network Extension. Failures upload both
test and device-build logs.

The CI IPA is deliberately unsigned, so it has neither `_CodeSignature` nor an
embedded provisioning profile and cannot prove final entitlements. XcodeGen
checks verify both source entitlement files and ensure the stale access-group
Info.plist property is absent. Release validation must additionally inspect the
post-signing `BuFi.app` and `BuFiTunnelExtension.appex` with `codesign -d
--entitlements :-` and compare their expanded access groups and Network
Extension capability with their embedded provisioning profiles. A SideStore-
signed IPA is required to audit what SideStore actually preserved or removed.

## Device validation still required

Unsigned CI cannot grant NetworkExtension entitlements or exercise real radio
handoffs. Before release, sign both targets and execute this matrix on physical
iPhones:

- final signed app/extension entitlements and provisioning-profile comparison
- profile creation on a build without shared Keychain access; no `-34018`, no
  repeated VPN prompt, and an explicit unsupported-signing state
- Linux kernel WireGuard handshake; IPv4 and IPv6 traffic
- IPv4-only, IPv6-only, dual-stack, split, and full `AllowedIPs`
- Plain IPv4/IPv6 DNS, DoH, DoT, and DoQ resolvers
- Balanced and Family DNS ad-blocking presets, including resolver restoration
- custom block/allow rules, NXDOMAIN response, aggregate count, and QUIC fallback
- connect/disconnect and profile enable/disable
- OpenSubsonic primary/tunnel endpoint switching without cache-scope changes
- Wi-Fi → cellular, cellular → Wi-Fi, temporary offline, and endpoint DNS change
- background/foreground, lock/sleep/wake, server restart, and keepalive
- malformed imports, wrong keys, unavailable endpoint, and unavailable resolver
- Instruments allocations/leaks, energy, CPU, thermal behavior, and throughput

## Known v1 limitations

- Plain DNS intentionally uses the standards-defined port 53 because
  `NEDNSSettings` does not expose a custom port.
- DoQ multiplexing depends on Network.framework's `NWConnectionGroup`; networks
  that block QUIC use the DoT fallback until the bounded QUIC retry gate opens.
- Import supports standard single- or multi-peer WireGuard `.conf` files but
  ignores `wg-quick` shell hooks and platform-specific route commands.
- Editing preserves saved private and preshared keys unless explicitly replaced;
  private-key export is intentionally absent.
