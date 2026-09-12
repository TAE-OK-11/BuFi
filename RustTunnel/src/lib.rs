// SPDX-License-Identifier: GPL-3.0-or-later

mod tun_device;

use base64::{engine::general_purpose::STANDARD, Engine};
use gotatun::{
    device::{Device, Peer},
    udp::socket::UdpSocketFactory,
    x25519::{PublicKey, StaticSecret},
};
use ipnetwork::IpNetwork;
use serde::{Deserialize, Serialize};
use std::{
    ffi::{c_char, c_void, CString},
    net::{IpAddr, SocketAddr},
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
    sync::{Arc, Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::runtime::{Builder, Runtime};
use tun_device::IosTunDevice;

type GotaTunDevice = Device<(UdpSocketFactory, IosTunDevice)>;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EngineConfiguration {
    private_key: String,
    mtu: u16,
    peers: Vec<PeerConfiguration>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PeerConfiguration {
    public_key: String,
    preshared_key: Option<String>,
    endpoint_ip: String,
    endpoint_port: u16,
    allowed_ips: Vec<String>,
    persistent_keepalive: Option<u16>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EngineStatistics {
    latest_handshake: Option<u64>,
    tx_bytes: u64,
    rx_bytes: u64,
    current_endpoint: Option<String>,
}

struct TunnelHandle {
    runtime: Runtime,
    device: Arc<GotaTunDevice>,
}

static LAST_ERROR: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn error_slot() -> &'static Mutex<Option<String>> {
    LAST_ERROR.get_or_init(|| Mutex::new(None))
}

fn set_error(error: impl ToString) {
    if let Ok(mut slot) = error_slot().lock() {
        *slot = Some(error.to_string());
    }
}

fn decode_key(value: &str, label: &str) -> Result<[u8; 32], String> {
    let decoded = STANDARD
        .decode(value)
        .map_err(|_| format!("{label} is not valid base64"))?;
    decoded
        .try_into()
        .map_err(|_| format!("{label} must contain exactly 32 bytes"))
}

fn make_peer(config: PeerConfiguration) -> Result<Peer, String> {
    let public_key = PublicKey::from(decode_key(&config.public_key, "peer public key")?);
    let endpoint_ip: IpAddr = config
        .endpoint_ip
        .parse()
        .map_err(|_| "resolved peer endpoint is not an IP address".to_string())?;
    let allowed_ips = config
        .allowed_ips
        .iter()
        .map(|value| value.parse::<IpNetwork>().map_err(|error| error.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let mut peer = Peer::new(public_key)
        .with_endpoint(SocketAddr::new(endpoint_ip, config.endpoint_port))
        .with_allowed_ips(allowed_ips);
    if let Some(key) = config.preshared_key {
        peer = peer.with_preshared_key(decode_key(&key, "preshared key")?);
    }
    peer.keepalive = config.persistent_keepalive.filter(|value| *value > 0);
    Ok(peer)
}

fn start_inner(tun_fd: i32, bytes: &[u8]) -> Result<*mut c_void, String> {
    let config: EngineConfiguration =
        serde_json::from_slice(bytes).map_err(|error| format!("invalid engine config: {error}"))?;
    if config.peers.is_empty() {
        return Err("at least one peer is required".to_string());
    }
    let private_key = StaticSecret::from(decode_key(&config.private_key, "private key")?);
    let peers = config
        .peers
        .into_iter()
        .map(make_peer)
        .collect::<Result<Vec<_>, _>>()?;
    let runtime = Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("bufi-gotatun")
        .build()
        .map_err(|error| format!("cannot create GotaTun runtime: {error}"))?;
    let tun = IosTunDevice::new(tun_fd, config.mtu)
        .map_err(|error| format!("cannot duplicate utun fd: {error}"))?;
    let device = runtime
        .block_on(
            gotatun::device::DeviceBuilder::new()
                .with_default_udp()
                .udp_recv_buffer_size(4 * 1024 * 1024)
                .udp_send_buffer_size(4 * 1024 * 1024)
                .with_ip(tun)
                .with_private_key(private_key)
                .with_peers(peers)
                .build(),
        )
        .map_err(|error| format!("cannot start GotaTun: {error}"))?;
    let handle = Box::new(TunnelHandle {
        runtime,
        device: Arc::new(device),
    });
    Ok(Box::into_raw(handle).cast())
}

#[repr(C)]
struct SockAddrCtl {
    sc_len: u8,
    sc_family: u8,
    ss_sysaddr: u16,
    sc_id: u32,
    sc_unit: u32,
    sc_reserved: [u32; 5],
}

#[repr(C)]
struct CtlInfo {
    ctl_id: u32,
    ctl_name: [c_char; 96],
}

/// Finds the utun control socket supplied by NetworkExtension without relying
/// on private KVC access to NEPacketTunnelFlow internals.
#[unsafe(no_mangle)]
pub extern "C" fn bufi_tunnel_find_utun_fd() -> i32 {
    const AF_SYSTEM_DARWIN: u8 = 32;
    const CTLIOCGINFO: libc::c_ulong = 0xC064_4E03;
    let mut info = CtlInfo {
        ctl_id: 0,
        ctl_name: [0; 96],
    };
    let name = b"com.apple.net.utun_control\0";
    for (target, source) in info.ctl_name.iter_mut().zip(name.iter().copied()) {
        *target = source as c_char;
    }
    for fd in 0..=1024 {
        let mut address = SockAddrCtl {
            sc_len: size_of::<SockAddrCtl>() as u8,
            sc_family: AF_SYSTEM_DARWIN,
            ss_sysaddr: 0,
            sc_id: 0,
            sc_unit: 0,
            sc_reserved: [0; 5],
        };
        let mut length = size_of::<SockAddrCtl>() as libc::socklen_t;
        // SAFETY: both pointers refer to initialized, correctly sized C-layout structures.
        let result = unsafe {
            libc::getpeername(
                fd,
                (&mut address as *mut SockAddrCtl).cast(),
                &mut length,
            )
        };
        if result != 0 || address.sc_family != AF_SYSTEM_DARWIN {
            continue;
        }
        if info.ctl_id == 0 {
            // SAFETY: CTLIOCGINFO writes only within the C-layout `CtlInfo` value.
            if unsafe { libc::ioctl(fd, CTLIOCGINFO, &mut info) } != 0 {
                continue;
            }
        }
        if address.sc_id == info.ctl_id {
            return fd;
        }
    }
    set_error("could not locate the NetworkExtension utun file descriptor");
    -1
}

/// Starts one GotaTun device. The JSON buffer is borrowed only for this call.
#[unsafe(no_mangle)]
pub extern "C" fn bufi_tunnel_start(
    tun_fd: i32,
    config: *const u8,
    config_len: usize,
) -> *mut c_void {
    if config.is_null() || config_len == 0 {
        set_error("engine configuration is empty");
        return ptr::null_mut();
    }
    // SAFETY: Swift supplies a readable Data buffer for the synchronous call.
    let bytes = unsafe { std::slice::from_raw_parts(config, config_len) };
    match catch_unwind(AssertUnwindSafe(|| start_inner(tun_fd, bytes))) {
        Ok(Ok(handle)) => handle,
        Ok(Err(error)) => {
            set_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("GotaTun panicked while starting");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_tunnel_stop(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: ownership is returned exactly once by Swift's adapter.
        let handle = unsafe { Box::from_raw(handle.cast::<TunnelHandle>()) };
        handle.runtime.block_on(handle.device.suspend());
    }));
}

fn with_handle(handle: *mut c_void, body: impl FnOnce(&TunnelHandle) -> Result<(), String>) -> i32 {
    if handle.is_null() {
        set_error("GotaTun handle is null");
        return -1;
    }
    // SAFETY: Swift serializes calls and keeps the handle alive for the call.
    let handle = unsafe { &*handle.cast::<TunnelHandle>() };
    match catch_unwind(AssertUnwindSafe(|| body(handle))) {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {
            set_error(error);
            -1
        }
        Err(_) => {
            set_error("GotaTun panicked during lifecycle operation");
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_tunnel_suspend(handle: *mut c_void) -> i32 {
    with_handle(handle, |handle| {
        handle.runtime.block_on(handle.device.suspend());
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_tunnel_resume(handle: *mut c_void) -> i32 {
    with_handle(handle, |handle| {
        handle
            .runtime
            .block_on(handle.device.resume())
            .map_err(|error| error.to_string())
    })
}

/// Rebinding uses GotaTun's suspend/resume path, which tears down UDP tasks,
/// creates fresh sockets, clears sessions, and initiates a fresh handshake.
#[unsafe(no_mangle)]
pub extern "C" fn bufi_tunnel_rebind(handle: *mut c_void) -> i32 {
    with_handle(handle, |handle| {
        handle.runtime.block_on(async {
            handle.device.suspend().await;
            handle.device.resume().await
        }).map_err(|error| error.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_tunnel_statistics(handle: *mut c_void) -> *mut c_char {
    if handle.is_null() {
        set_error("GotaTun handle is null");
        return ptr::null_mut();
    }
    // SAFETY: caller owns the live handle and serializes access.
    let handle = unsafe { &*handle.cast::<TunnelHandle>() };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let peers = handle.runtime.block_on(handle.device.peers());
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let statistics = EngineStatistics {
            latest_handshake: peers
                .iter()
                .filter_map(|peer| peer.stats.last_handshake)
                .map(|elapsed| now.saturating_sub(elapsed.as_secs()))
                .max(),
            tx_bytes: peers.iter().map(|peer| peer.stats.tx_bytes as u64).sum(),
            rx_bytes: peers.iter().map(|peer| peer.stats.rx_bytes as u64).sum(),
            current_endpoint: peers
                .iter()
                .find_map(|peer| peer.peer.endpoint.map(|endpoint| endpoint.to_string())),
        };
        serde_json::to_string(&statistics).map_err(|error| error.to_string())
    }));
    match result {
        Ok(Ok(json)) => CString::new(json).map_or(ptr::null_mut(), CString::into_raw),
        Ok(Err(error)) => {
            set_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_error("GotaTun panicked while reading statistics");
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_tunnel_last_error() -> *mut c_char {
    let message = error_slot()
        .lock()
        .ok()
        .and_then(|mut slot| slot.take())
        .unwrap_or_else(|| "unknown GotaTun error".to_string());
    CString::new(message).map_or(ptr::null_mut(), CString::into_raw)
}

#[unsafe(no_mangle)]
pub extern "C" fn bufi_tunnel_string_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: value was returned by CString::into_raw in this library.
        drop(unsafe { CString::from_raw(value) });
    }
}
