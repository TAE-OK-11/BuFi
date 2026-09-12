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
  parsing, non-secret app-group persistence, diagnostics, and shared Keychain
  access.
- `BuFi/Tunnel/App` contains the SwiftUI profile/client experience and
  `NETunnelProviderManager` ownership.
- `BuFiTunnelExtension` contains the packet-tunnel provider, routes, resolver
  implementations, endpoint resolution, and the narrow Swift/Rust adapter.
- `RustTunnel` is a static library with a small C ABI around upstream GotaTun.
  Packet buffers remain inside Rust for the data path; Swift/Rust crossings are
  limited to start/stop, network lifecycle operations, and on-demand metrics.

## Profiles and secrets

The app-group profile record includes names, addresses, public keys, routing,
endpoints, MTU, DNS choices, and opaque Keychain references. It never contains
an interface private key or preshared key. Both targets use the explicit
`$(AppIdentifierPrefix)cloud.tae00217.BuFi.tunnel` Keychain access group and
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

Keypairs are generated locally with CryptoKit X25519. The public key can be
copied from the editor. The UI never reveals an existing private key.

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

## Device validation still required

Unsigned CI cannot grant NetworkExtension entitlements or exercise real radio
handoffs. Before release, sign both targets and execute this matrix on physical
iPhones:

- Linux kernel WireGuard handshake; IPv4 and IPv6 traffic
- IPv4-only, IPv6-only, dual-stack, split, and full `AllowedIPs`
- Plain IPv4/IPv6 DNS, DoH, DoT, and DoQ resolvers
- connect/disconnect and profile enable/disable
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
