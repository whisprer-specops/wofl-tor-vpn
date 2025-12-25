use anyhow::{Result};
use tokio::process::Command;
use crate::config::Config;

pub async fn apply_rules(cfg: &Config, _state_dir: &std::path::Path) -> Result<()> {
    use tokio::process::Command as TCmd;
    // Resolve tor_user to UID (if exists)
    let mut uids: Vec<u32> = cfg.security.allow_uids.clone();
    if !cfg.security.tor_user.is_empty() {
        if let Ok(out) = TCmd::new("sh").arg("-lc").arg(format!("id -u {}", cfg.security.tor_user)).output().await {
            if out.status.success() {
                if let Ok(s) = String::from_utf8(out.stdout) {
                    if let Ok(uid) = s.trim().parse::<u32>() {
                        if !uids.contains(&uid) { uids.push(uid); }
                    }
                }
            }
        }
    }
    // Build set string for nftables
    let uid_elems = if uids.is_empty() {
        String::new()
    } else {
        format!("set allowed_uids {{ type uid_t; elements = {{ {} }} }};", uids.iter().map(|u| u.to_string()).collect::<Vec<_>>().join(", "))
    };

    let tun = &cfg.tun.interface;
    let dns_port = cfg.tor.dns_port;
    let trans_port = cfg.tor.trans_port;

    let rules = if cfg.net.mode == "transparent" {
        format!(r#"
flush ruleset
table inet torvpn {{
  {uid_elems}
  chains {{
    output {{
      type filter hook output priority 0; policy drop;
      meta oif "lo" accept
      {uid_accept}
      ip daddr 127.0.0.1 tcp dport {{ {dns_port}, 9050, 9051, {trans_port} }} accept
      udp dport 53 drop
    }}
    prerouting {{
      type nat hook prerouting priority -100;
      # Redirect all TCP to Tor TransPort; exempt loopback
      ip daddr != 127.0.0.1 tcp redirect to :{trans_port}
    }}
    output_nat {{
      type nat hook output priority -100;
      # Local-originated TCP gets redirected too (covers localhost-originating apps)
      ip daddr != 127.0.0.1 tcp dport != {trans_port} redirect to :{trans_port}
      # Redirect DNS to Tor DNSPort
      udp dport 53 redirect to :{dns_port}
    }}
  }}
}}
"#,
            uid_elems = if uids.is_empty() { "".to_string() } else { format!("sets {{ {} }}", uid_elems) },
            uid_accept = if uids.is_empty() { "".to_string() } else { "meta skuid @allowed_uids accept".to_string() },
            dns_port = dns_port,
            trans_port = trans_port
        )
    } else {
        format!(r#"
flush ruleset
table inet torvpn {{
  {uid_elems}
  chains {{
    output {{
      type filter hook output priority 0; policy drop;
      oifname "{tun}" accept
      meta oif "lo" accept
      {uid_accept}
      ip daddr 127.0.0.1 tcp dport {{ {dns_port}, 9050, 9051, 9040 }} accept
      udp dport 53 drop
    }}
  }}
}}
"#,
            uid_elems = if uids.is_empty() { "".to_string() } else { format!("sets {{ {} }}", uid_elems) },
            uid_accept = if uids.is_empty() { "".to_string() } else { "meta skuid @allowed_uids accept".to_string() },
            tun = tun,
            dns_port = dns_port
        )
    };

    TCmd::new("sh").arg("-lc").arg(format!("nft -f - <<'NFT'
{}
NFT", rules)).status().await?;
    Ok(())
}