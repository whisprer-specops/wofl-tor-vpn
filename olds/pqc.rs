use anyhow::{Result, Context};
use pqcrypto_dilithium::dilithium2;
use pqcrypto_dilithium::dilithium2::{PublicKey, SecretKey, SignedMessage};
use pqcrypto_kyber::kyber1024;
use base64::{engine::general_purpose, Engine as _};
use tokio::{fs, io::AsyncWriteExt};
use std::path::Path;

pub async fn keygen_sig(out_dir: &Path) -> Result<()> {
    let (pk, sk) = dilithium2::keypair();
    fs::create_dir_all(out_dir).await?;
    fs::write(out_dir.join("pqc_dilithium2.pk"), pk.as_bytes()).await?;
    fs::write(out_dir.join("pqc_dilithium2.sk"), sk.as_bytes()).await?;
    Ok(())
}

pub async fn sign_file(sk_path: &Path, in_path: &Path, sig_out: &Path) -> Result<()> {
    let sk_bytes = fs::read(sk_path).await?;
    let sk = SecretKey::from_bytes(&sk_bytes).context("invalid secret key")?;
    let data = fs::read(in_path).await?;
    let sm: SignedMessage = dilithium2::sign(&data, &sk);
    fs::write(sig_out, sm.as_bytes()).await?;
    Ok(())
}

pub async fn verify_file(pk_path: &Path, in_path: &Path, sig_path: &Path) -> Result<bool> {
    let pk_bytes = fs::read(pk_path).await?;
    let pk = PublicKey::from_bytes(&pk_bytes).context("invalid public key")?;
    let data = fs::read(in_path).await?;
    let sig = fs::read(sig_path).await?;
    Ok(dilithium2::verify_detached(&sig, &data, &pk).is_ok())
}

pub async fn kem_demo(out_dir: &Path) -> Result<()> {
    let (pk, sk) = kyber1024::keypair();
    let (ct, ss_enc) = kyber1024::encapsulate(&pk);
    let ss_dec = kyber1024::decapsulate(&ct, &sk);
    fs::create_dir_all(out_dir).await?;
    fs::write(out_dir.join("kyber_ct.bin"), ct.as_bytes()).await?;
    fs::write(out_dir.join("kyber_ss.enc"), general_purpose::STANDARD.encode(ss_enc.as_bytes())).await?;
    fs::write(out_dir.join("kyber_ss.dec"), general_purpose::STANDARD.encode(ss_dec.as_bytes())).await?;
    Ok(())
}
