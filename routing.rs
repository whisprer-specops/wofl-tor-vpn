use anyhow::Result;
use tokio::process::Command;
use crate::config::Config;

// Constants for policy routing
const TABLE_NUM: u32 = 100;
const TABLE_NAME: &str = "torvpn";
const MARK: u32 = 0x1;

pub async fn apply_for_tun2socks(cfg: &Config) -> Result<()> {
    // Policy route: marked packets -> table 100 -> default via 10.111.0.2 dev tun0
    let tun = &cfg.tun.interface;
    let peer_ip = "10.111.0.2"; // peer end used by tun2socks
    let table_num = TABLE_NUM;
    let mark = MARK;

    // Add route table entry
    sh(&format!("ip route replace default via {peer_ip} dev {tun} table {table_num}")).await?

    // Ensure rule: fwmark 0x1 -> table 100
    sh(&format!("ip rule add fwmark {mark} lookup {table_num} priority 100 || true")).await?;

    // Build nft mangle table to set marks and clamp MSS
    let uid_set = build_uid_set(cfg).await?;
    let rules = format!(r#"
flush table inet torvpn_mangle
table inet torvpn_mangle {{
  {uid_set}
  chains {{
    m_out {{
      type route hook output priority mangle; policy accept;
      # Don't touch loopback
      meta oif "lo" accept
      # Allow Tor/allowed uids to pass unmarked (use main routing table)
      {uid_accept}
      # Avoid marking traffic to loopback
      ip daddr 127.0.0.0/8 accept
      # Mark all else for policy routing into tun table
      meta mark set {mark}
    }}
    m_post {{
      type route hook postrouting priority mangle; policy accept;
      # TCP MSS clamp to PMTU to avoid fragmentation blackholes
      tcp flags syn tcp option maxseg size set clamp to pmtu
    }}
  }}
}}
"#,
        uid_set = uid_set.set_def,
        uid_accept = uid_set.accept_rule,
        mark = MARK,
    );

    sh(&format!("nft -f - <<'NFT'\n{}\nNFT", rules)).await?;
    Ok(())
}

pub async fn teardown_for_tun2socks() -> Result<()> {
    // Remove ip rule and flush custom route table; drop mangle table
    let _ = sh(&format!("ip rule del fwmark {} lookup {} priority 100 || true", MARK, TABLE_NUM)).await;
    let _ = sh(&format!("ip route flush table {}", TABLE_NUM)).await;
    let _ = sh("nft delete table inet torvpn_mangle || true").await;
    Ok(())
}

struct UidSetDef {
    set_def: String,
    accept_rule: String,
}

async fn build_uid_set(cfg: &Config) -> Result<UidSetDef> {
    use tokio::process::Command as Cmd;
    // Merge allow_uids with resolved tor_user uid (if any)
    let mut uids: Vec<u32> = cfg.security.allow_uids.clone();
    if !cfg.security.tor_user.is_empty() {
        if let Ok(out) = Cmd::new("sh").arg("-lc").arg(format!("id -u {}", cfg.security.tor_user)).output().await {
            if out.status.success() {
                if let Ok(s) = String::from_utf8(out.stdout) {
                    if let Ok(uid) = s.trim().parse::<u32>() {
                        if !uids.contains(&uid) { uids.push(uid); }
                    }
                }
            }
        }
    }
    if uids.is_empty() {
        Ok(UidSetDef {
            set_def: "".into(),
            accept_rule: "".into(),
        })
    } else {
        let elems = uids.iter().map(|u| u.to_string()).collect::<Vec<_>>().join(", ");
        Ok(UidSetDef {
            set_def: format!("sets {{ allowed_uids {{ type uid_t; elements = {{ {} }} }} }}", elems),
            accept_rule: "meta skuid @allowed_uids accept".into(),
        })
    }
}

async fn sh(cmd: &str) -> Result<()> {
    let status = Command::new("sh").arg("-lc").arg(cmd).status().await?;
    if !status.success() {
        anyhow::bail!("command failed: {}", cmd);
    }
    Ok(())
}
