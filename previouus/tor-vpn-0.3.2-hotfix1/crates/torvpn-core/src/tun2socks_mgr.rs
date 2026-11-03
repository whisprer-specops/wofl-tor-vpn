//! Spawns `tun2socks.exe` against a Wintun device, pointing at Tor's first
//! SOCKS port. Discovers the binary either via `[tun2socks].binary` (filename
//! on PATH or absolute path) or — if bundled — next to our exe.

use anyhow::{anyhow, Context, Result};
use std::path::PathBuf;
use tokio::process::{Child, Command};

use crate::config::Config;

pub struct Tun2Socks {
    child: Option<Child>,
    pid: u32,
    #[cfg(windows)]
    _job: crate::process_job::Job,
}

impl Tun2Socks {
    pub fn pid(&self) -> u32 {
        self.pid
    }
    pub fn has_exited(&mut self) -> std::io::Result<bool> {
        match self.child.as_mut() {
            Some(c) => c.try_wait().map(|v| v.is_some()),
            None => Ok(true),
        }
    }

    pub async fn start(cfg: &Config) -> Result<Self> {
        let bin = resolve_binary(cfg).context("locating tun2socks.exe")?;
        let ifname = &cfg.tun.interface;
        let socks = cfg.tor.socks_port;
        let mtu = cfg.tun.mtu;

        // Capture tun2socks output to a log instead of /dev/null. tun2socks
        // reports adapter-creation failures (wrong-architecture wintun.dll,
        // missing wintun.dll, access denied) on stderr and then exits — nulling
        // that output is precisely why "tun2socks_pid is set but no Wintun
        // adapter exists" had no visible cause. Truncate each start so the log
        // always reflects the current attempt.
        let log_path = crate::paths::state_dir().join("tun2socks.log");
        let _ = std::fs::create_dir_all(crate::paths::state_dir());

        let mut cmd = Command::new(&bin);
        // Device scheme is "tun://<name>" — NOT "wintun://<name>". On Windows,
        // xjasonlyu/tun2socks's engine recognises exactly three schemes: tun,
        // tap, fd. It parses the scheme off the -device URL and dispatches on
        // it directly; "wintun" isn't one of the three, so it hits the
        // catch-all branch and dies with a clean, immediate "unsupported
        // driver: wintun" — before it ever touches wintun.dll. That's why
        // swapping DLL architecture changed nothing: the program never got
        // that far. Wintun is what "tun://" uses *under the hood* on Windows
        // (dynamically loading wintun.dll next to the exe, same as the DLL
        // you already have in place) — it just isn't a URL scheme of its own.
        // Confirmed against a real working Windows invocation in the
        // project's own issue tracker (xjasonlyu/tun2socks#77):
        // `tun2socks-windows-amd64.exe -device tun://tun0 -proxy socks5://127.0.0.1:10808`
        cmd.arg("-device")
            .arg(format!("tun://{}", ifname))
            .arg("-proxy")
            .arg(format!("socks5://127.0.0.1:{}", socks))
            .arg("-mtu")
            .arg(mtu.to_string())
            .arg("-loglevel")
            .arg("info");

        match std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&log_path)
        {
            Ok(f) => match f.try_clone() {
                Ok(f2) => {
                    cmd.stdout(std::process::Stdio::from(f));
                    cmd.stderr(std::process::Stdio::from(f2));
                }
                Err(_) => {
                    cmd.stdout(std::process::Stdio::from(f));
                    cmd.stderr(std::process::Stdio::null());
                }
            },
            Err(_) => {
                cmd.stdout(std::process::Stdio::null());
                cmd.stderr(std::process::Stdio::null());
            }
        }
        if let Some(dir) = bin.parent() {
            cmd.current_dir(dir);
        }
        cmd.kill_on_drop(true);

        #[cfg(windows)]
        {
            // tokio's Command exposes creation_flags() inherently on Windows.
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }

        let mut child = cmd
            .spawn()
            .with_context(|| format!("spawn {}", bin.display()))?;
        let pid = child.id().context("spawned process has no PID")?;
        #[cfg(windows)]
        let job = crate::process_job::Job::for_child(&child)?;

        // A tun2socks that can't create its Wintun adapter dies within a beat.
        // Give it one, and if it's already gone, surface WHY (the tail of its
        // own log) instead of handing back a live-looking PID for a corpse and
        // letting connect() march on to "Engaged".
        tokio::time::sleep(std::time::Duration::from_millis(800)).await;
        if let Some(status) = child.try_wait().context("checking tun2socks process")? {
            let tail = read_log_tail(&log_path, 1200);
            let said = if tail.is_empty() {
                "no output captured".to_string()
            } else {
                tail
            };
            return Err(anyhow!(
                "tun2socks exited immediately ({status}). Common causes, in order of \
                 likelihood: (1) wintun.dll missing from the same folder as the \
                 tun2socks exe; (2) wintun.dll architecture doesn't match the exe — a \
                 32-bit 'windows-386' build cannot load a 64-bit wintun.dll or vice \
                 versa, so if you're on the windows-386 build, use a 32-bit wintun.dll, \
                 or switch to the windows-amd64 build to pair with a 64-bit one; (3) not \
                 running elevated — creating a Wintun adapter needs admin rights; (4) an \
                 adapter with this name already exists in a broken state (check \
                 `Get-NetAdapter` and remove any stale '{ifname}' entry). \
                 tun2socks log ({}): {said}",
                log_path.display(),
            ));
        }

        Ok(Self {
            child: Some(child),
            pid,
            #[cfg(windows)]
            _job: job,
        })
    }

    // (helper `read_log_tail` defined below)

    pub async fn stop(mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.start_kill();
            let _ = tokio::time::timeout(std::time::Duration::from_secs(3), child.wait()).await;
        }
    }
}

/// Last `max_chars` characters of a log file, trimmed, char-boundary safe.
/// Used to fold tun2socks's own error text into our error message.
fn read_log_tail(path: &std::path::Path, max_chars: usize) -> String {
    let s = std::fs::read_to_string(path).unwrap_or_default();
    let s = s.trim();
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= max_chars {
        s.to_string()
    } else {
        format!(
            "…{}",
            chars[chars.len() - max_chars..].iter().collect::<String>()
        )
    }
}

pub(crate) fn resolve_binary(cfg: &Config) -> Result<PathBuf> {
    let configured = &cfg.tun2socks.binary;
    let mut tried: Vec<String> = Vec::new();

    // Absolute or relative-with-slash path
    if configured.contains('\\') || configured.contains('/') {
        let p = PathBuf::from(configured);
        if p.exists() {
            return Ok(p);
        }
        tried.push(format!("{} (not found)", p.display()));
    }
    // Next to our binary (bundled install case)
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let cand = dir.join(configured);
            if cand.exists() {
                return Ok(cand);
            }
            tried.push(format!("{} (not found)", cand.display()));
            let cand = dir.join("tun2socks").join(configured);
            if cand.exists() {
                return Ok(cand);
            }
            tried.push(format!("{} (not found)", cand.display()));
        }
    }
    // PATH lookup
    if let Ok(p) = which::which(configured) {
        return Ok(p);
    }
    tried.push(format!("PATH search for '{configured}' (not found)"));

    // See tor_manager::find_tor for why "it's on my PATH" doesn't help here:
    // this runs inside the service process, whose environment was captured
    // whenever it last started, not your interactive shell's.
    let path_seen = std::env::var("PATH").unwrap_or_else(|_| "<PATH not set>".to_string());

    Err(anyhow!(
        "tun2socks not found ([tun2socks].binary = '{configured}'). Tried: {}. \
         PATH this service process sees: {path_seen}. Fix: set [tun2socks].binary \
         to a full path (forward slashes, or \\\\ — a bare \\ in a TOML string is \
         an escape code) in %ProgramData%\\torvpn\\profile.toml, then \
         `Restart-Service TorVPN`.",
        tried.join("; ")
    ))
}
