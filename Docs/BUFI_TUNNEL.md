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

Properly provisioned app and extension targets declare the same
`$(AppIdentifierPrefix)cloud.tae00217.BuFi.tunnel` Keychain access group. The
runtime does not read that build substitution from Info.plist. Instead, each
signed process creates a harmless target-local probe, reads the default access
group assigned by its actual signer, derives the candidate shared group, and
asks Security whether that exact group is available. An explicit
`kSecAttrAccessGroup` is added to secret queries only after this check succeeds.

If a re-signed build lacks the shared group, newly generated keys are stored in
the main app's normal default Keychain group with no explicit access-group
attribute. Profile creation therefore remains secure and does not fail with
`errSecMissingEntitlement`, while the profile is marked `mainAppOnly`. Bufi does
not create or start an `NETunnelProviderManager` for that profile, and the UI
clearly reports that valid shared-Keychain and Packet Tunnel provisioning is
required. The extension refuses app-local secret ownership, so it can never
pretend to establish a tunnel without access to its private key.

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
launch that extension solely to provision a key. Building a temporary VPN
configuration just for key generation would add prompts and failure states.
The capability-checked shared group is therefore retained for properly signed
builds, with a narrow app-local fallback that is never exposed to the extension.

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
- DoQ starts loopback UDP and TCP DNS listeners on port 53 and forwards framed
  DNS messages through authenticated Network.framework QUIC connections with
  ALPN `doq` to the configurable server (default port 853). This component is
  deliberately isolated so a future persistent/multiplexed QUIC resolver or
  filtering layer can replace it without touching GotaTun.

No DNS filtering or advertising blocking is present in v1.

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
Short unsatisfied transitions are debounced. A sustained offline state suspends
GotaTun, which tears down packet and timer tasks. A restored or changed path
re-resolves peer hostnames, recreates UDP sockets, and forces a fresh handshake.
Sleep suspends the engine and wake performs the same recovery. Normal WireGuard
timers plus `PersistentKeepalive` handle server restarts and idle NAT mappings;
there is no STUN, traversal, relay, DERP, mesh, or coordination layer.

The GotaTun runtime uses two workers, pooled packet buffers, vectored utun
writes, a duplicated nonblocking fd, and 4 MiB UDP buffers. There is no Swift
per-packet callback, metrics timer in the extension, or reconnect polling loop.
The app requests metrics every two seconds only while the VPN is active.

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
- connect/disconnect and profile enable/disable
- OpenSubsonic primary/tunnel endpoint switching without cache-scope changes
- Wi-Fi → cellular, cellular → Wi-Fi, temporary offline, and endpoint DNS change
- background/foreground, lock/sleep/wake, server restart, and keepalive
- malformed imports, wrong keys, unavailable endpoint, and unavailable resolver
- Instruments allocations/leaks, energy, CPU, thermal behavior, and throughput

## Known v1 limitations

- Plain DNS intentionally uses the standards-defined port 53 because
  `NEDNSSettings` does not expose a custom port.
- DoQ uses one QUIC connection per query for a small, deterministic v1 surface;
  connection pooling/multiplexing is the primary resolver optimization point.
- Import supports standard single- or multi-peer WireGuard `.conf` files but
  ignores `wg-quick` shell hooks and platform-specific route commands.
- Editing preserves saved private and preshared keys unless explicitly replaced;
  private-key export is intentionally absent.
