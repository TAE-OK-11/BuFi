// SPDX-License-Identifier: GPL-3.0-or-later
//
// The fd ownership and utun framing pattern is adapted from Mullvad VPN's
// GPLv3 iOS GotaTun integration. The implementation uses GotaTun's public
// packet-pool traits and never takes ownership of Apple's original utun fd.

use bytes::Buf;
use gotatun::{
    packet::{Ip, Ipv4Header, Packet, PacketBufPool},
    tun::{IpRecv, IpSend, MtuWatcher},
};
use nix::fcntl::{fcntl, FcntlArg, OFlag};
use std::{
    io::{self, IoSlice},
    iter,
    os::fd::{AsRawFd, BorrowedFd, OwnedFd, RawFd},
    sync::Arc,
};
use tokio::io::{unix::AsyncFd, Interest};

const UTUN_HEADER_LENGTH: usize = size_of::<u32>();

#[derive(Clone)]
pub struct IosTunDevice {
    fd: Arc<AsyncFd<OwnedFd>>,
    mtu: MtuWatcher,
}

impl IosTunDevice {
    pub fn new(fd: RawFd, mtu: u16) -> io::Result<Self> {
        // SAFETY: NetworkExtension owns `fd` for at least the duration of this
        // call. We immediately duplicate it and only own the duplicate.
        let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
        let owned = nix::unistd::dup(borrowed)?;
        let flags = OFlag::from_bits_retain(fcntl(&owned, FcntlArg::F_GETFL)?);
        fcntl(&owned, FcntlArg::F_SETFL(flags | OFlag::O_NONBLOCK))?;
        Ok(Self {
            fd: Arc::new(AsyncFd::new(owned)?),
            mtu: MtuWatcher::new(mtu),
        })
    }
}

impl IpSend for IosTunDevice {
    async fn send(&mut self, packet: Packet<Ip>) -> io::Result<()> {
        let family = match packet.header.version() {
            4 => libc::AF_INET.to_ne_bytes(),
            6 => libc::AF_INET6.to_ne_bytes(),
            _ => return Err(io::ErrorKind::InvalidInput.into()),
        };
        let slices = [IoSlice::new(&family), IoSlice::new(packet.as_ref())];
        let expected = UTUN_HEADER_LENGTH + packet.len();
        let written = self
            .fd
            .async_io(Interest::WRITABLE, |fd| {
                nix::sys::uio::writev(fd, &slices).map_err(Into::into)
            })
            .await?;
        if written != expected {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "partial utun write"));
        }
        Ok(())
    }
}

impl IpRecv for IosTunDevice {
    async fn recv<'a>(
        &'a mut self,
        pool: &mut PacketBufPool,
    ) -> io::Result<impl Iterator<Item = Packet<Ip>> + Send + 'a> {
        let mut buffer = pool.get();
        let count = self
            .fd
            .async_io(Interest::READABLE, |fd| {
                nix::unistd::read(fd, &mut buffer[..]).map_err(Into::into)
            })
            .await?;
        if count < UTUN_HEADER_LENGTH + Ipv4Header::LEN {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "short utun packet"));
        }
        buffer.buf_mut().truncate(count);
        buffer.buf_mut().advance(UTUN_HEADER_LENGTH);
        let packet = buffer
            .try_into_ip()
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?;
        Ok(iter::once(packet))
    }

    fn mtu(&self) -> MtuWatcher {
        self.mtu.clone()
    }
}

