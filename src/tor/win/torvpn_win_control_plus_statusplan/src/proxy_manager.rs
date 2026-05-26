use anyhow::Result;
use rand::{seq::SliceRandom, thread_rng};
use crate::config::{Config, ProxyItem};
use std::path::PathBuf;
use tokio::fs;

pub struct ProxyManager {
    idx: usize,
}

impl ProxyManager {
    pub async fn load(state_dir: &PathBuf) -> Result<Self> {
        let p = state_dir.join("proxy_idx.json");
        if let Ok(b) = fs::read(&p).await {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&b) {
                if let Some(i) = v.get("idx").and_then(|x| x.as_u64()) {
                    return Ok(Self { idx: i as usize });
                }
            }
        }
        Ok(Self { idx: 0 })
    }
    pub async fn save(&self, state_dir: &PathBuf) -> Result<()> {
        let p = state_dir.join("proxy_idx.json");
        let v = serde_json::json!({ "idx": self.idx });
        fs::write(p, serde_json::to_vec_pretty(&v)?).await?;
        Ok(())
    }
    pub fn current<'a>(&mut self, cfg: &'a Config) -> Option<&'a ProxyItem> {
        if !cfg.proxy.enabled || cfg.proxy.proxies.is_empty() { return None; }
        if cfg.proxy.rotation == "random" {
            let mut rng = thread_rng();
            return cfg.proxy.proxies.choose(&mut rng);
        }
        let i = self.idx % cfg.proxy.proxies.len();
        Some(&cfg.proxy.proxies[i])
    }
    pub fn next(&mut self, cfg: &Config) {
        if !cfg.proxy.enabled || cfg.proxy.proxies.is_empty() { return; }
        self.idx = (self.idx + 1) % cfg.proxy.proxies.len();
    }
}
