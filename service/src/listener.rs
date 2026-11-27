//! Advertises the service over Bonjour under the computer's name, accepts connections from the
//! iPhone app and hands every line received to the core thread.
//!
//! On macOS the system's Bonjour (mDNSResponder) does the advertising, as for any Mac app: it
//! resolves name clashes and withdraws the service when the process ends, however it ends.
//! Elsewhere mdns-sd does it in Rust, so Windows needs no Bonjour service installed.

use std::io::{Read, Write};
use std::net::{Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::Arc;
use std::thread;

use socket2::{Domain, Protocol, Socket, Type};

use crate::protocol::{LineDecoder, SERVICE_TYPE};
use crate::{log, Event};

pub use bonjour::Advertisement;

/// The port tried first: the same one every time keeps records other devices still hold from an
/// earlier start valid. Another free port is taken when it is in use.
const PREFERRED_PORT: u16 = 52_300;

/// Starts accepting connections on a free port, over IPv4 and IPv6 as the phone may use either
/// (often an IPv6 link-local address), and advertises it. Returns the port.
pub fn start(events: Sender<Event>) -> Result<(u16, Advertisement), String> {
    let v4 = TcpListener::bind(("0.0.0.0", PREFERRED_PORT))
        .or_else(|_| TcpListener::bind(("0.0.0.0", 0)))
        .map_err(|e| e.to_string())?;
    let port = v4.local_addr().map_err(|e| e.to_string())?.port();
    let v6 = match bind_v6(port) {
        Ok(listener) => Some(listener),
        Err(error) => {
            log!("Listening over IPv4 only: {error}");
            None
        }
    };
    let advertisement = bonjour::advertise(port)?;
    log!("Listening on port {port} as {}", SERVICE_TYPE.trim_end_matches(".local."));

    let next_id = Arc::new(AtomicU64::new(0));
    for listener in std::iter::once(v4).chain(v6) {
        let (events, next_id) = (events.clone(), next_id.clone());
        thread::spawn(move || {
            for stream in listener.incoming() {
                match stream {
                    Ok(stream) => accept(next_id.fetch_add(1, Ordering::Relaxed) + 1, stream, events.clone()),
                    Err(error) => log!("Accept failed: {error}"),
                }
            }
        });
    }
    Ok((port, advertisement))
}

/// The IPv6 side on the same port, IPv6 only, so it does not clash with the IPv4 listener.
fn bind_v6(port: u16) -> std::io::Result<TcpListener> {
    let socket = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_only_v6(true)?;
    socket.bind(&SocketAddr::from((Ipv6Addr::UNSPECIFIED, port)).into())?;
    socket.listen(128)?;
    Ok(socket.into())
}

/// The computer's host name, without `.local`: the name the service is advertised under, which
/// the phone lists it by, as "Heyangs-MacBook-Pro" rather than "Heyang’s MacBook Pro".
pub fn hostname() -> String {
    let name = gethostname::gethostname().to_string_lossy().into_owned();
    let name = name.trim_end_matches('.').trim_end_matches(".local").to_string();
    if name.is_empty() { "computer".into() } else { name }
}

/// What the phone shows under the computer's name in its list: its system (`os`, macos or
/// windows) and its addresses on the local network (`ip`, IPv4, the Wi-Fi or Ethernet one first,
/// comma-separated). Taken when the service starts: a computer that
/// moves to another network shows its old address until the service restarts.
fn txt_entries() -> Vec<(&'static str, String)> {
    let os = if cfg!(windows) { "windows".to_string() } else { std::env::consts::OS.to_string() };
    let mut entries = vec![("os", os)];
    let addresses = local_addresses();
    if !addresses.is_empty() {
        entries.push(("ip", addresses.join(", ")));
    }
    entries
}

/// The computer's IPv4 addresses on the local network: not loopback, not self-assigned
/// (169.254.x.x), not on a VPN, container or virtual machine adapter.
fn local_addresses() -> Vec<String> {
    const VIRTUAL: [&str; 9] = ["utun", "bridge", "vmnet", "vboxnet", "docker", "veth", "awdl", "llw", "vEthernet"];
    let Ok(interfaces) = if_addrs::get_if_addrs() else { return Vec::new() };
    let mut found: Vec<(bool, String)> = interfaces
        .into_iter()
        .filter(|i| !i.is_loopback() && !VIRTUAL.iter().any(|prefix| i.name.starts_with(prefix)))
        .filter_map(|i| match i.addr {
            if_addrs::IfAddr::V4(v4) if !v4.ip.is_link_local() => {
                let physical = ["en0", "en1", "eth", "wlan", "Wi-Fi", "Ethernet"].iter().any(|p| i.name.starts_with(p));
                Some((!physical, v4.ip.to_string()))
            }
            _ => None,
        })
        .collect();
    found.sort_by_key(|(later, _)| *later);
    let mut addresses: Vec<String> = Vec::new();
    for (_, address) in found {
        if !addresses.contains(&address) {
            addresses.push(address);
        }
    }
    addresses
}

#[cfg_attr(target_os = "macos", allow(dead_code))]
fn sanitized(name: &str) -> String {
    let name: String = name
        .trim_end_matches(".local")
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' })
        .collect();
    if name.is_empty() { "computer".into() } else { name }
}

/// Each connection gets a thread reading its lines and a thread writing what is sent to it, so a
/// slow phone never holds up the core thread.
fn accept(id: u64, stream: TcpStream, events: Sender<Event>) {
    let peer = stream.peer_addr().map(|a| a.to_string()).unwrap_or_else(|_| "?".into());
    let Ok(mut writer) = stream.try_clone() else { return };
    let (send, outgoing) = mpsc::channel::<Vec<u8>>();
    thread::spawn(move || {
        for data in outgoing {
            if writer.write_all(&data).is_err() {
                break;
            }
        }
        let _ = writer.shutdown(Shutdown::Both);
    });
    let _ = events.send(Event::Connected { id, peer, send });

    let mut stream = stream;
    thread::spawn(move || {
        let mut decoder = LineDecoder::default();
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            match stream.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let lines = decoder.feed(&buffer[..n]);
                    if !lines.is_empty() && events.send(Event::Received { lines }).is_err() {
                        break;
                    }
                }
            }
        }
        let _ = stream.shutdown(Shutdown::Both);
        let _ = events.send(Event::Disconnected { id });
    });
}

#[cfg(target_os = "macos")]
mod bonjour {
    use std::ffi::{c_char, c_void, CString};
    use std::ptr;

    #[allow(non_camel_case_types)]
    type DNSServiceRef = *mut c_void;

    // dns_sd.h, in libSystem.
    extern "C" {
        fn DNSServiceRegister(
            sd_ref: *mut DNSServiceRef,
            flags: u32,
            interface_index: u32,
            name: *const c_char,
            regtype: *const c_char,
            domain: *const c_char,
            host: *const c_char,
            port: u16,
            txt_len: u16,
            txt_record: *const c_void,
            callback: *const c_void,
            context: *mut c_void,
        ) -> i32;
        fn DNSServiceRefDeallocate(sd_ref: DNSServiceRef);
    }

    /// Kept for the life of the process: mDNSResponder withdraws the service when it ends.
    pub struct Advertisement(DNSServiceRef);

    unsafe impl Send for Advertisement {}

    impl Advertisement {
        pub fn stop(&self) {
            unsafe { DNSServiceRefDeallocate(self.0) };
        }
    }

    /// Registered under the host name, which mDNSResponder changes itself when another device
    /// already uses it, with what the phone shows about it (txt_entries).
    pub fn advertise(port: u16) -> Result<Advertisement, String> {
        let regtype = CString::new(super::SERVICE_TYPE.trim_end_matches(".local.")).unwrap();
        let name = CString::new(super::hostname()).unwrap_or_default();
        // A TXT record is its entries one after another, each after a byte giving its length.
        let mut txt = Vec::new();
        for (key, value) in super::txt_entries() {
            let entry = format!("{key}={value}");
            let entry = &entry.as_bytes()[..entry.len().min(255)];
            txt.push(entry.len() as u8);
            txt.extend_from_slice(entry);
        }
        let mut service: DNSServiceRef = ptr::null_mut();
        let error = unsafe {
            DNSServiceRegister(
                &mut service,
                0,
                0,
                name.as_ptr(),
                regtype.as_ptr(),
                ptr::null(),
                ptr::null(),
                port.to_be(),
                txt.len() as u16,
                txt.as_ptr().cast(),
                ptr::null(),
                ptr::null_mut(),
            )
        };
        if error != 0 {
            return Err(format!("Bonjour registration failed ({error})"));
        }
        Ok(Advertisement(service))
    }
}

#[cfg(not(target_os = "macos"))]
mod bonjour {
    use std::time::Duration;

    use mdns_sd::{ServiceDaemon, ServiceInfo};

    pub struct Advertisement {
        daemon: ServiceDaemon,
        fullname: String,
    }

    impl Advertisement {
        /// Sends the goodbye before the process ends, so other devices drop the service at once
        /// rather than keep it until it times out and clash with the next start's.
        pub fn stop(&self) {
            if let Ok(done) = self.daemon.unregister(&self.fullname) {
                let _ = done.recv_timeout(Duration::from_secs(1));
            }
            if let Ok(done) = self.daemon.shutdown() {
                let _ = done.recv_timeout(Duration::from_secs(1));
            }
        }
    }

    pub fn advertise(port: u16) -> Result<Advertisement, String> {
        let daemon = ServiceDaemon::new().map_err(|e| e.to_string())?;
        let name = super::hostname();
        // A host name of our own, so the system's own records for `<name>.local` are not answered twice.
        let host = format!("voiced-{}.local.", super::sanitized(&gethostname::gethostname().to_string_lossy()));
        let properties: std::collections::HashMap<String, String> = super::txt_entries().into_iter().map(|(key, value)| (key.to_string(), value)).collect();
        let info = ServiceInfo::new(super::SERVICE_TYPE, &name, &host, "", port, Some(properties))
            .map_err(|e| e.to_string())?
            .enable_addr_auto();
        let fullname = info.get_fullname().to_string();
        daemon.register(info).map_err(|e| e.to_string())?;
        Ok(Advertisement { daemon, fullname })
    }
}
