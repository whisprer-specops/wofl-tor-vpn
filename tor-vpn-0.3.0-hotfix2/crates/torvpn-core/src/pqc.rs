//! Post-quantum signing / KEM helpers. Off by default — these are heavy
//! dependencies (Dilithium + Kyber) we don't need for the VPN core. Build
//! with `--features pqc` to enable.

use anyhow::Result;
use base64::{engine::general_purpose, Engine as _};
use pqcrypto_dilithium::dilithium2;
use pqcrypto_kyber::kyber1024;
use pqcrypto_traits::kem::{
    Ciphertext as _, PublicKey as KemPk, SecretKey as KemSk, SharedSecret as _,
};
use pqcrypto_traits::sign::{PublicKey as _, SecretKey as _, SignedMessage as _};
use std::path::Path;
use tokio::fs;

pub async fn keygen_sig(out_dir: &Path) -> Result<()> {
    let (pk, sk) = dilithium2::keypair();
    fs::create_dir_all(out_dir).await?;
    fs::write(out_dir.join("pqc_dilithium2.pk"), pk.as_bytes()).await?;
    fs::write(out_dir.join("pqc_dilithium2.sk"), sk.as_bytes()).await?;
    Ok(())
}

pub async fn sign_file(sk_path: &Path, in_path: &Path, sig_out: &Path) -> Result<()> {
    let sk_bytes = fs::read(sk_path).await?;
    let sk = dilithium2::SecretKey::from_bytes(&sk_bytes)
        .map_err(|e| anyhow::anyhow!("bad sk: {e:?}"))?;
    let data = fs::read(in_path).await?;
    let sm = dilithium2::sign(&data, &sk);
    fs::write(sig_out, sm.as_bytes()).await?;
    Ok(())
}

pub async fn verify_file(pk_path: &Path, in_path: &Path, sig_path: &Path) -> Result<bool> {
    let pk_bytes = fs::read(pk_path).await?;
    let pk = dilithium2::PublicKey::from_bytes(&pk_bytes)
        .map_err(|e| anyhow::anyhow!("bad pk: {e:?}"))?;
    let data = fs::read(in_path).await?;
    let sig_bytes = fs::read(sig_path).await?;
    let sm = dilithium2::SignedMessage::from_bytes(&sig_bytes)
        .map_err(|e| anyhow::anyhow!("bad sig: {e:?}"))?;
    Ok(dilithium2::open(&sm, &pk)
        .map(|opened| opened == data)
        .unwrap_or(false))
}

pub async fn kem_demo(out_dir: &Path) -> Result<()> {
    let (pk, sk) = kyber1024::keypair();
    let (ss_enc, ct) = kyber1024::encapsulate(&pk);
    let ss_dec = kyber1024::decapsulate(&ct, &sk);
    fs::create_dir_all(out_dir).await?;
    fs::write(out_dir.join("kyber_ct.bin"), ct.as_bytes()).await?;
    fs::write(
        out_dir.join("kyber_ss.enc"),
        general_purpose::STANDARD.encode(ss_enc.as_bytes()),
    )
    .await?;
    fs::write(
        out_dir.join("kyber_ss.dec"),
        general_purpose::STANDARD.encode(ss_dec.as_bytes()),
    )
    .await?;
    Ok(())
}
