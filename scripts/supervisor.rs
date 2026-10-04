use std::env;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::mem;
use std::net::{Ipv4Addr, Ipv6Addr, Shutdown, TcpListener, TcpStream, ToSocketAddrs};
use std::os::raw::{c_char, c_int, c_long, c_uchar, c_void};
use std::os::unix::io::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const DEFAULT_SDK_PATH: &str = "/usr/share/sangfor/aTrust/resources/bin/libaTrustSDK.so";
const DEFAULT_HELPER_ENV_FILE: &str = "/root/.tunlet/helper.env";
const DEFAULT_CONNECTED_SIGNAL_FILE: &str = "/root/.tunlet/connected.request";
const DEFAULT_CORE_AGENT_LOG: &str = "/root/.tunlet/core-agent.log";
const DEFAULT_SDK_API_LOG: &str = "/home/sangfor/.aTrust/logs/SdkApi.log";
const DEFAULT_VPN_ROOT: &str = "/usr/share/sangfor/aTrust";
const DEFAULT_VPN_BIN: &str = "/usr/share/sangfor/aTrust/resources/bin";
const DEFAULT_SOCKS_GATE_STATE_FILE: &str = "/root/.tunlet/socks-gate.state";
const DEFAULT_STATE_DIR: &str = "/root/.tunlet";
const DEFAULT_CA_BUNDLE: &str = "/etc/ssl/certs/ca-certificates.crt";

const AUTH_OK: c_int = 0;
const AUTH_SMS: c_int = 2;
const RTLD_NOW: c_int = 2;
const RTLD_GLOBAL: c_int = 0x100;
const SSL_VERIFY_PEER: c_int = 0x01;
const SSL_CTRL_SET_TLSEXT_HOSTNAME: c_int = 55;
const SIGTERM: c_int = 15;
const SIGINT: c_int = 2;
const WNOHANG: c_int = 1;

static TERMINATE: AtomicBool = AtomicBool::new(false);
static ACTIVE_SOCKS_CLIENTS: AtomicUsize = AtomicUsize::new(0);

type AtrustInitial = unsafe extern "C" fn(*const c_char) -> c_int;
type AtrustUninitial = unsafe extern "C" fn();
type AtrustFree = unsafe extern "C" fn(*mut c_void);
type AtrustQueryStatus = unsafe extern "C" fn(*mut *mut c_void) -> c_int;
type AtrustLoginPwd = unsafe extern "C" fn(
    *const c_char,
    *const c_char,
    c_uchar,
    *mut c_int,
    *mut *mut c_void,
) -> c_int;
type AtrustFetchSms = unsafe extern "C" fn(*mut *mut c_void) -> c_int;
type AtrustLoginSms = unsafe extern "C" fn(*const c_char, *mut c_int, *mut *mut c_void) -> c_int;
type AtrustLogout = unsafe extern "C" fn() -> c_int;
type TlsClientMethod = unsafe extern "C" fn() -> *const c_void;
type SslCtxNew = unsafe extern "C" fn(*const c_void) -> *mut c_void;
type SslCtxFree = unsafe extern "C" fn(*mut c_void);
type SslCtxLoadVerifyLocations =
    unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char) -> c_int;
type SslCtxSetVerify = unsafe extern "C" fn(*mut c_void, c_int, *mut c_void);
type SslNew = unsafe extern "C" fn(*mut c_void) -> *mut c_void;
type SslFree = unsafe extern "C" fn(*mut c_void);
type SslSetFd = unsafe extern "C" fn(*mut c_void, c_int) -> c_int;
type SslCtrl = unsafe extern "C" fn(*mut c_void, c_int, c_long, *mut c_void) -> c_long;
type SslSet1Host = unsafe extern "C" fn(*mut c_void, *const c_char) -> c_int;
type SslGet0Param = unsafe extern "C" fn(*mut c_void) -> *mut c_void;
type X509VerifyParamSet1IpAsc = unsafe extern "C" fn(*mut c_void, *const c_char) -> c_int;
type SslConnect = unsafe extern "C" fn(*mut c_void) -> c_int;
type SslWrite = unsafe extern "C" fn(*mut c_void, *const c_void, c_int) -> c_int;
type SslRead = unsafe extern "C" fn(*mut c_void, *mut c_void, c_int) -> c_int;
type SslGetError = unsafe extern "C" fn(*const c_void, c_int) -> c_int;
type SslShutdown = unsafe extern "C" fn(*mut c_void) -> c_int;

#[link(name = "dl")]
extern "C" {
    fn dlopen(filename: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlerror() -> *const c_char;
    fn dlclose(handle: *mut c_void) -> c_int;
}

extern "C" {
    fn setsid() -> c_int;
    fn kill(pid: c_int, sig: c_int) -> c_int;
    fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
    fn signal(signum: c_int, handler: extern "C" fn(c_int)) -> usize;
}

extern "C" fn handle_signal(_sig: c_int) {
    TERMINATE.store(true, Ordering::SeqCst);
}

#[derive(Clone)]
struct Config {
    sdk_path: String,
    server: String,
    helper_env_file: String,
    bind_addr: String,
    port: u16,
    token: String,
    username: String,
    password: String,
    domain: String,
    connected_signal_file: String,
    vpn_root: String,
    vpn_bin: String,
    socks_bind: String,
    socks_gate_state_file: String,
    socks_port: u16,
    socks_max_clients: usize,
    socks_handshake_timeout_seconds: u64,
    socks_io_timeout_seconds: u64,
    socks_fallback_dns: String,
    socks_fallback_tls_name: String,
    socks_fallback_domains: String,
    sdk_api_log: String,
    pending_sms_ttl_seconds: i64,
    vpn_tun: String,
    watchdog_interval_seconds: u64,
    health_failure_threshold: u32,
    health_probe_timeout_seconds: u64,
    health_dns_probe_host: String,
    health_dns_query_bin: String,
    health_dns_upstream_host: String,
    health_dns_upstream_port: u16,
    health_socks_probe_host: String,
    health_socks_probe_port: u16,
    health_socks_proxy_host: String,
    keepalive_urls: String,
    keepalive_interval_seconds: u64,
    keepalive_timeout_seconds: u64,
}

impl Config {
    fn load() -> Self {
        let mut cfg = Self {
            sdk_path: env_value("ATRUST_SDK_LIB", DEFAULT_SDK_PATH),
            server: env_value("ATRUST_SERVER", ""),
            helper_env_file: env_value("TUNLET_HELPER_ENV_FILE", DEFAULT_HELPER_ENV_FILE),
            bind_addr: env_value("TUNLET_HELPER_BIND", "0.0.0.0"),
            port: env_value("TUNLET_HELPER_PORT", "54680")
                .parse()
                .unwrap_or(54680),
            token: String::new(),
            username: String::new(),
            password: String::new(),
            domain: env_value("ATRUST_DOMAIN", ""),
            connected_signal_file: env_value(
                "ATRUST_CONNECTED_SIGNAL_FILE",
                DEFAULT_CONNECTED_SIGNAL_FILE,
            ),
            vpn_root: env_value("VPN_ROOT", DEFAULT_VPN_ROOT),
            vpn_bin: env_value("VPN_BIN", DEFAULT_VPN_BIN),
            socks_bind: env_value("TUNLET_SOCKS_BIND", "0.0.0.0"),
            socks_gate_state_file: env_value(
                "TUNLET_SOCKS_GATE_STATE_FILE",
                DEFAULT_SOCKS_GATE_STATE_FILE,
            ),
            socks_port: env_value("TUNLET_SOCKS_PORT", "1080")
                .parse()
                .unwrap_or(1080),
            socks_max_clients: env_value("TUNLET_SOCKS_MAX_CLIENTS", "256")
                .parse()
                .unwrap_or(256),
            socks_handshake_timeout_seconds: env_value(
                "TUNLET_SOCKS_HANDSHAKE_TIMEOUT_SECONDS",
                "10",
            )
            .parse()
            .unwrap_or(10),
            socks_io_timeout_seconds: env_value("TUNLET_SOCKS_IO_TIMEOUT_SECONDS", "120")
                .parse()
                .unwrap_or(120),
            socks_fallback_dns: env_value("TUNLET_SOCKS_FALLBACK_DNS", ""),
            socks_fallback_tls_name: env_value("TUNLET_SOCKS_FALLBACK_TLS_NAME", ""),
            socks_fallback_domains: env_value("TUNLET_SOCKS_FALLBACK_DOMAINS", ""),
            sdk_api_log: env_value("ATRUST_SDK_API_LOG", DEFAULT_SDK_API_LOG),
            pending_sms_ttl_seconds: env_value("ATRUST_PENDING_SMS_TTL_SECONDS", "300")
                .parse()
                .unwrap_or(300),
            vpn_tun: env_value("VPN_TUN", "utun7"),
            watchdog_interval_seconds: env_value("ATRUST_WATCHDOG_INTERVAL_SECONDS", "30")
                .parse()
                .unwrap_or(30),
            health_failure_threshold: env_value("ATRUST_HEALTH_FAILURE_THRESHOLD", "3")
                .parse()
                .unwrap_or(3),
            health_probe_timeout_seconds: env_value("ATRUST_HEALTH_PROBE_TIMEOUT_SECONDS", "5")
                .parse()
                .unwrap_or(5),
            health_dns_probe_host: env_value("ATRUST_HEALTH_DNS_PROBE_HOST", ""),
            health_dns_query_bin: env_value(
                "ATRUST_HEALTH_DNS_QUERY_BIN",
                "/opt/tunlet/atrust-dns-query",
            ),
            health_dns_upstream_host: env_value("ATRUST_HEALTH_DNS_UPSTREAM_HOST", "198.18.255.1"),
            health_dns_upstream_port: env_value("ATRUST_HEALTH_DNS_UPSTREAM_PORT", "53")
                .parse()
                .unwrap_or(53),
            health_socks_probe_host: env_value("ATRUST_HEALTH_SOCKS_PROBE_HOST", ""),
            health_socks_probe_port: env_value("ATRUST_HEALTH_SOCKS_PROBE_PORT", "443")
                .parse()
                .unwrap_or(443),
            health_socks_proxy_host: env_value("ATRUST_HEALTH_SOCKS_PROXY_HOST", "127.0.0.1"),
            keepalive_urls: env_value("ATRUST_KEEPALIVE_URLS", ""),
            keepalive_interval_seconds: env_value("ATRUST_KEEPALIVE_INTERVAL_SECONDS", "0")
                .parse()
                .unwrap_or(0),
            keepalive_timeout_seconds: env_value("ATRUST_KEEPALIVE_TIMEOUT_SECONDS", "8")
                .parse()
                .unwrap_or(8),
        };
        cfg.load_env_file();
        if let Ok(value) = env::var("TUNLET_HELPER_TOKEN") {
            if !value.is_empty() {
                cfg.token = value;
            }
        }
        if let Ok(value) = env::var("ATRUST_USERNAME") {
            if !value.is_empty() {
                cfg.username = value;
            }
        }
        if let Ok(value) = env::var("ATRUST_PASSWORD") {
            if !value.is_empty() {
                cfg.password = value;
            }
        }
        cfg
    }

    fn load_env_file(&mut self) {
        let content = match fs::read_to_string(&self.helper_env_file) {
            Ok(content) => content,
            Err(_) => return,
        };
        for raw in content.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (key, value) = match line.split_once('=') {
                Some(pair) => pair,
                None => continue,
            };
            self.set_value(key.trim(), trim_env_value(value.trim()));
        }
    }

    fn set_value(&mut self, key: &str, value: String) {
        match key {
            "ATRUST_SDK_LIB" => self.sdk_path = value,
            "ATRUST_SERVER" => self.server = value,
            "TUNLET_HELPER_BIND" => self.bind_addr = value,
            "TUNLET_HELPER_PORT" => self.port = value.parse().unwrap_or(54680),
            "TUNLET_HELPER_TOKEN" => self.token = value,
            "ATRUST_USERNAME" => self.username = value,
            "ATRUST_PASSWORD" => self.password = value,
            "ATRUST_DOMAIN" => self.domain = value,
            "ATRUST_CONNECTED_SIGNAL_FILE" => self.connected_signal_file = value,
            "VPN_ROOT" => self.vpn_root = value,
            "VPN_BIN" => self.vpn_bin = value,
            "VPN_TUN" => self.vpn_tun = value,
            "TUNLET_SOCKS_BIND" => self.socks_bind = value,
            "TUNLET_SOCKS_PORT" => self.socks_port = value.parse().unwrap_or(1080),
            "TUNLET_SOCKS_GATE_STATE_FILE" => self.socks_gate_state_file = value,
            "TUNLET_SOCKS_MAX_CLIENTS" => self.socks_max_clients = value.parse().unwrap_or(256),
            "TUNLET_SOCKS_HANDSHAKE_TIMEOUT_SECONDS" => {
                self.socks_handshake_timeout_seconds = value.parse().unwrap_or(10)
            }
            "TUNLET_SOCKS_IO_TIMEOUT_SECONDS" => {
                self.socks_io_timeout_seconds = value.parse().unwrap_or(120)
            }
            "TUNLET_SOCKS_FALLBACK_DNS" => self.socks_fallback_dns = value,
            "TUNLET_SOCKS_FALLBACK_TLS_NAME" => self.socks_fallback_tls_name = value,
            "TUNLET_SOCKS_FALLBACK_DOMAINS" => self.socks_fallback_domains = value,
            "ATRUST_SDK_API_LOG" => self.sdk_api_log = value,
            "ATRUST_PENDING_SMS_TTL_SECONDS" => {
                self.pending_sms_ttl_seconds = value.parse().unwrap_or(300)
            }
            "ATRUST_WATCHDOG_INTERVAL_SECONDS" => {
                self.watchdog_interval_seconds = value.parse().unwrap_or(30)
            }
            "ATRUST_HEALTH_FAILURE_THRESHOLD" => {
                self.health_failure_threshold = value.parse().unwrap_or(3)
            }
            "ATRUST_HEALTH_PROBE_TIMEOUT_SECONDS" => {
                self.health_probe_timeout_seconds = value.parse().unwrap_or(5)
            }
            "ATRUST_HEALTH_DNS_PROBE_HOST" => self.health_dns_probe_host = value,
            "ATRUST_HEALTH_DNS_QUERY_BIN" => self.health_dns_query_bin = value,
            "ATRUST_HEALTH_DNS_UPSTREAM_HOST" => self.health_dns_upstream_host = value,
            "ATRUST_HEALTH_DNS_UPSTREAM_PORT" => {
                self.health_dns_upstream_port = value.parse().unwrap_or(53)
            }
            "ATRUST_HEALTH_SOCKS_PROBE_HOST" => self.health_socks_probe_host = value,
            "ATRUST_HEALTH_SOCKS_PROBE_PORT" => {
                self.health_socks_probe_port = value.parse().unwrap_or(443)
            }
            "ATRUST_HEALTH_SOCKS_PROXY_HOST" => self.health_socks_proxy_host = value,
            "ATRUST_KEEPALIVE_URLS" => self.keepalive_urls = value,
            "ATRUST_KEEPALIVE_INTERVAL_SECONDS" => {
                self.keepalive_interval_seconds = value.parse().unwrap_or(0)
            }
            "ATRUST_KEEPALIVE_TIMEOUT_SECONDS" => {
                self.keepalive_timeout_seconds = value.parse().unwrap_or(8)
            }
            _ => {}
        }
    }

    fn keepalive_urls(&self) -> Vec<String> {
        self.keepalive_urls
            .split(|ch: char| ch == ',' || ch.is_ascii_whitespace())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .collect()
    }

    fn socks_dns_fallback(&self) -> SocksDnsFallback {
        SocksDnsFallback {
            resolver: self.socks_fallback_dns.trim().to_string(),
            tls_name: self.socks_fallback_tls_name.trim().to_string(),
            domains: self
                .socks_fallback_domains
                .split(|ch: char| ch == ',' || ch.is_ascii_whitespace())
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| value.trim_start_matches('.').to_ascii_lowercase())
                .collect(),
        }
    }
}

struct Status {
    sdk_code: i32,
    connected: bool,
    pending_sms: bool,
    user_status: i32,
    tunnel_status: i32,
}

impl Status {
    fn idle(pending_sms: bool) -> Self {
        Self {
            sdk_code: 0,
            connected: false,
            pending_sms,
            user_status: 0,
            tunnel_status: 0,
        }
    }
}

struct Sdk {
    _handle: *mut c_void,
    initialized: bool,
    pending_sms: bool,
    pending_sms_since: Option<SystemTime>,
    initial: AtrustInitial,
    _uninitial: AtrustUninitial,
    free_ptr: AtrustFree,
    query_status: AtrustQueryStatus,
    login_pwd: AtrustLoginPwd,
    fetch_sms: AtrustFetchSms,
    login_sms: AtrustLoginSms,
    logout: AtrustLogout,
}

impl Sdk {
    fn load(path: &str) -> Result<Self, String> {
        let c_path = CString::new(path).map_err(|_| "invalid SDK path".to_string())?;
        let handle = unsafe { dlopen(c_path.as_ptr(), RTLD_NOW | RTLD_GLOBAL) };
        if handle.is_null() {
            return Err(format!("dlopen {} failed: {}", path, dl_error()));
        }
        Ok(Self {
            _handle: handle,
            initialized: false,
            pending_sms: false,
            pending_sms_since: None,
            initial: load_symbol(handle, "atrust_initial")?,
            _uninitial: load_symbol(handle, "atrust_uninitial")?,
            free_ptr: load_symbol(handle, "atrust_free")?,
            query_status: load_symbol(handle, "atrust_sync_query_status")?,
            login_pwd: load_symbol(handle, "atrust_sync_login_by_pwd")?,
            fetch_sms: load_symbol(handle, "atrust_sync_fetch_sms")?,
            login_sms: load_symbol(handle, "atrust_sync_login_by_sms")?,
            logout: load_symbol(handle, "atrust_sync_logout")?,
        })
    }

    fn ensure_initial(&mut self, cfg: &Config) -> i32 {
        if self.initialized {
            return 0;
        }
        if cfg.server.is_empty() {
            return -2;
        }
        let server = match CString::new(cfg.server.as_str()) {
            Ok(server) => server,
            Err(_) => return -3,
        };
        let code = unsafe { (self.initial)(server.as_ptr()) };
        self.initialized = code == 0;
        code
    }

    fn free(&self, ptr: *mut c_void) {
        if !ptr.is_null() {
            unsafe { (self.free_ptr)(ptr) };
        }
    }

    fn reset_session(&mut self) {
        if self.initialized {
            unsafe { (self._uninitial)() };
            self.initialized = false;
        }
        self.clear_pending_sms();
    }

    fn mark_pending_sms(&mut self) {
        self.pending_sms = true;
        self.pending_sms_since = Some(SystemTime::now());
    }

    fn clear_pending_sms(&mut self) {
        self.pending_sms = false;
        self.pending_sms_since = None;
    }

    fn pending_sms_time_remaining(&mut self, cfg: &Config) -> i64 {
        if !self.pending_sms || cfg.pending_sms_ttl_seconds <= 0 {
            return -1;
        }
        let since = self.pending_sms_since.get_or_insert_with(SystemTime::now);
        let elapsed = since.elapsed().unwrap_or_default().as_secs() as i64;
        (cfg.pending_sms_ttl_seconds - elapsed).max(0)
    }
}

#[derive(Clone, Copy)]
enum TlsResponseMode {
    Http,
    DnsFrame,
}

struct OpenSslApi {
    handle: *mut c_void,
    tls_client_method: TlsClientMethod,
    ctx_new: SslCtxNew,
    ctx_free: SslCtxFree,
    ctx_load_verify_locations: SslCtxLoadVerifyLocations,
    ctx_set_verify: SslCtxSetVerify,
    ssl_new: SslNew,
    ssl_free: SslFree,
    ssl_set_fd: SslSetFd,
    ssl_ctrl: SslCtrl,
    ssl_set1_host: SslSet1Host,
    ssl_get0_param: SslGet0Param,
    x509_verify_param_set1_ip_asc: X509VerifyParamSet1IpAsc,
    ssl_connect: SslConnect,
    ssl_write: SslWrite,
    ssl_read: SslRead,
    ssl_get_error: SslGetError,
    ssl_shutdown: SslShutdown,
}

impl OpenSslApi {
    fn load() -> Result<Self, String> {
        let mut failures = Vec::new();
        let mut handle = ptr::null_mut();
        for library in ["libssl.so.1.1", "libssl.so.3", "libssl.so"] {
            let c_library = CString::new(library).expect("static OpenSSL library name");
            handle = unsafe { dlopen(c_library.as_ptr(), RTLD_NOW) };
            if !handle.is_null() {
                break;
            }
            failures.push(format!("{}: {}", library, dl_error()));
        }
        if handle.is_null() {
            return Err(format!("could not load OpenSSL ({})", failures.join("; ")));
        }

        let result = (|| {
            Ok(Self {
                handle,
                tls_client_method: load_symbol(handle, "TLS_client_method")?,
                ctx_new: load_symbol(handle, "SSL_CTX_new")?,
                ctx_free: load_symbol(handle, "SSL_CTX_free")?,
                ctx_load_verify_locations: load_symbol(handle, "SSL_CTX_load_verify_locations")?,
                ctx_set_verify: load_symbol(handle, "SSL_CTX_set_verify")?,
                ssl_new: load_symbol(handle, "SSL_new")?,
                ssl_free: load_symbol(handle, "SSL_free")?,
                ssl_set_fd: load_symbol(handle, "SSL_set_fd")?,
                ssl_ctrl: load_symbol(handle, "SSL_ctrl")?,
                ssl_set1_host: load_symbol(handle, "SSL_set1_host")?,
                ssl_get0_param: load_symbol(handle, "SSL_get0_param")?,
                x509_verify_param_set1_ip_asc: load_symbol(
                    handle,
                    "X509_VERIFY_PARAM_set1_ip_asc",
                )?,
                ssl_connect: load_symbol(handle, "SSL_connect")?,
                ssl_write: load_symbol(handle, "SSL_write")?,
                ssl_read: load_symbol(handle, "SSL_read")?,
                ssl_get_error: load_symbol(handle, "SSL_get_error")?,
                ssl_shutdown: load_symbol(handle, "SSL_shutdown")?,
            })
        })();
        if result.is_err() {
            unsafe {
                dlclose(handle);
            }
        }
        result
    }

    fn send_request(&self, stream: &TcpStream, host: &str, request: &[u8]) -> Result<(), String> {
        let response = self.exchange(stream, host, request, TlsResponseMode::Http)?;
        validate_http_response(&response)
    }

    fn exchange(
        &self,
        stream: &TcpStream,
        host: &str,
        request: &[u8],
        response_mode: TlsResponseMode,
    ) -> Result<Vec<u8>, String> {
        if !Path::new(DEFAULT_CA_BUNDLE).is_file() {
            return Err(format!("TLS CA bundle is missing: {}", DEFAULT_CA_BUNDLE));
        }
        let method = unsafe { (self.tls_client_method)() };
        let ctx = unsafe { (self.ctx_new)(method) };
        if ctx.is_null() {
            return Err("TLS context creation failed".to_string());
        }
        let result = self.exchange_with_ctx(ctx, stream, host, request, response_mode);
        unsafe {
            (self.ctx_free)(ctx);
        }
        result
    }

    fn exchange_with_ctx(
        &self,
        ctx: *mut c_void,
        stream: &TcpStream,
        host: &str,
        request: &[u8],
        response_mode: TlsResponseMode,
    ) -> Result<Vec<u8>, String> {
        let ca_bundle = CString::new(DEFAULT_CA_BUNDLE).expect("static CA bundle path");
        let ca_loaded =
            unsafe { (self.ctx_load_verify_locations)(ctx, ca_bundle.as_ptr(), ptr::null()) };
        if ca_loaded != 1 {
            return Err(format!(
                "TLS could not load CA bundle {}",
                DEFAULT_CA_BUNDLE
            ));
        }
        unsafe {
            (self.ctx_set_verify)(ctx, SSL_VERIFY_PEER, ptr::null_mut());
        }

        let ssl = unsafe { (self.ssl_new)(ctx) };
        if ssl.is_null() {
            return Err("TLS session creation failed".to_string());
        }
        let result = (|| {
            let c_host =
                CString::new(host).map_err(|_| "TLS host contains a NUL byte".to_string())?;
            if host.parse::<std::net::IpAddr>().is_ok() {
                let param = unsafe { (self.ssl_get0_param)(ssl) };
                if param.is_null()
                    || unsafe { (self.x509_verify_param_set1_ip_asc)(param, c_host.as_ptr()) } != 1
                {
                    return Err(format!(
                        "TLS could not configure IP verification for {}",
                        host
                    ));
                }
            } else {
                if unsafe { (self.ssl_set1_host)(ssl, c_host.as_ptr()) } != 1 {
                    return Err(format!(
                        "TLS could not configure hostname verification for {}",
                        host
                    ));
                }
                if unsafe {
                    (self.ssl_ctrl)(
                        ssl,
                        SSL_CTRL_SET_TLSEXT_HOSTNAME,
                        0,
                        c_host.as_ptr() as *mut c_void,
                    )
                } != 1
                {
                    return Err(format!("TLS could not configure SNI for {}", host));
                }
            }
            if unsafe { (self.ssl_set_fd)(ssl, stream.as_raw_fd()) } != 1 {
                return Err("TLS could not attach the SOCKS socket".to_string());
            }
            let connected = unsafe { (self.ssl_connect)(ssl) };
            if connected != 1 {
                return Err(self.ssl_error("handshake", ssl, connected));
            }

            let mut written = 0;
            while written < request.len() {
                let remaining = request.len() - written;
                let chunk = remaining.min(c_int::MAX as usize) as c_int;
                let count = unsafe {
                    (self.ssl_write)(ssl, request[written..].as_ptr() as *const c_void, chunk)
                };
                if count <= 0 {
                    return Err(self.ssl_error("request write", ssl, count));
                }
                written += count as usize;
            }

            let response = match response_mode {
                TlsResponseMode::Http => {
                    let mut response = vec![0u8; 4096];
                    let count = unsafe {
                        (self.ssl_read)(
                            ssl,
                            response.as_mut_ptr() as *mut c_void,
                            response.len() as c_int,
                        )
                    };
                    if count <= 0 {
                        return Err(self.ssl_error("response read", ssl, count));
                    }
                    response.truncate(count as usize);
                    response
                }
                TlsResponseMode::DnsFrame => {
                    let mut length = [0u8; 2];
                    self.ssl_read_exact(ssl, &mut length)?;
                    let length = u16::from_be_bytes(length) as usize;
                    if length < 12 {
                        return Err(format!("DNS over TLS returned a short frame ({})", length));
                    }
                    let mut response = vec![0u8; length];
                    self.ssl_read_exact(ssl, &mut response)?;
                    response
                }
            };
            let _ = unsafe { (self.ssl_shutdown)(ssl) };
            Ok(response)
        })();
        unsafe {
            (self.ssl_free)(ssl);
        }
        result
    }

    fn ssl_read_exact(&self, ssl: *mut c_void, output: &mut [u8]) -> Result<(), String> {
        let mut read = 0usize;
        while read < output.len() {
            let remaining = output.len() - read;
            let chunk = remaining.min(c_int::MAX as usize) as c_int;
            let count = unsafe {
                (self.ssl_read)(ssl, output[read..].as_mut_ptr() as *mut c_void, chunk)
            };
            if count <= 0 {
                return Err(self.ssl_error("response read", ssl, count));
            }
            read += count as usize;
        }
        Ok(())
    }

    fn ssl_error(&self, operation: &str, ssl: *mut c_void, result: c_int) -> String {
        let code = unsafe { (self.ssl_get_error)(ssl, result) };
        format!("TLS {} failed (SSL error {})", operation, code)
    }
}

impl Drop for OpenSslApi {
    fn drop(&mut self) {
        unsafe {
            dlclose(self.handle);
        }
    }
}

#[derive(Clone)]
struct SocksDnsFallback {
    resolver: String,
    tls_name: String,
    domains: Vec<String>,
}

impl SocksDnsFallback {
    fn matches(&self, host: &str) -> bool {
        if self.resolver.is_empty()
            || self.tls_name.is_empty()
            || self.domains.is_empty()
            || host.parse::<std::net::IpAddr>().is_ok()
        {
            return false;
        }
        let host = host.trim_end_matches('.').to_ascii_lowercase();
        self.domains
            .iter()
            .any(|domain| host == *domain || host.ends_with(&format!(".{}", domain)))
    }

    fn resolve_ipv4(&self, host: &str) -> io::Result<Vec<Ipv4Addr>> {
        query_ipv4_over_tls(&self.resolver, &self.tls_name, host).map_err(|err| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("fallback DNS failed for {}: {}", host, err),
            )
        })
    }
}

fn build_dns_a_query(host: &str, id: u16) -> Result<Vec<u8>, String> {
    let host = host.trim_end_matches('.');
    if host.is_empty() || host.len() > 253 {
        return Err("DNS name is empty or too long".to_string());
    }
    let mut query = Vec::with_capacity(host.len() + 18);
    query.extend_from_slice(&id.to_be_bytes());
    query.extend_from_slice(&0x0100u16.to_be_bytes());
    query.extend_from_slice(&1u16.to_be_bytes());
    query.extend_from_slice(&0u16.to_be_bytes());
    query.extend_from_slice(&0u16.to_be_bytes());
    query.extend_from_slice(&0u16.to_be_bytes());
    for label in host.split('.') {
        if label.is_empty() || label.len() > 63 || !label.is_ascii() {
            return Err("DNS name contains an invalid label".to_string());
        }
        query.push(label.len() as u8);
        query.extend_from_slice(label.as_bytes());
    }
    query.push(0);
    query.extend_from_slice(&1u16.to_be_bytes());
    query.extend_from_slice(&1u16.to_be_bytes());
    Ok(query)
}

fn skip_dns_name(packet: &[u8], mut offset: usize) -> Result<usize, String> {
    loop {
        let length = *packet
            .get(offset)
            .ok_or_else(|| "DNS name exceeds packet".to_string())?;
        if length == 0 {
            return Ok(offset + 1);
        }
        if length & 0xc0 == 0xc0 {
            if packet.get(offset + 1).is_none() {
                return Err("DNS compression pointer is truncated".to_string());
            }
            return Ok(offset + 2);
        }
        if length & 0xc0 != 0 {
            return Err("DNS name has an invalid label type".to_string());
        }
        offset = offset
            .checked_add(1 + length as usize)
            .ok_or_else(|| "DNS name offset overflow".to_string())?;
        if offset > packet.len() {
            return Err("DNS label exceeds packet".to_string());
        }
    }
}

fn dns_u16(packet: &[u8], offset: usize) -> Result<u16, String> {
    let bytes = packet
        .get(offset..offset + 2)
        .ok_or_else(|| "DNS field is truncated".to_string())?;
    Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
}

fn parse_dns_a_response(packet: &[u8], expected_id: u16) -> Result<Vec<Ipv4Addr>, String> {
    if packet.len() < 12 {
        return Err("DNS response is shorter than its header".to_string());
    }
    if dns_u16(packet, 0)? != expected_id {
        return Err("DNS response ID does not match the query".to_string());
    }
    let flags = dns_u16(packet, 2)?;
    if flags & 0x8000 == 0 {
        return Err("DNS packet is not a response".to_string());
    }
    if flags & 0x000f != 0 {
        return Err(format!("DNS response returned rcode {}", flags & 0x000f));
    }
    let questions = dns_u16(packet, 4)? as usize;
    let answers = dns_u16(packet, 6)? as usize;
    let mut offset = 12usize;
    for _ in 0..questions {
        offset = skip_dns_name(packet, offset)?;
        offset = offset
            .checked_add(4)
            .filter(|value| *value <= packet.len())
            .ok_or_else(|| "DNS question is truncated".to_string())?;
    }
    let mut addresses = Vec::new();
    for _ in 0..answers {
        offset = skip_dns_name(packet, offset)?;
        let record_type = dns_u16(packet, offset)?;
        let class = dns_u16(packet, offset + 2)?;
        let data_length = dns_u16(packet, offset + 8)? as usize;
        offset = offset
            .checked_add(10)
            .ok_or_else(|| "DNS answer offset overflow".to_string())?;
        let data = packet
            .get(offset..offset + data_length)
            .ok_or_else(|| "DNS answer data is truncated".to_string())?;
        if record_type == 1 && class == 1 && data.len() == 4 {
            addresses.push(Ipv4Addr::new(data[0], data[1], data[2], data[3]));
        }
        offset += data_length;
    }
    if addresses.is_empty() {
        return Err("DNS response contains no IPv4 address".to_string());
    }
    Ok(addresses)
}

fn query_ipv4_over_tls(
    resolver: &str,
    tls_name: &str,
    host: &str,
) -> Result<Vec<Ipv4Addr>, String> {
    let timeout = Duration::from_secs(8);
    let mut stream = None;
    let mut last_error = None;
    let resolver_addresses = resolver
        .to_socket_addrs()
        .map_err(|err| format!("invalid fallback DNS endpoint {}: {}", resolver, err))?;
    for address in resolver_addresses {
        match TcpStream::connect_timeout(&address, timeout) {
            Ok(candidate) => {
                stream = Some(candidate);
                break;
            }
            Err(err) => last_error = Some(err),
        }
    }
    let stream = stream.ok_or_else(|| {
        format!(
            "could not connect to fallback DNS {}: {}",
            resolver,
            last_error
                .map(|err| err.to_string())
                .unwrap_or_else(|| "no address".to_string())
        )
    })?;
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    let query_id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as u16;
    let query = build_dns_a_query(host, query_id)?;
    let mut framed_query = Vec::with_capacity(query.len() + 2);
    framed_query.extend_from_slice(&(query.len() as u16).to_be_bytes());
    framed_query.extend_from_slice(&query);
    let response = OpenSslApi::load()?.exchange(
        &stream,
        tls_name,
        &framed_query,
        TlsResponseMode::DnsFrame,
    )?;
    parse_dns_a_response(&response, query_id)
}

struct SocksServer {
    running: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    bind_addr: String,
    port: u16,
}

impl SocksServer {
    fn start(
        bind_addr: &str,
        port: u16,
        max_clients: usize,
        handshake_timeout_seconds: u64,
        io_timeout_seconds: u64,
        dns_fallback: SocksDnsFallback,
    ) -> Result<Self, String> {
        let bind = format!("{}:{}", bind_addr, port);
        let listener =
            TcpListener::bind(&bind).map_err(|err| format!("bind {} failed: {}", bind, err))?;
        listener
            .set_nonblocking(true)
            .map_err(|err| format!("set nonblocking {} failed: {}", bind, err))?;
        let running = Arc::new(AtomicBool::new(true));
        let accept_running = Arc::clone(&running);
        let dns_fallback = Arc::new(dns_fallback);
        let handle = thread::spawn(move || {
            socks_accept_loop(
                listener,
                accept_running,
                max_clients,
                handshake_timeout_seconds,
                io_timeout_seconds,
                dns_fallback,
            )
        });
        Ok(Self {
            running,
            handle: Some(handle),
            bind_addr: bind_addr.to_string(),
            port,
        })
    }

    fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
            && self
                .handle
                .as_ref()
                .map(|handle| !handle.is_finished())
                .unwrap_or(false)
    }

    fn stop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        let wake_host = match self.bind_addr.as_str() {
            "0.0.0.0" | "::" | "" => "127.0.0.1",
            other => other,
        };
        let _ = TcpStream::connect(format!("{}:{}", wake_host, self.port));
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for SocksServer {
    fn drop(&mut self) {
        self.stop();
    }
}

struct Supervisor {
    cfg: Config,
    sdk: Option<Sdk>,
    socks: Option<SocksServer>,
    last_watchdog: Instant,
    last_keepalive: Instant,
    health_failures: u32,
    data_plane_healthy: bool,
    data_plane_last_error: String,
    data_plane_last_checked: u64,
    data_plane_last_ok: u64,
    keepalive_last_run: u64,
    keepalive_last_ok: u64,
    keepalive_last_error: String,
}

impl Supervisor {
    fn new() -> Result<Self, String> {
        let cfg = Config::load();
        Ok(Self {
            cfg,
            sdk: None,
            socks: None,
            last_watchdog: Instant::now(),
            last_keepalive: Instant::now(),
            health_failures: 0,
            data_plane_healthy: false,
            data_plane_last_error: String::new(),
            data_plane_last_checked: 0,
            data_plane_last_ok: 0,
            keepalive_last_run: 0,
            keepalive_last_ok: 0,
            keepalive_last_error: String::new(),
        })
    }

    fn sdk_mut(&mut self) -> Result<&mut Sdk, String> {
        if self.sdk.is_none() {
            self.sdk = Some(Sdk::load(&self.cfg.sdk_path)?);
        }
        Ok(self.sdk.as_mut().expect("sdk loaded"))
    }

    fn sdk_free(&self, ptr: *mut c_void) {
        if let Some(sdk) = &self.sdk {
            sdk.free(ptr);
        }
    }

    fn pending_sms(&self) -> bool {
        self.sdk
            .as_ref()
            .map(|sdk| sdk.pending_sms)
            .unwrap_or(false)
    }

    fn pending_sms_time_remaining(&mut self) -> i64 {
        match self.sdk.as_mut() {
            Some(sdk) => sdk.pending_sms_time_remaining(&self.cfg),
            None => -1,
        }
    }

    fn mark_pending_sms(&mut self) {
        if let Ok(sdk) = self.sdk_mut() {
            sdk.mark_pending_sms();
        }
    }

    fn clear_pending_sms(&mut self) {
        if let Some(sdk) = self.sdk.as_mut() {
            sdk.clear_pending_sms();
        }
    }

    fn reload_env_file(&mut self) {
        self.cfg.load_env_file();
    }

    fn data_plane_probe_enabled(&self) -> bool {
        !self.cfg.health_dns_probe_host.is_empty() || !self.cfg.health_socks_probe_host.is_empty()
    }

    fn keepalive_enabled(&self) -> bool {
        self.cfg.keepalive_interval_seconds > 0 && !self.cfg.keepalive_urls().is_empty()
    }

    fn mark_data_plane_ok(&mut self) {
        let now = unix_time();
        self.data_plane_healthy = true;
        self.data_plane_last_error.clear();
        self.data_plane_last_checked = now;
        self.data_plane_last_ok = now;
    }

    fn mark_data_plane_failed(&mut self, err: &str) {
        self.data_plane_healthy = false;
        self.data_plane_last_error = err.to_string();
        self.data_plane_last_checked = unix_time();
    }

    fn check_and_record_data_plane(&mut self) -> Result<(), String> {
        let result = self.check_data_plane();
        match result {
            Ok(()) => {
                self.mark_data_plane_ok();
                Ok(())
            }
            Err(err) => {
                self.mark_data_plane_failed(&err);
                Err(err)
            }
        }
    }

    fn hard_reset_runtime(&mut self, reason: &str) {
        eprintln!("data-plane health hard reset: {}", reason);
        self.write_socks_gate_state("closed");
        self.reset_socks_proxy();
        self.stop_xtunnel();
        self.stop_core();
        if let Some(sdk) = self.sdk.as_mut() {
            sdk.reset_session();
        }
        self.sdk = None;
        self.clear_pending_sms();
        self.health_failures = 0;
        self.data_plane_healthy = false;
        self.data_plane_last_error = reason.to_string();
        self.data_plane_last_checked = unix_time();
    }

    fn expire_pending_sms_if_needed(&mut self) {
        if self.pending_sms_time_remaining() != 0 {
            return;
        }
        self.clear_pending_sms();
        self.stop_xtunnel();
        self.stop_core();
        self.reset_socks_proxy();
    }

    fn sdk_status(&mut self) -> Status {
        self.expire_pending_sms_if_needed();
        if !self.atrust_runtime_active() {
            return Status::idle(self.pending_sms());
        }
        let cfg = self.cfg.clone();
        let init = match self.sdk_mut() {
            Ok(sdk) => sdk.ensure_initial(&cfg),
            Err(_) => -1,
        };
        if init != 0 {
            return Status {
                sdk_code: init,
                connected: false,
                pending_sms: self.pending_sms(),
                user_status: 0,
                tunnel_status: 0,
            };
        }
        let mut out: *mut c_void = ptr::null_mut();
        let code = match self.sdk_mut() {
            Ok(sdk) => unsafe { (sdk.query_status)(&mut out) },
            Err(_) => -1,
        };
        let mut status = Status {
            sdk_code: code,
            connected: false,
            pending_sms: self.pending_sms(),
            user_status: 0,
            tunnel_status: 0,
        };
        if code == 0 && !out.is_null() {
            let fields = out as *const i32;
            unsafe {
                status.user_status = *fields;
                status.tunnel_status = *fields.add(1);
            }
            status.connected = status.tunnel_status == 2 || self.tunnel_device_ready();
            if status.connected && status.tunnel_status == 0 {
                status.tunnel_status = 2;
            }
            if status.connected {
                let _ = self.ensure_socks_proxy();
            }
        }
        self.sdk_free(out);
        status
    }

    fn connect_json(&mut self) -> String {
        if self.cfg.server.is_empty() {
            return failed_json("aTrust server is not configured", "missing-server", 0);
        }
        if self.cfg.username.is_empty() || self.cfg.password.is_empty() {
            return failed_json(
                "aTrust credentials are not configured",
                "missing-credentials",
                0,
            );
        }
        if self.ensure_core_started() == "failed" {
            return failed_json("aTrust core failed to start", "core-start-failed", 0);
        }
        if self.sdk_mut().is_err() {
            return failed_json("aTrust SDK load failed", "sdk-load-failed", 0);
        }
        self.wait_for_core_ready();
        let current = self.sdk_status();
        if current.connected {
            let _ = self.ensure_socks_proxy();
            if self.data_plane_probe_enabled() {
                match self.check_and_record_data_plane() {
                    Ok(()) => {
                        self.health_failures = 0;
                        self.signal_connected_hook();
                        return self.status_json(&current);
                    }
                    Err(err) => {
                        self.hard_reset_runtime(&format!(
                            "connect found stale SDK session: {}",
                            err
                        ));
                        if self.ensure_core_started() == "failed" {
                            return failed_json(
                                "aTrust core failed to start",
                                "core-start-failed",
                                0,
                            );
                        }
                        if self.sdk_mut().is_err() {
                            return failed_json("aTrust SDK load failed", "sdk-load-failed", 0);
                        }
                        self.wait_for_core_ready();
                    }
                }
            } else {
                self.signal_connected_hook();
                return self.status_json(&current);
            }
        }
        if self.pending_sms() {
            let ttl = self.pending_sms_time_remaining();
            return format!(
                "{{\"status\":\"sms_required\",\"message\":\"SMS verification code already pending\",\
                 \"blocker\":\"sms-code-required\",\"sdkCode\":{},\"nextAuth\":{},\
                 \"pendingSms\":true,\"pendingSmsExpiresIn\":{}}}",
                current.sdk_code, AUTH_SMS, ttl
            );
        }

        let mut candidates = Vec::new();
        if self.cfg.username.contains('@') {
            candidates.push(self.cfg.username.clone());
        } else if !self.cfg.domain.is_empty() {
            candidates.push(format!("{}@{}", self.cfg.username, self.cfg.domain));
            candidates.push(self.cfg.username.clone());
        } else {
            candidates.push(self.cfg.username.clone());
        }

        let mut last_code = 0;
        let mut last_next_auth = 0;
        for (index, candidate) in candidates.iter().enumerate() {
            let candidate_c = match CString::new(candidate.as_str()) {
                Ok(value) => value,
                Err(_) => continue,
            };
            let password_c = match CString::new(self.cfg.password.as_str()) {
                Ok(value) => value,
                Err(_) => {
                    return failed_json(
                        "aTrust credentials are not configured",
                        "invalid-credentials",
                        0,
                    )
                }
            };
            let mut next_auth: c_int = 0;
            let mut data: *mut c_void = ptr::null_mut();
            let sdk_offset = file_size(&self.cfg.sdk_api_log);
            let core_offset = file_size(DEFAULT_CORE_AGENT_LOG);
            let code = match self.sdk_mut() {
                Ok(sdk) => unsafe {
                    (sdk.login_pwd)(
                        candidate_c.as_ptr(),
                        password_c.as_ptr(),
                        1,
                        &mut next_auth,
                        &mut data,
                    )
                },
                Err(_) => return failed_json("aTrust SDK load failed", "sdk-load-failed", 0),
            };
            last_code = code;
            last_next_auth = next_auth;
            if code == 0 && next_auth == AUTH_SMS {
                let mut sms_data: *mut c_void = ptr::null_mut();
                let sms_code = match self.sdk_mut() {
                    Ok(sdk) => unsafe { (sdk.fetch_sms)(&mut sms_data) },
                    Err(_) => return failed_json("aTrust SDK load failed", "sdk-load-failed", 0),
                };
                self.sdk_free(sms_data);
                self.sdk_free(data);
                if sms_code == 0 || self.sms_log_success_since(sdk_offset, core_offset) {
                    self.mark_pending_sms();
                    let ttl = self.pending_sms_time_remaining();
                    return format!(
                        "{{\"status\":\"sms_required\",\"message\":\"SMS verification code sent\",\
                         \"blocker\":\"sms-code-required\",\"sdkCode\":{},\"nextAuth\":{},\
                         \"pendingSms\":true,\"pendingSmsExpiresIn\":{},\
                         \"auth\":{{\"sdkCode\":{},\"nextAuth\":{},\"candidate\":{}}}}}",
                        sms_code, AUTH_SMS, ttl, code, next_auth, index
                    );
                }
                return failed_json(
                    "aTrust SDK failed to request SMS verification code",
                    "sms-fetch-failed",
                    sms_code,
                );
            }
            self.sdk_free(data);
            if code == 0 && next_auth == AUTH_OK {
                let xtunnel = self.ensure_xtunnel_started();
                let connected = self.wait_for_connected();
                if connected.connected {
                    self.clear_pending_sms();
                    let socks = self.ensure_socks_proxy();
                    if let Err(err) = self.refresh_socks_gate() {
                        eprintln!(
                            "data-plane health failed immediately after password login: {}",
                            err
                        );
                    }
                    self.signal_connected_hook();
                    return format!(
                        "{{\"status\":\"connected\",\"message\":\"aTrust connected\",\"sdkCode\":{},\
                         \"connected\":true,\"pendingSms\":false,\"userStatus\":{},\"tunnelStatus\":{},\
                         \"xtunnel\":{{\"status\":\"{}\"}},\"socks\":{{\"status\":\"{}\"}}}}",
                        connected.sdk_code, connected.user_status, connected.tunnel_status, xtunnel, socks
                    );
                }
                return format!(
                    "{{\"status\":\"failed\",\"message\":\"aTrust password login returned OK but tunnel did not connect\",\
                     \"connected\":false,\"userStatus\":{},\"tunnelStatus\":{},\"xtunnel\":{{\"status\":\"{}\"}}}}",
                    connected.user_status, connected.tunnel_status, xtunnel
                );
            }
            if self.sms_log_success_since(sdk_offset, core_offset) {
                self.mark_pending_sms();
                let ttl = self.pending_sms_time_remaining();
                return format!(
                    "{{\"status\":\"sms_required\",\"message\":\"SMS verification code sent\",\
                     \"blocker\":\"sms-code-required\",\"sdkCode\":{},\"nextAuth\":{},\
                     \"pendingSms\":true,\"pendingSmsExpiresIn\":{},\
                     \"auth\":{{\"sdkCode\":{},\"nextAuth\":{},\"candidate\":{},\
                     \"source\":\"core-log\"}}}}",
                    code, AUTH_SMS, ttl, code, next_auth, index
                );
            }
        }
        format!(
            "{{\"status\":\"failed\",\"message\":\"aTrust password login failed\",\
             \"error\":\"password-login-failed\",\"sdkCode\":{},\"nextAuth\":{}}}",
            last_code, last_next_auth
        )
    }

    fn submit_sms_json(&mut self, code: &str) -> String {
        if self.cfg.server.is_empty() {
            return failed_json("aTrust server is not configured", "missing-server", 0);
        }
        if code.len() < 4 || code.len() > 8 || !code.chars().all(|ch| ch.is_ascii_digit()) {
            return failed_json("SMS code must be 4 to 8 digits", "invalid-sms-code", 0);
        }
        let current = self.sdk_status();
        if current.connected {
            let _ = self.ensure_socks_proxy();
            self.signal_connected_hook();
            return self.status_json(&current);
        }
        if !self.pending_sms() && !contains_process("aTrustAgent --plugin plugins/aTrustCore") {
            return format!(
                "{{\"status\":\"blocked\",\"message\":\"aTrust SMS session expired; request a new SMS code\",\
                 \"blocker\":\"sms-session-expired\",\"sdkCode\":{},\"connected\":false,\
                 \"pendingSms\":false,\"userStatus\":{},\"tunnelStatus\":{}}}",
                current.sdk_code, current.user_status, current.tunnel_status
            );
        }
        if !self.pending_sms() {
            self.mark_pending_sms();
        }
        if self.ensure_core_started() == "failed" {
            return failed_json("aTrust core failed to start", "core-start-failed", 0);
        }
        let code_c = match CString::new(code) {
            Ok(value) => value,
            Err(_) => return failed_json("SMS code must be 4 to 8 digits", "invalid-sms-code", 0),
        };
        let mut next_auth: c_int = 0;
        let mut data: *mut c_void = ptr::null_mut();
        let sdk_offset = file_size(&self.cfg.sdk_api_log);
        let core_offset = file_size(DEFAULT_CORE_AGENT_LOG);
        let sdk_code = match self.sdk_mut() {
            Ok(sdk) => unsafe { (sdk.login_sms)(code_c.as_ptr(), &mut next_auth, &mut data) },
            Err(_) => return failed_json("aTrust SDK load failed", "sdk-load-failed", 0),
        };
        self.sdk_free(data);
        if sdk_code != 0 {
            if self.sms_auth_success_since(sdk_offset, core_offset) {
                let xtunnel = self.ensure_xtunnel_started();
                let connected = self.wait_for_connected();
                if connected.connected {
                    self.clear_pending_sms();
                    let socks = self.ensure_socks_proxy();
                    if let Err(err) = self.refresh_socks_gate() {
                        eprintln!(
                            "data-plane health failed immediately after SMS login: {}",
                            err
                        );
                    }
                    self.signal_connected_hook();
                    return format!(
                        "{{\"status\":\"connected\",\"message\":\"aTrust connected\",\"sdkCode\":{},\
                         \"connected\":true,\"pendingSms\":false,\"userStatus\":{},\"tunnelStatus\":{},\
                         \"xtunnel\":{{\"status\":\"{}\"}},\"socks\":{{\"status\":\"{}\"}},\
                         \"auth\":{{\"source\":\"core-log\"}}}}",
                        sdk_code, connected.user_status, connected.tunnel_status, xtunnel, socks
                    );
                }
                return format!(
                    "{{\"status\":\"failed\",\"message\":\"aTrust SMS verification succeeded but tunnel did not connect\",\
                     \"connected\":false,\"userStatus\":{},\"tunnelStatus\":{},\"xtunnel\":{{\"status\":\"{}\"}},\
                     \"auth\":{{\"source\":\"core-log\"}}}}",
                    connected.user_status, connected.tunnel_status, xtunnel
                );
            }
            let ttl = self.pending_sms_time_remaining();
            return format!(
                "{{\"status\":\"failed\",\"message\":\"aTrust SMS verification failed\",\
                 \"error\":\"sms-login-failed\",\"sdkCode\":{},\"nextAuth\":{},\
                 \"pendingSms\":true,\"pendingSmsExpiresIn\":{}}}",
                sdk_code, next_auth, ttl
            );
        }
        if next_auth == AUTH_OK {
            let xtunnel = self.ensure_xtunnel_started();
            let connected = self.wait_for_connected();
            if connected.connected {
                self.clear_pending_sms();
                let socks = self.ensure_socks_proxy();
                if let Err(err) = self.refresh_socks_gate() {
                    eprintln!(
                        "data-plane health failed immediately after SMS login: {}",
                        err
                    );
                }
                self.signal_connected_hook();
                return format!(
                    "{{\"status\":\"connected\",\"message\":\"aTrust connected\",\"sdkCode\":{},\
                     \"connected\":true,\"pendingSms\":false,\"userStatus\":{},\"tunnelStatus\":{},\
                     \"xtunnel\":{{\"status\":\"{}\"}},\"socks\":{{\"status\":\"{}\"}}}}",
                    connected.sdk_code,
                    connected.user_status,
                    connected.tunnel_status,
                    xtunnel,
                    socks
                );
            }
            return format!(
                "{{\"status\":\"failed\",\"message\":\"aTrust SMS verification succeeded but tunnel did not connect\",\
                 \"connected\":false,\"userStatus\":{},\"tunnelStatus\":{},\"xtunnel\":{{\"status\":\"{}\"}}}}",
                connected.user_status, connected.tunnel_status, xtunnel
            );
        }
        if next_auth == AUTH_SMS {
            self.mark_pending_sms();
            let ttl = self.pending_sms_time_remaining();
            return format!(
                "{{\"status\":\"sms_required\",\"message\":\"aTrust still requires SMS verification\",\
                 \"blocker\":\"sms-code-required\",\"sdkCode\":{},\"nextAuth\":{},\
                 \"pendingSms\":true,\"pendingSmsExpiresIn\":{}}}",
                sdk_code, next_auth, ttl
            );
        }
        format!(
            "{{\"status\":\"blocked\",\"message\":\"aTrust requires an unsupported secondary authentication method\",\
             \"blocker\":\"unsupported-secondary-auth\",\"sdkCode\":{},\"nextAuth\":{}}}",
            sdk_code, next_auth
        )
    }

    fn disconnect_json(&mut self) -> String {
        let before = self.sdk_status();
        if !before.connected
            && !contains_process("aTrustAgent --plugin plugins/aTrustCore")
            && !contains_process("aTrustXtunnel-64")
        {
            self.clear_pending_sms();
            self.reset_socks_proxy();
            return format!(
                "{{\"status\":\"disconnected\",\"message\":\"aTrust disconnected\",\
                 \"sdkCode\":{},\"connected\":false,\"pendingSms\":false,\
                 \"userStatus\":{},\"tunnelStatus\":{},\
                 \"core\":{{\"status\":\"not-running\"}},\"xtunnel\":{{\"status\":\"not-running\"}}}}",
                before.sdk_code, before.user_status, before.tunnel_status
            );
        }
        let cfg = self.cfg.clone();
        let init = match self.sdk_mut() {
            Ok(sdk) => sdk.ensure_initial(&cfg),
            Err(_) => return failed_json("aTrust SDK load failed", "sdk-load-failed", 0),
        };
        if init != 0 {
            return failed_json(
                "aTrust SDK initialization failed",
                "sdk-initial-failed",
                init,
            );
        }
        let code = match self.sdk_mut() {
            Ok(sdk) => unsafe { (sdk.logout)() },
            Err(_) => return failed_json("aTrust SDK load failed", "sdk-load-failed", 0),
        };
        if code != 0 {
            return failed_json("aTrust logout failed", "logout-failed", code);
        }
        for _ in 0..8 {
            let current = self.sdk_status();
            if !current.connected {
                self.clear_pending_sms();
                let xtunnel = self.stop_xtunnel();
                let core = self.stop_core();
                self.reset_socks_proxy();
                return format!(
                    "{{\"status\":\"disconnected\",\"message\":\"aTrust disconnected\",\
                     \"sdkCode\":{},\"connected\":false,\"pendingSms\":false,\
                     \"userStatus\":{},\"tunnelStatus\":{},\
                     \"core\":{{\"status\":\"{}\"}},\"xtunnel\":{{\"status\":\"{}\"}}}}",
                    code, current.user_status, current.tunnel_status, core, xtunnel
                );
            }
            thread::sleep(Duration::from_secs(1));
        }
        self.hard_reset_runtime("disconnect could not verify SDK logout");
        format!(
            "{{\"status\":\"disconnected\",\"message\":\"aTrust runtime was force reset after logout verification failed\",\
             \"sdkCode\":{},\"connected\":false,\"pendingSms\":false,\
             \"userStatus\":0,\"tunnelStatus\":0,\
             \"core\":{{\"status\":\"force-reset\"}},\"xtunnel\":{{\"status\":\"force-reset\"}}}}",
            code
        )
    }

    fn status_json(&mut self, status: &Status) -> String {
        let ttl = self.pending_sms_time_remaining();
        if status.connected {
            match self.refresh_socks_gate() {
                Ok(()) => {
                    self.health_failures = 0;
                }
                Err(err) => {
                    self.health_failures = self.health_failures.saturating_add(1);
                    eprintln!("data-plane health failed during status refresh: {}", err);
                }
            }
        } else if !status.connected {
            self.data_plane_healthy = false;
        }
        let probes_enabled = self.data_plane_probe_enabled();
        let data_plane_status = if !probes_enabled {
            "disabled"
        } else if !status.connected {
            "down"
        } else if self.data_plane_last_checked == 0 {
            "unknown"
        } else if self.data_plane_healthy {
            "healthy"
        } else {
            "unhealthy"
        };
        let usable_connected = status.connected && data_plane_status != "unhealthy";
        let lifecycle_status = if status.connected && data_plane_status == "unhealthy" {
            "degraded"
        } else if status.connected {
            "connected"
        } else {
            "disconnected"
        };
        let message = if lifecycle_status == "degraded" {
            "aTrust SDK connected but data plane is unhealthy"
        } else if status.connected {
            "aTrust connected"
        } else {
            "aTrust disconnected"
        };
        format!(
            "{{\"status\":\"{}\",\"message\":\"{}\",\"sdkCode\":{},\"connected\":{},\
             \"sdkConnected\":{},\"pendingSms\":{},\"pendingSmsExpiresIn\":{},\
             \"userStatus\":{},\"tunnelStatus\":{},\
             \"dataPlane\":{{\"enabled\":{},\"status\":\"{}\",\"healthy\":{},\
             \"lastChecked\":{},\"lastOk\":{},\"failureCount\":{},\"lastError\":\"{}\"}},\
             \"keepAlive\":{{\"enabled\":{},\"intervalSeconds\":{},\"lastRun\":{},\
             \"lastOk\":{},\"lastError\":\"{}\"}},\
             \"socks\":{{\"activeClients\":{},\"maxClients\":{},\
             \"handshakeTimeoutSeconds\":{},\"ioTimeoutSeconds\":{}}}}}",
            lifecycle_status,
            message,
            status.sdk_code,
            json_bool(usable_connected),
            json_bool(status.connected),
            json_bool(status.pending_sms),
            ttl,
            status.user_status,
            status.tunnel_status,
            json_bool(probes_enabled),
            data_plane_status,
            json_bool(data_plane_status == "healthy" || data_plane_status == "disabled"),
            self.data_plane_last_checked,
            self.data_plane_last_ok,
            self.health_failures,
            json_escape(&self.data_plane_last_error),
            json_bool(self.keepalive_enabled()),
            self.cfg.keepalive_interval_seconds,
            self.keepalive_last_run,
            self.keepalive_last_ok,
            json_escape(&self.keepalive_last_error),
            ACTIVE_SOCKS_CLIENTS.load(Ordering::SeqCst),
            self.cfg.socks_max_clients,
            self.cfg.socks_handshake_timeout_seconds,
            self.cfg.socks_io_timeout_seconds
        )
    }

    fn ensure_core_started(&self) -> &'static str {
        if !env_flag_enabled("ATRUST_ON_DEMAND_CORE", true) {
            return "disabled";
        }
        if contains_process("aTrustAgent --plugin plugins/aTrustCore") {
            return "already-running";
        }
        let agent = format!("{}/aTrustAgent", self.cfg.vpn_bin);
        if !Path::new(&agent).exists() {
            return "failed";
        }
        let null = open_null();
        let mut cmd = Command::new(agent);
        cmd.arg("--plugin")
            .arg("plugins/aTrustCore")
            .arg("--enable-http")
            .arg("--enable-event-center")
            .stdin(null)
            .stdout(open_log(DEFAULT_CORE_AGENT_LOG))
            .stderr(open_log(DEFAULT_CORE_AGENT_LOG))
            .env("FAKE_LOGIN", "sangfor")
            .env("LD_PRELOAD", child_ld_preload())
            .env(
                "LD_LIBRARY_PATH",
                format!("{}:{}", self.cfg.vpn_root, self.cfg.vpn_bin),
            );
        unsafe {
            cmd.pre_exec(|| {
                setsid();
                Ok(())
            });
        }
        if cmd.spawn().is_err() {
            return "failed";
        }
        for _ in 0..20 {
            if contains_process("aTrustAgent --plugin plugins/aTrustCore") {
                return "started";
            }
            thread::sleep(Duration::from_millis(500));
        }
        "failed"
    }

    fn stop_core(&self) -> &'static str {
        if !env_flag_enabled("ATRUST_STOP_CORE_ON_DISCONNECT", true) {
            return "disabled";
        }
        if !contains_process("aTrustAgent --plugin plugins/aTrustCore") {
            return "not-running";
        }
        kill_matching_processes("aTrustAgent --plugin plugins/aTrustCore");
        "stopped"
    }

    fn ensure_xtunnel_started(&self) -> &'static str {
        if !env_flag_enabled("ATRUST_ON_DEMAND_XTUNNEL", true) {
            return "disabled";
        }
        if contains_process("aTrustXtunnel-64") {
            return "already-running";
        }
        let xtunnel = format!("{}/aTrustXtunnel-64", self.cfg.vpn_bin);
        if !Path::new(&xtunnel).exists() {
            return "failed";
        }
        let null = open_null();
        let mut cmd = Command::new(xtunnel);
        cmd.stdin(null)
            .stdout(open_log("/root/.tunlet/xtunnel.log"))
            .stderr(open_log("/root/.tunlet/xtunnel.log"))
            .env("FAKE_LOGIN", "sangfor")
            .env("LD_PRELOAD", child_ld_preload())
            .env(
                "LD_LIBRARY_PATH",
                format!("{}:{}", self.cfg.vpn_root, self.cfg.vpn_bin),
            );
        unsafe {
            cmd.pre_exec(|| {
                setsid();
                Ok(())
            });
        }
        if cmd.spawn().is_err() {
            return "failed";
        }
        for _ in 0..10 {
            if contains_process("aTrustXtunnel-64") {
                return "started";
            }
            thread::sleep(Duration::from_millis(500));
        }
        "failed"
    }

    fn stop_xtunnel(&self) -> &'static str {
        if !env_flag_enabled("ATRUST_STOP_XTUNNEL_ON_DISCONNECT", true) {
            return "disabled";
        }
        if !contains_process("aTrustXtunnel-64") {
            return "not-running";
        }
        kill_matching_processes("aTrustXtunnel-64");
        "stopped"
    }

    fn ensure_socks_proxy(&mut self) -> &'static str {
        if !env_flag_enabled("ATRUST_ENABLE_SOCKS_PROXY", true) {
            self.write_socks_gate_state("closed");
            return "disabled";
        }
        if self
            .socks
            .as_ref()
            .map(|socks| socks.is_running())
            .unwrap_or(false)
        {
            return "already-running";
        }
        kill_matching_processes("/opt/tunlet/microsocks");
        kill_matching_processes("/usr/bin/microsocks");
        match SocksServer::start(
            &self.cfg.socks_bind,
            self.cfg.socks_port,
            self.cfg.socks_max_clients,
            self.cfg.socks_handshake_timeout_seconds,
            self.cfg.socks_io_timeout_seconds,
            self.cfg.socks_dns_fallback(),
        ) {
            Ok(socks) => self.socks = Some(socks),
            Err(_) => {
                self.write_socks_gate_state("closed");
                return "failed";
            }
        }
        "started"
    }

    fn refresh_socks_gate(&mut self) -> Result<(), String> {
        let socks = self.ensure_socks_proxy();
        if matches!(socks, "disabled" | "failed") {
            self.write_socks_gate_state("closed");
            return Err(format!("embedded SOCKS is {}", socks));
        }
        if !self.data_plane_probe_enabled() {
            self.write_socks_gate_state("open");
            return Ok(());
        }
        match self.check_and_record_data_plane() {
            Ok(()) => {
                self.write_socks_gate_state("open");
                Ok(())
            }
            Err(err) => {
                self.write_socks_gate_state("closed");
                Err(err)
            }
        }
    }

    fn reset_socks_proxy(&mut self) -> &'static str {
        let had_socks = self.socks.is_some();
        if let Some(mut socks) = self.socks.take() {
            socks.stop();
        }
        kill_matching_processes("/opt/tunlet/microsocks");
        kill_matching_processes("/usr/bin/microsocks");
        self.write_socks_gate_state("closed");
        if had_socks {
            "stopped"
        } else {
            self.write_socks_gate_state("closed");
            "not-running"
        }
    }

    fn write_socks_gate_state(&self, state: &str) {
        if self.cfg.socks_gate_state_file.is_empty() {
            return;
        }
        if fs::read_to_string(&self.cfg.socks_gate_state_file)
            .map(|current| current.trim().eq_ignore_ascii_case(state))
            .unwrap_or(false)
        {
            return;
        }
        if let Some(parent) = Path::new(&self.cfg.socks_gate_state_file).parent() {
            let _ = fs::create_dir_all(parent);
        }
        let tmp = format!(
            "{}.tmp.{}",
            self.cfg.socks_gate_state_file,
            std::process::id()
        );
        if fs::write(&tmp, format!("{}\n", state)).is_ok() {
            let _ = fs::rename(tmp, &self.cfg.socks_gate_state_file);
        }
    }

    fn signal_connected_hook(&self) {
        if self.cfg.connected_signal_file.is_empty() {
            return;
        }
        if let Some(parent) = Path::new(&self.cfg.connected_signal_file).parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.cfg.connected_signal_file)
        {
            let _ = writeln!(file, "{} connected", unix_time());
        }
    }

    fn wait_for_connected(&mut self) -> Status {
        for _ in 0..12 {
            let current = self.sdk_status();
            if current.connected {
                dedupe_atrust_dns_rule();
                return current;
            }
            thread::sleep(Duration::from_secs(1));
        }
        let status = self.sdk_status();
        if status.connected {
            dedupe_atrust_dns_rule();
        }
        status
    }

    fn wait_for_core_ready(&mut self) {
        for _ in 0..8 {
            let current = self.sdk_status();
            if current.sdk_code == 0 && (current.user_status != 0 || current.tunnel_status != 0) {
                return;
            }
            thread::sleep(Duration::from_millis(500));
        }
    }

    fn atrust_runtime_active(&self) -> bool {
        self.pending_sms()
            || contains_process("aTrustAgent --plugin plugins/aTrustCore")
            || contains_process("aTrustXtunnel-64")
    }

    fn watchdog_tick_if_due(&mut self) {
        if self.cfg.watchdog_interval_seconds == 0 {
            return;
        }
        if self.last_watchdog.elapsed()
            < Duration::from_secs(self.cfg.watchdog_interval_seconds.max(5))
        {
            return;
        }
        self.last_watchdog = Instant::now();
        let status = self.sdk_status();
        if status.connected {
            match self.refresh_socks_gate() {
                Ok(()) => {
                    if self.health_failures > 0 {
                        eprintln!(
                            "data-plane health recovered after {} failed check(s)",
                            self.health_failures
                        );
                    }
                    self.health_failures = 0;
                    self.write_socks_gate_state("open");
                    if let Err(err) = self.keepalive_tick_if_due() {
                        eprintln!("keepalive request failed: {}", err);
                    }
                }
                Err(err) => {
                    self.health_failures = self.health_failures.saturating_add(1);
                    self.write_socks_gate_state("closed");
                    eprintln!(
                        "data-plane health failed ({}/{}): {}",
                        self.health_failures, self.cfg.health_failure_threshold, err
                    );
                    if self.health_failures >= self.cfg.health_failure_threshold.max(1) {
                        self.recover_data_plane(&err);
                    }
                }
            }
            return;
        }
        self.health_failures = 0;
        if status.pending_sms {
            self.write_socks_gate_state("closed");
            return;
        }
        if self.socks.is_some()
            || contains_process("aTrustAgent --plugin plugins/aTrustCore")
            || contains_process("aTrustXtunnel-64")
        {
            self.clear_pending_sms();
            self.stop_xtunnel();
            self.stop_core();
            self.reset_socks_proxy();
        }
    }

    fn check_data_plane(&self) -> Result<(), String> {
        if self.cfg.health_dns_probe_host.is_empty() && self.cfg.health_socks_probe_host.is_empty()
        {
            return Ok(());
        }
        if !self.tunnel_device_ready() {
            return Err(format!("{} is not ready", self.cfg.vpn_tun));
        }
        if !self.cfg.health_dns_probe_host.is_empty() {
            self.probe_atrust_dns(&self.cfg.health_dns_probe_host)?;
        }
        if !self.cfg.health_socks_probe_host.is_empty() {
            self.probe_socks_connect(
                &self.cfg.health_socks_probe_host,
                self.cfg.health_socks_probe_port,
            )?;
        }
        Ok(())
    }

    fn keepalive_tick_if_due(&mut self) -> Result<(), String> {
        if !self.keepalive_enabled() {
            return Ok(());
        }
        let interval = self.cfg.keepalive_interval_seconds.max(10);
        if self.last_keepalive.elapsed() < Duration::from_secs(interval) {
            return Ok(());
        }
        self.last_keepalive = Instant::now();
        self.keepalive_last_run = unix_time();
        match self.run_keepalive_requests() {
            Ok(()) => {
                self.keepalive_last_ok = self.keepalive_last_run;
                self.keepalive_last_error.clear();
                Ok(())
            }
            Err(err) => {
                self.keepalive_last_error = err.clone();
                Err(err)
            }
        }
    }

    fn run_keepalive_requests(&self) -> Result<(), String> {
        let urls = self.cfg.keepalive_urls();
        let mut failures = Vec::new();
        for url in urls {
            match self.run_keepalive_request(&url) {
                Ok(()) => return Ok(()),
                Err(err) => failures.push(format!("{} ({})", url, err)),
            }
        }
        Err(failures.join("; "))
    }

    fn run_keepalive_request(&self, url: &str) -> Result<(), String> {
        let target = parse_keepalive_target(url)?;
        let mut stream = self.open_socks_tunnel_with_timeout(
            &target.host,
            target.port,
            self.cfg.keepalive_timeout_seconds,
        )?;
        let request = target.request();
        if target.tls {
            return OpenSslApi::load()?.send_request(&stream, &target.host, request.as_bytes());
        }

        stream
            .write_all(request.as_bytes())
            .map_err(|err| format!("HTTP keepalive request write failed: {}", err))?;
        let mut response = [0u8; 4096];
        let count = stream
            .read(&mut response)
            .map_err(|err| format!("HTTP keepalive response read failed: {}", err))?;
        validate_http_response(&response[..count])
    }

    fn recover_data_plane(&mut self, reason: &str) {
        eprintln!(
            "data-plane health exceeded threshold; resetting xtunnel and socks: {}",
            reason
        );
        self.write_socks_gate_state("closed");
        self.reset_socks_proxy();
        self.stop_xtunnel();
        thread::sleep(Duration::from_secs(2));
        let xtunnel = self.ensure_xtunnel_started();
        let status = self.wait_for_connected();
        if status.connected {
            let socks = self.ensure_socks_proxy();
            self.write_socks_gate_state("closed");
            match self.check_and_record_data_plane() {
                Ok(()) => {
                    self.health_failures = 0;
                    self.write_socks_gate_state("open");
                    eprintln!(
                        "data-plane health recovered after xtunnel reset ({}, socks {})",
                        xtunnel, socks
                    );
                }
                Err(err) => {
                    self.health_failures = 0;
                    self.write_socks_gate_state("closed");
                    eprintln!(
                        "data-plane health is still unhealthy after xtunnel reset ({}, socks {}); preserving SDK session: {}",
                        xtunnel, socks, err
                    );
                }
            }
        } else {
            self.health_failures = 0;
            self.write_socks_gate_state("closed");
            self.stop_xtunnel();
            eprintln!(
                "SDK is disconnected after xtunnel reset ({}); leaving session cleanup to the disconnected-state watchdog",
                xtunnel
            );
        }
    }

    fn probe_atrust_dns(&self, host: &str) -> Result<(), String> {
        if !Path::new(&self.cfg.health_dns_query_bin).exists() {
            return Err(format!(
                "DNS probe binary missing: {}",
                self.cfg.health_dns_query_bin
            ));
        }
        let upstream_port = self.cfg.health_dns_upstream_port.to_string();
        let timeout = self.cfg.health_probe_timeout_seconds.max(1).to_string();
        let output = Command::new(&self.cfg.health_dns_query_bin)
            .arg(host)
            .arg(&self.cfg.health_dns_upstream_host)
            .arg(upstream_port)
            .arg(timeout)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .map_err(|err| format!("DNS probe failed to start: {}", err))?;
        if !output.status.success() {
            return Err(format!(
                "DNS probe for {} exited with {}",
                host, output.status
            ));
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        if !contains_ipv4_literal(&stdout) {
            return Err(format!("DNS probe for {} returned no IPv4 address", host));
        }
        Ok(())
    }

    fn probe_socks_connect(&self, host: &str, port: u16) -> Result<(), String> {
        self.probe_socks_connect_with_timeout(host, port, self.cfg.health_probe_timeout_seconds)
    }

    fn probe_socks_connect_with_timeout(
        &self,
        host: &str,
        port: u16,
        timeout_seconds: u64,
    ) -> Result<(), String> {
        self.open_socks_tunnel_with_timeout(host, port, timeout_seconds)
            .map(|_| ())
    }

    fn open_socks_tunnel_with_timeout(
        &self,
        host: &str,
        port: u16,
        timeout_seconds: u64,
    ) -> Result<TcpStream, String> {
        let proxy = format!(
            "{}:{}",
            self.cfg.health_socks_proxy_host, self.cfg.socks_port
        );
        let timeout = Duration::from_secs(timeout_seconds.max(1));
        let mut last_err = None;
        for addr in proxy
            .to_socket_addrs()
            .map_err(|err| format!("SOCKS probe proxy address {} failed: {}", proxy, err))?
        {
            match TcpStream::connect_timeout(&addr, timeout) {
                Ok(mut stream) => {
                    let _ = stream.set_read_timeout(Some(timeout));
                    let _ = stream.set_write_timeout(Some(timeout));
                    stream
                        .write_all(&[0x05, 0x01, 0x00])
                        .map_err(|err| format!("SOCKS probe greeting write failed: {}", err))?;
                    let mut greeting = [0u8; 2];
                    stream
                        .read_exact(&mut greeting)
                        .map_err(|err| format!("SOCKS probe greeting read failed: {}", err))?;
                    if greeting != [0x05, 0x00] {
                        return Err(format!("SOCKS probe rejected method: {:02x?}", greeting));
                    }
                    let host_bytes = host.as_bytes();
                    if host_bytes.len() > u8::MAX as usize {
                        return Err(format!("SOCKS probe host is too long: {}", host));
                    }
                    let mut request = Vec::with_capacity(7 + host_bytes.len());
                    request.extend_from_slice(&[0x05, 0x01, 0x00, 0x03, host_bytes.len() as u8]);
                    request.extend_from_slice(host_bytes);
                    request.extend_from_slice(&port.to_be_bytes());
                    stream
                        .write_all(&request)
                        .map_err(|err| format!("SOCKS probe request write failed: {}", err))?;
                    let mut reply = [0u8; 10];
                    stream
                        .read_exact(&mut reply)
                        .map_err(|err| format!("SOCKS probe reply read failed: {}", err))?;
                    if reply[0] == 0x05 && reply[1] == 0x00 {
                        return Ok(stream);
                    }
                    return Err(format!(
                        "SOCKS probe connect to {}:{} returned code {}",
                        host, port, reply[1]
                    ));
                }
                Err(err) => last_err = Some(err),
            }
        }
        Err(format!(
            "SOCKS probe could not connect to proxy {}: {}",
            proxy,
            last_err
                .map(|err| err.to_string())
                .unwrap_or_else(|| "no proxy address".to_string())
        ))
    }

    fn tunnel_device_ready(&self) -> bool {
        if !contains_process("aTrustXtunnel-64") {
            return false;
        }
        Path::new(&format!("/sys/class/net/{}", self.cfg.vpn_tun)).exists()
    }

    fn sms_log_success_since(&self, sdk_offset: u64, core_offset: u64) -> bool {
        sms_log_success_in_file_since(&self.cfg.sdk_api_log, sdk_offset)
            || sms_log_success_in_file_since(DEFAULT_CORE_AGENT_LOG, core_offset)
    }

    fn sms_auth_success_since(&self, sdk_offset: u64, core_offset: u64) -> bool {
        sms_auth_success_in_file_since(&self.cfg.sdk_api_log, sdk_offset)
            || sms_auth_success_in_file_since(DEFAULT_CORE_AGENT_LOG, core_offset)
    }

    fn serve_forever(&mut self) -> i32 {
        let bind = format!("{}:{}", self.cfg.bind_addr, self.cfg.port);
        let listener = match TcpListener::bind(&bind) {
            Ok(listener) => listener,
            Err(err) => {
                eprintln!("bind {} failed: {}", bind, err);
                return 1;
            }
        };
        let _ = listener.set_nonblocking(true);
        eprintln!("Tunlet supervisor listening on {}", bind);
        while !TERMINATE.load(Ordering::SeqCst) {
            self.expire_pending_sms_if_needed();
            self.watchdog_tick_if_due();
            reap_children();
            match listener.accept() {
                Ok((stream, _)) => self.handle_client(stream),
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    let sleep_ms = match self.pending_sms_time_remaining() {
                        n if n > 0 => n.min(1) as u64 * 1000,
                        0 => 50,
                        _ => 250,
                    };
                    thread::sleep(Duration::from_millis(sleep_ms));
                }
                Err(err) => {
                    eprintln!("accept failed: {}", err);
                    thread::sleep(Duration::from_millis(250));
                }
            }
        }
        self.cleanup();
        0
    }

    fn handle_client(&mut self, mut stream: TcpStream) {
        let mut request = Vec::new();
        let mut buf = [0u8; 4096];
        let _ = stream.set_read_timeout(Some(Duration::from_secs(120)));
        loop {
            match stream.read(&mut buf) {
                Ok(0) => return,
                Ok(n) => {
                    request.extend_from_slice(&buf[..n]);
                    if request.windows(4).any(|w| w == b"\r\n\r\n") {
                        let length = content_length(&request);
                        if body_len(&request) >= length {
                            break;
                        }
                    }
                    if request.len() > 65536 {
                        send_response(&mut stream, 400, "{\"error\":\"request too large\"}");
                        return;
                    }
                }
                Err(_) => return,
            }
        }
        let text = String::from_utf8_lossy(&request);
        let mut first = text.lines().next().unwrap_or("").split_whitespace();
        let method = first.next().unwrap_or("");
        let path = first.next().unwrap_or("");
        if path == "/healthz" && method == "GET" {
            send_response(&mut stream, 200, "{\"status\":\"ok\"}");
            return;
        }
        self.reload_env_file();
        if !authorized(&text, &self.cfg.token) {
            send_response(&mut stream, 401, "{\"error\":\"unauthorized\"}");
            return;
        }
        let response = match (method, path) {
            ("GET", "/status") => {
                let status = self.sdk_status();
                self.status_json(&status)
            }
            ("POST", "/connect") => self.connect_json(),
            ("POST", "/submit-sms") => {
                let body = request_body(&request);
                let code = extract_sms_code(body);
                self.submit_sms_json(&code)
            }
            ("POST", "/disconnect") => self.disconnect_json(),
            _ => {
                send_response(&mut stream, 404, "{\"error\":\"not found\"}");
                return;
            }
        };
        send_response(&mut stream, 200, &response);
    }

    fn cleanup(&mut self) {
        self.reset_socks_proxy();
        kill_matching_processes("aTrustAgent --plugin plugins/aTrustCore");
        kill_matching_processes("aTrustAgent --plugin plugin-daemon");
        kill_matching_processes("aTrustXtunnel-64");
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mode = args.get(1).map(|s| s.as_str()).unwrap_or("run");
    if mode == "run" {
        unsafe {
            signal(SIGTERM, handle_signal);
            signal(SIGINT, handle_signal);
        }
    }

    if mode == "run" {
        configure_runtime_from_env();
    }

    let mut supervisor = match Supervisor::new() {
        Ok(supervisor) => supervisor,
        Err(err) => {
            eprintln!("{}", err);
            std::process::exit(2);
        }
    };

    let exit_code = match mode {
        "run" | "serve" => supervisor.serve_forever(),
        "status" => {
            let status = supervisor.sdk_status();
            println!("{}", supervisor.status_json(&status));
            0
        }
        "connect" => {
            println!("{}", supervisor.connect_json());
            0
        }
        "disconnect" => {
            println!("{}", supervisor.disconnect_json());
            0
        }
        other => {
            eprintln!("unsupported mode {}", other);
            2
        }
    };
    std::process::exit(exit_code);
}

fn configure_runtime_from_env() {
    let state_dir = env_value("ATRUST_STATE_DIR", DEFAULT_STATE_DIR);
    let _ = fs::create_dir_all(&state_dir);
    let _ = fs::create_dir_all("/run");
    let state_env = format!("{}/helper.env", state_dir);
    env::set_var(
        "TUNLET_HELPER_ENV_FILE",
        env_value("TUNLET_HELPER_ENV_FILE", &state_env),
    );
    env::set_var(
        "ATRUST_CONNECTED_SIGNAL_FILE",
        env_value(
            "ATRUST_CONNECTED_SIGNAL_FILE",
            &format!("{}/connected.request", state_dir),
        ),
    );
    env::set_var(
        "TUNLET_SOCKS_GATE_STATE_FILE",
        env_value(
            "TUNLET_SOCKS_GATE_STATE_FILE",
            &format!("{}/socks-gate.state", state_dir),
        ),
    );
    env::set_var("SANGFOR_ROOT", "/usr/share/sangfor");
    env::set_var("VPN_ROOT", DEFAULT_VPN_ROOT);
    env::set_var("VPN_RESOURCES", "/usr/share/sangfor/aTrust/resources");
    env::set_var("VPN_BIN", DEFAULT_VPN_BIN);
    env::set_var("VPN_CONF", "/usr/share/sangfor/aTrust/resources/conf");
    let current_ld = env::var("LD_LIBRARY_PATH").unwrap_or_default();
    env::set_var(
        "LD_LIBRARY_PATH",
        if current_ld.is_empty() {
            format!("{}:{}", DEFAULT_VPN_ROOT, DEFAULT_VPN_BIN)
        } else {
            format!("{}:{}:{}", DEFAULT_VPN_ROOT, DEFAULT_VPN_BIN, current_ld)
        },
    );

    configure_resolver_from_env();
    configure_hosts_from_env();
    configure_vpn_iptables_for_tun(&env_value("VPN_TUN", "utun7"));
}

fn configure_resolver_from_env() {
    let primary = env_value("ATRUST_BOOTSTRAP_DNS_PRIMARY", "223.5.5.5");
    let secondary = env_value("ATRUST_BOOTSTRAP_DNS_SECONDARY", "119.29.29.29");
    let content = format!(
        "nameserver {}\nnameserver {}\noptions ndots:1 timeout:1 attempts:1\n",
        primary, secondary
    );
    let _ = fs::write("/etc/resolv.conf", content);
}

fn configure_hosts_from_env() {
    replace_hosts_block(
        "# tunlet-static-hosts begin",
        "# tunlet-static-hosts end",
        &env_value("ATRUST_STATIC_HOSTS", ""),
    );
    replace_hosts_block(
        "# tunlet-bootstrap begin",
        "# tunlet-bootstrap end",
        &env_value("ATRUST_BOOTSTRAP_HOSTS", ""),
    );
}

fn configure_vpn_iptables_for_tun(vpn_tun: &str) {
    command_ok("iptables", &["-t", "nat", "-N", "SANGFOR_OUTPUT"]);
    ensure_command_rule(
        "iptables",
        &[
            "-t",
            "nat",
            "-C",
            "POSTROUTING",
            "-o",
            vpn_tun,
            "-j",
            "MASQUERADE",
        ],
        &[
            "-t",
            "nat",
            "-A",
            "POSTROUTING",
            "-o",
            vpn_tun,
            "-j",
            "MASQUERADE",
        ],
    );
    ensure_command_rule(
        "iptables",
        &["-t", "nat", "-C", "PREROUTING", "-j", "SANGFOR_OUTPUT"],
        &["-t", "nat", "-A", "PREROUTING", "-j", "SANGFOR_OUTPUT"],
    );
    ensure_command_rule(
        "iptables",
        &[
            "-C",
            "INPUT",
            "-m",
            "state",
            "--state",
            "ESTABLISHED,RELATED",
            "-j",
            "ACCEPT",
        ],
        &[
            "-A",
            "INPUT",
            "-m",
            "state",
            "--state",
            "ESTABLISHED,RELATED",
            "-j",
            "ACCEPT",
        ],
    );
    ensure_command_rule(
        "iptables",
        &["-C", "INPUT", "-i", vpn_tun, "-p", "tcp", "-j", "DROP"],
        &["-A", "INPUT", "-i", vpn_tun, "-p", "tcp", "-j", "DROP"],
    );
    configure_policy_route_for_tun(vpn_tun);
    dedupe_atrust_dns_rule();
}

fn configure_policy_route_for_tun(vpn_tun: &str) {
    command_ok("ip", &["route", "flush", "table", "2"]);
    if let Some(routes) = command_output("ip", &["route", "show"]) {
        for line in routes.lines() {
            let mut args: Vec<&str> = vec!["route", "add"];
            args.extend(line.split_whitespace());
            args.extend(["table", "2"]);
            command_ok("ip", &args);
        }
    }
    if !ip_rule_exists(&format!("iif {} lookup 2", vpn_tun)) {
        command_ok("ip", &["rule", "add", "iif", vpn_tun, "table", "2"]);
    }
    command_ok(
        "ip",
        &["rule", "del", "iif", "lo", "sport", "4440", "table", "2"],
    );
    command_ok(
        "ip",
        &["rule", "add", "iif", "lo", "sport", "4440", "table", "2"],
    );
}

fn ip_rule_exists(needle: &str) -> bool {
    command_output("ip", &["rule", "show"])
        .map(|rules| rules.lines().any(|line| line.contains(needle)))
        .unwrap_or(false)
}

fn dedupe_atrust_dns_rule() {
    let save = match command_output("iptables-save", &[]) {
        Some(save) => save,
        None => return,
    };
    if !save.contains(":ATRUST_BLOCK_DNS") {
        return;
    }
    while command_ok("iptables", &["-D", "OUTPUT", "-j", "ATRUST_BLOCK_DNS"]) {}
    command_ok("iptables", &["-I", "OUTPUT", "1", "-j", "ATRUST_BLOCK_DNS"]);
}

fn env_value(name: &str, fallback: &str) -> String {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| fallback.to_string())
}

fn trim_env_value(value: &str) -> String {
    let mut out = value.trim().to_string();
    if out.len() >= 2 {
        let bytes = out.as_bytes();
        if (bytes[0] == b'\'' && bytes[out.len() - 1] == b'\'')
            || (bytes[0] == b'"' && bytes[out.len() - 1] == b'"')
        {
            out = out[1..out.len() - 1].to_string();
        }
    }
    out
}

fn json_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if ch < ' ' => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out
}

fn failed_json(message: &str, error: &str, sdk_code: i32) -> String {
    format!(
        "{{\"status\":\"failed\",\"message\":\"{}\",\"error\":\"{}\",\"sdkCode\":{}}}",
        message, error, sdk_code
    )
}

fn json_bool(value: bool) -> &'static str {
    if value {
        "true"
    } else {
        "false"
    }
}

fn contains_ipv4_literal(value: &str) -> bool {
    value
        .split(|ch: char| !(ch.is_ascii_digit() || ch == '.'))
        .any(|part| part.parse::<Ipv4Addr>().is_ok())
}

fn dl_error() -> String {
    let ptr = unsafe { dlerror() };
    if ptr.is_null() {
        return "unknown dlerror".to_string();
    }
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

fn load_symbol<T: Copy>(handle: *mut c_void, name: &str) -> Result<T, String> {
    let c_name = CString::new(name).map_err(|_| format!("invalid symbol name {}", name))?;
    let symbol = unsafe { dlsym(handle, c_name.as_ptr()) };
    if symbol.is_null() {
        return Err(format!("missing dynamic symbol {}: {}", name, dl_error()));
    }
    Ok(unsafe { mem::transmute_copy(&symbol) })
}

fn file_size(path: &str) -> u64 {
    fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

fn sms_log_success_in_file_since(path: &str, offset: u64) -> bool {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(_) => return false,
    };
    if offset > 0 {
        use std::io::Seek;
        let _ = file.seek(std::io::SeekFrom::Start(offset));
    }
    let mut buffer = String::new();
    let _ = file.take(65536).read_to_string(&mut buffer);
    buffer.contains("SMS message sent successfully")
        || buffer.contains("Your verification code is still valid")
        || buffer.contains("\"code\":75500401")
}

fn sms_auth_success_in_file_since(path: &str, offset: u64) -> bool {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(_) => return false,
    };
    if offset > 0 {
        use std::io::Seek;
        let _ = file.seek(std::io::SeekFrom::Start(offset));
    }
    let mut buffer = String::new();
    let _ = file.take(65536).read_to_string(&mut buffer);
    buffer.contains("SMS authentication succeeded") || buffer.contains("\"isOnline\":true")
}

fn contains_process(needle: &str) -> bool {
    process_ids_matching(needle, false).next().is_some()
}

fn kill_matching_processes(needle: &str) {
    let pids: Vec<i32> = process_ids_matching(needle, true).collect();
    for pid in pids {
        unsafe {
            kill(pid, SIGTERM);
        }
    }
}

fn process_ids_matching(needle: &str, skip_self: bool) -> impl Iterator<Item = i32> + '_ {
    let self_pid = std::process::id() as i32;
    let entries = fs::read_dir("/proc").into_iter().flatten();
    entries.filter_map(move |entry| {
        let entry = entry.ok()?;
        let pid: i32 = entry.file_name().to_string_lossy().parse().ok()?;
        if pid <= 1 || (skip_self && pid == self_pid) {
            return None;
        }
        let mut cmdline = fs::read(format!("/proc/{}/cmdline", pid)).ok()?;
        if cmdline.is_empty() {
            return None;
        }
        for byte in &mut cmdline {
            if *byte == 0 {
                *byte = b' ';
            }
        }
        let cmdline = String::from_utf8_lossy(&cmdline);
        if cmdline.contains(needle) {
            Some(pid)
        } else {
            None
        }
    })
}

fn open_log(path: &str) -> Stdio {
    if let Some(parent) = Path::new(path).parent() {
        let _ = fs::create_dir_all(parent);
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map(Stdio::from)
        .unwrap_or_else(|_| Stdio::null())
}

fn open_null() -> Stdio {
    File::open("/dev/null")
        .map(Stdio::from)
        .unwrap_or_else(|_| Stdio::null())
}

struct ActiveSocksClient;

impl Drop for ActiveSocksClient {
    fn drop(&mut self) {
        ACTIVE_SOCKS_CLIENTS.fetch_sub(1, Ordering::SeqCst);
    }
}

fn socks_accept_loop(
    listener: TcpListener,
    running: Arc<AtomicBool>,
    max_clients: usize,
    handshake_timeout_seconds: u64,
    io_timeout_seconds: u64,
    dns_fallback: Arc<SocksDnsFallback>,
) {
    let mut last_capacity_log = None;
    let mut rejected_since_log = 0usize;
    while running.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, peer)) => {
                if !running.load(Ordering::SeqCst) {
                    break;
                }
                let active = ACTIVE_SOCKS_CLIENTS.fetch_add(1, Ordering::SeqCst);
                if !socks_client_allowed(active, max_clients, peer.ip().is_loopback()) {
                    ACTIVE_SOCKS_CLIENTS.fetch_sub(1, Ordering::SeqCst);
                    rejected_since_log = rejected_since_log.saturating_add(1);
                    let should_log = last_capacity_log
                        .map(|last: Instant| last.elapsed() >= Duration::from_secs(5))
                        .unwrap_or(true);
                    if should_log {
                        eprintln!(
                            "socks client rejected: max clients {} reached ({} rejected since previous log)",
                            max_clients, rejected_since_log
                        );
                        last_capacity_log = Some(Instant::now());
                        rejected_since_log = 0;
                    }
                    let _ = stream.shutdown(Shutdown::Both);
                    continue;
                }
                let dns_fallback = Arc::clone(&dns_fallback);
                thread::spawn(move || {
                    let _active = ActiveSocksClient;
                    if let Err(err) = handle_socks_client(
                        stream,
                        handshake_timeout_seconds,
                        io_timeout_seconds,
                        &dns_fallback,
                    )
                    {
                        eprintln!("socks client failed: {}", err);
                    }
                });
            }
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(err) => {
                eprintln!("socks accept failed: {}", err);
                thread::sleep(Duration::from_millis(250));
            }
        }
    }
}

fn socks_client_allowed(active: usize, max_clients: usize, loopback: bool) -> bool {
    max_clients == 0 || active < max_clients || loopback
}

fn handle_socks_client(
    mut client: TcpStream,
    handshake_timeout_seconds: u64,
    io_timeout_seconds: u64,
    dns_fallback: &SocksDnsFallback,
) -> io::Result<()> {
    let handshake_timeout = Duration::from_secs(handshake_timeout_seconds.max(1));
    let io_timeout = Duration::from_secs(io_timeout_seconds.max(5));
    let _ = client.set_read_timeout(Some(handshake_timeout));
    let _ = client.set_write_timeout(Some(handshake_timeout));

    let mut hello = [0u8; 2];
    client.read_exact(&mut hello)?;
    if hello[0] != 0x05 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsupported SOCKS version",
        ));
    }
    let mut methods = vec![0u8; hello[1] as usize];
    client.read_exact(&mut methods)?;
    if !methods.contains(&0x00) {
        client.write_all(&[0x05, 0xff])?;
        return Ok(());
    }
    client.write_all(&[0x05, 0x00])?;

    let mut header = [0u8; 4];
    client.read_exact(&mut header)?;
    if header[0] != 0x05 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid request version",
        ));
    }
    if header[1] != 0x01 {
        write_socks_reply(&mut client, 0x07)?;
        return Ok(());
    }

    let host = match header[3] {
        0x01 => {
            let mut raw = [0u8; 4];
            client.read_exact(&mut raw)?;
            Ipv4Addr::from(raw).to_string()
        }
        0x03 => {
            let mut length = [0u8; 1];
            client.read_exact(&mut length)?;
            let mut raw = vec![0u8; length[0] as usize];
            client.read_exact(&mut raw)?;
            String::from_utf8_lossy(&raw).to_string()
        }
        0x04 => {
            let mut raw = [0u8; 16];
            client.read_exact(&mut raw)?;
            Ipv6Addr::from(raw).to_string()
        }
        _ => {
            write_socks_reply(&mut client, 0x08)?;
            return Ok(());
        }
    };
    let mut port_raw = [0u8; 2];
    client.read_exact(&mut port_raw)?;
    let port = u16::from_be_bytes(port_raw);

    let remote = match connect_target(&host, port, dns_fallback) {
        Ok(remote) => remote,
        Err(err) => {
            let code = match err.kind() {
                io::ErrorKind::ConnectionRefused => 0x05,
                io::ErrorKind::TimedOut => 0x06,
                io::ErrorKind::NotFound | io::ErrorKind::AddrNotAvailable => 0x04,
                _ => 0x01,
            };
            let _ = write_socks_reply(&mut client, code);
            return Err(err);
        }
    };
    write_socks_reply(&mut client, 0x00)?;
    relay_tcp(client, remote, io_timeout)
}

fn connect_target(
    host: &str,
    port: u16,
    dns_fallback: &SocksDnsFallback,
) -> io::Result<TcpStream> {
    let timeout = Duration::from_secs(
        env::var("TUNLET_SOCKS_CONNECT_TIMEOUT_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|value| *value > 0)
            .unwrap_or(10),
    );
    let mut addresses = match (host, port).to_socket_addrs() {
        Ok(addresses) => addresses.collect::<Vec<_>>(),
        Err(_) if dns_fallback.matches(host) => {
            eprintln!("socks DNS returned no address for {}; trying fallback", host);
            let resolved = dns_fallback.resolve_ipv4(host)?;
            eprintln!(
                "socks fallback DNS resolved {} to {}",
                host,
                resolved
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(",")
            );
            resolved
                .into_iter()
                .map(|address| (address, port).into())
                .collect::<Vec<_>>()
        }
        Err(err) => return Err(err),
    };
    if addresses.is_empty() && dns_fallback.matches(host) {
        eprintln!("socks DNS returned no address for {}; trying fallback", host);
        addresses = dns_fallback
            .resolve_ipv4(host)?
            .into_iter()
            .map(|address| (address, port).into())
            .collect();
    }
    let mut last_err = None;
    for address in addresses {
        match TcpStream::connect_timeout(&address, timeout) {
            Ok(stream) => {
                let _ = stream.set_nodelay(true);
                return Ok(stream);
            }
            Err(err) => last_err = Some(err),
        }
    }
    Err(last_err
        .unwrap_or_else(|| io::Error::new(io::ErrorKind::NotFound, "target has no address")))
}

fn write_socks_reply(stream: &mut TcpStream, code: u8) -> io::Result<()> {
    stream.write_all(&[0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
}

fn relay_tcp(mut client: TcpStream, mut remote: TcpStream, io_timeout: Duration) -> io::Result<()> {
    let _ = client.set_read_timeout(Some(io_timeout));
    let _ = client.set_write_timeout(Some(io_timeout));
    let _ = remote.set_read_timeout(Some(io_timeout));
    let _ = remote.set_write_timeout(Some(io_timeout));
    let mut client_read = client.try_clone()?;
    let mut remote_write = remote.try_clone()?;
    let _ = client_read.set_read_timeout(Some(io_timeout));
    let _ = remote_write.set_write_timeout(Some(io_timeout));
    let upstream = thread::spawn(move || {
        let _ = io::copy(&mut client_read, &mut remote_write);
        let _ = remote_write.shutdown(Shutdown::Both);
    });
    let downstream = thread::spawn(move || {
        let _ = io::copy(&mut remote, &mut client);
        let _ = client.shutdown(Shutdown::Both);
    });
    let _ = upstream.join();
    let _ = downstream.join();
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
struct KeepaliveTarget {
    tls: bool,
    host: String,
    port: u16,
    host_header: String,
    path: String,
}

impl KeepaliveTarget {
    fn request(&self) -> String {
        format!(
            "GET {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: tunlet-supervisor/1\r\nAccept: */*\r\nConnection: close\r\n\r\n",
            self.path, self.host_header
        )
    }
}

fn parse_keepalive_target(value: &str) -> Result<KeepaliveTarget, String> {
    let value = value.trim();
    if value
        .chars()
        .any(|ch| ch.is_ascii_control() || ch.is_ascii_whitespace())
    {
        return Err(
            "keepalive target must not contain whitespace or control characters".to_string(),
        );
    }
    let (remainder, default_port, tls) = if let Some(remainder) = value.strip_prefix("https://") {
        (remainder, 443, true)
    } else if let Some(remainder) = value.strip_prefix("http://") {
        (remainder, 80, false)
    } else {
        return Err("keepalive target must use http:// or https://".to_string());
    };

    let authority_end = remainder
        .find(|ch| matches!(ch, '/' | '?' | '#'))
        .unwrap_or(remainder.len());
    let authority = &remainder[..authority_end];
    if authority.is_empty() || authority.contains('@') {
        return Err("keepalive target has an invalid authority".to_string());
    }

    let (host, port, bracketed_host) = if let Some(bracketed) = authority.strip_prefix('[') {
        let end = bracketed
            .find(']')
            .ok_or_else(|| "keepalive IPv6 target is missing ]".to_string())?;
        let host = &bracketed[..end];
        let suffix = &bracketed[end + 1..];
        let port = if suffix.is_empty() {
            default_port
        } else if let Some(raw_port) = suffix.strip_prefix(':') {
            parse_keepalive_port(raw_port)?
        } else {
            return Err("keepalive IPv6 target has an invalid port".to_string());
        };
        (host, port, true)
    } else {
        if authority.matches(':').count() > 1 {
            return Err("keepalive IPv6 targets must use brackets".to_string());
        }
        match authority.rsplit_once(':') {
            Some((host, raw_port)) => (host, parse_keepalive_port(raw_port)?, false),
            None => (authority, default_port, false),
        }
    };

    if host.is_empty() {
        return Err("keepalive target host is empty".to_string());
    }
    let suffix = &remainder[authority_end..];
    let request_target = suffix
        .split_once('#')
        .map(|(path, _)| path)
        .unwrap_or(suffix);
    let path = if request_target.is_empty() {
        "/".to_string()
    } else if request_target.starts_with('?') {
        format!("/{}", request_target)
    } else if request_target.starts_with('/') {
        request_target.to_string()
    } else {
        return Err("keepalive target has an invalid request path".to_string());
    };
    let mut host_header = if bracketed_host {
        format!("[{}]", host)
    } else {
        host.to_string()
    };
    if port != default_port {
        host_header.push(':');
        host_header.push_str(&port.to_string());
    }
    Ok(KeepaliveTarget {
        tls,
        host: host.to_string(),
        port,
        host_header,
        path,
    })
}

fn parse_keepalive_port(value: &str) -> Result<u16, String> {
    let port = value
        .parse::<u16>()
        .map_err(|_| format!("invalid keepalive target port: {}", value))?;
    if port == 0 {
        return Err("keepalive target port must be greater than zero".to_string());
    }
    Ok(port)
}

fn validate_http_response(response: &[u8]) -> Result<(), String> {
    if response.is_empty() {
        return Err("keepalive endpoint returned an empty response".to_string());
    }
    let line_end = response
        .windows(2)
        .position(|window| window == b"\r\n")
        .or_else(|| response.iter().position(|byte| *byte == b'\n'))
        .unwrap_or(response.len());
    let status_line = std::str::from_utf8(&response[..line_end])
        .map_err(|_| "keepalive endpoint returned a non-UTF-8 status line".to_string())?;
    let mut fields = status_line.split_whitespace();
    let version = fields.next().unwrap_or_default();
    let code = fields
        .next()
        .ok_or_else(|| format!("invalid HTTP status line: {}", status_line))?
        .parse::<u16>()
        .map_err(|_| format!("invalid HTTP status line: {}", status_line))?;
    if !version.starts_with("HTTP/") || !(100..600).contains(&code) {
        return Err(format!("invalid HTTP status line: {}", status_line));
    }
    Ok(())
}

fn child_ld_preload() -> String {
    if env::var("FAKE_HWADDR")
        .ok()
        .filter(|v| !v.is_empty())
        .is_some()
    {
        "/usr/local/lib/fake-hwaddr.so /usr/local/lib/fake-getlogin.so".to_string()
    } else {
        "/usr/local/lib/fake-getlogin.so".to_string()
    }
}

fn env_flag_enabled(name: &str, fallback: bool) -> bool {
    match env::var(name) {
        Ok(value) if !value.is_empty() => !matches!(
            value.to_ascii_lowercase().as_str(),
            "0" | "false" | "no" | "off"
        ),
        _ => fallback,
    }
}

fn unix_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn authorized(request: &str, token: &str) -> bool {
    if token.is_empty() {
        return true;
    }
    for line in request.lines() {
        let (name, value) = match line.split_once(':') {
            Some(pair) => pair,
            None => continue,
        };
        if name.eq_ignore_ascii_case("authorization") {
            return value.trim() == format!("Bearer {}", token);
        }
    }
    false
}

fn content_length(request: &[u8]) -> usize {
    let text = String::from_utf8_lossy(request);
    for line in text.lines() {
        let (name, value) = match line.split_once(':') {
            Some(pair) => pair,
            None => continue,
        };
        if name.eq_ignore_ascii_case("content-length") {
            return value.trim().parse().unwrap_or(0);
        }
    }
    0
}

fn body_len(request: &[u8]) -> usize {
    request
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|pos| request.len().saturating_sub(pos + 4))
        .unwrap_or(0)
}

fn request_body(request: &[u8]) -> &str {
    let start = request
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|pos| pos + 4)
        .unwrap_or(request.len());
    std::str::from_utf8(&request[start..]).unwrap_or("")
}

fn extract_sms_code(body: &str) -> String {
    for field in ["smsCode", "code"] {
        let Some(pos) = body.find(field) else {
            continue;
        };
        let code: String = body[pos..]
            .chars()
            .skip_while(|ch| !ch.is_ascii_digit())
            .take_while(|ch| ch.is_ascii_digit())
            .collect();
        if !code.is_empty() {
            return code;
        }
    }
    String::new()
}

fn send_response(stream: &mut TcpStream, status: u16, body: &str) {
    let label = match status {
        200 => "OK",
        401 => "Unauthorized",
        404 => "Not Found",
        _ => "Bad Request",
    };
    let _ = write!(
        stream,
        "HTTP/1.1 {} {}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        status,
        label,
        body.len(),
        body
    );
}

fn replace_hosts_block(begin: &str, end: &str, content: &str) {
    let current = fs::read_to_string("/etc/hosts").unwrap_or_default();
    let mut output = Vec::new();
    let mut skip = false;
    for line in current.lines() {
        if line.contains(begin) {
            skip = true;
            continue;
        }
        if line.contains(end) {
            skip = false;
            continue;
        }
        if !skip {
            output.push(line.to_string());
        }
    }
    if !content.trim().is_empty() {
        output.push(begin.to_string());
        for item in content.replace(',', "\n").lines() {
            let item = item.trim();
            if !item.is_empty() {
                output.push(item.to_string());
            }
        }
        output.push(end.to_string());
    }
    let _ = fs::write("/etc/hosts", format!("{}\n", output.join("\n")));
}

fn command_ok(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn command_output(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn ensure_command_rule(program: &str, check: &[&str], add: &[&str]) {
    if !command_ok(program, check) {
        command_ok(program, add);
    }
}

fn reap_children() {
    loop {
        let mut status = 0;
        let pid = unsafe { waitpid(-1, &mut status, WNOHANG) };
        if pid <= 0 {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        build_dns_a_query, parse_dns_a_response, parse_keepalive_target, socks_client_allowed,
        validate_http_response, SocksDnsFallback,
    };

    #[test]
    fn socks_capacity_accepts_normal_clients_below_limit() {
        assert!(socks_client_allowed(127, 128, false));
        assert!(!socks_client_allowed(128, 128, false));
    }

    #[test]
    fn socks_capacity_reserves_loopback_probe_access() {
        assert!(socks_client_allowed(128, 128, true));
        assert!(socks_client_allowed(512, 128, true));
    }

    #[test]
    fn zero_socks_capacity_limit_is_unbounded() {
        assert!(socks_client_allowed(usize::MAX, 0, false));
    }

    #[test]
    fn socks_dns_fallback_requires_an_allowlisted_domain() {
        let fallback = SocksDnsFallback {
            resolver: "223.5.5.5:853".to_string(),
            tls_name: "dns.alidns.com".to_string(),
            domains: vec!["wanyol.com".to_string(), "oppoit.com".to_string()],
        };
        assert!(fallback.matches("tower.wanyol.com"));
        assert!(fallback.matches("WANYOL.COM."));
        assert!(!fallback.matches("notwanyol.com"));
        assert!(!fallback.matches("example.com"));
        assert!(!fallback.matches("10.225.56.59"));
    }

    #[test]
    fn dns_query_and_compressed_a_response_round_trip() {
        let id = 0x4a31;
        let query = build_dns_a_query("tower.wanyol.com", id).unwrap();
        assert_eq!(&query[0..2], &id.to_be_bytes());
        assert!(build_dns_a_query("bad..example", id).is_err());

        let mut response = query;
        response[2..4].copy_from_slice(&0x8180u16.to_be_bytes());
        response[6..8].copy_from_slice(&1u16.to_be_bytes());
        response.extend_from_slice(&[
            0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3c, 0x00, 0x04, 10,
            225, 56, 59,
        ]);
        assert_eq!(
            parse_dns_a_response(&response, id).unwrap(),
            vec![std::net::Ipv4Addr::new(10, 225, 56, 59)]
        );
        assert!(parse_dns_a_response(&response, id.wrapping_add(1)).is_err());
    }

    #[test]
    fn keepalive_urls_map_to_http_requests() {
        let https = parse_keepalive_target("https://internal.example/path").unwrap();
        assert!(https.tls);
        assert_eq!(https.host, "internal.example");
        assert_eq!(https.port, 443);
        assert_eq!(https.path, "/path");
        assert!(https.request().starts_with("GET /path HTTP/1.1\r\n"));

        let http =
            parse_keepalive_target("http://internal.example:8080/health?full=1#local").unwrap();
        assert!(!http.tls);
        assert_eq!(http.port, 8080);
        assert_eq!(http.host_header, "internal.example:8080");
        assert_eq!(http.path, "/health?full=1");
    }

    #[test]
    fn keepalive_urls_support_bracketed_ipv6() {
        let target = parse_keepalive_target("https://[2001:db8::1]:8443/").unwrap();
        assert_eq!(target.host, "2001:db8::1");
        assert_eq!(target.port, 8443);
        assert_eq!(target.host_header, "[2001:db8::1]:8443");
    }

    #[test]
    fn keepalive_targets_reject_unsafe_or_ambiguous_authorities() {
        assert!(parse_keepalive_target("ftp://internal.example/").is_err());
        assert!(parse_keepalive_target("https://user@internal.example/").is_err());
        assert!(parse_keepalive_target("https://2001:db8::1/").is_err());
        assert!(parse_keepalive_target("https://internal.example:0/").is_err());
        assert!(parse_keepalive_target("https://internal.example/a b").is_err());
    }

    #[test]
    fn keepalive_requires_a_real_http_response() {
        assert!(validate_http_response(b"HTTP/1.1 302 Found\r\nLocation: /login\r\n\r\n").is_ok());
        assert!(validate_http_response(b"").is_err());
        assert!(validate_http_response(b"not-http\r\n").is_err());
    }
}
