//! Own-provider persistent WFP guard. No kernel driver, registry or firewall-profile writes.
//! Fixed filter-key range makes recovery independent of a writable recovery journal.
use std::process::ExitCode;
fn main() -> ExitCode {
    #[cfg(windows)]
    let result = win::run(std::env::args().skip(1).collect());
    #[cfg(not(windows))]
    let result: Result<(), String> = Err("Windows 11 x64 is required".into());
    match result { Ok(()) => ExitCode::SUCCESS, Err(e) => { eprintln!("Guard: {e}"); ExitCode::FAILURE } }
}

#[cfg(windows)]
mod win {
    use std::{ffi::c_void, net::Ipv4Addr, ptr::{null, null_mut}, mem::zeroed};
    use windows_sys::{core::GUID, Win32::{Foundation::HANDLE, NetworkManagement::{WindowsFilteringPlatform::*, IpHelper::ConvertInterfaceGuidToLuid, Ndis::NET_LUID_LH}}};
    const PROVIDER: GUID = GUID::from_u128(0xd78d8eb9_b7c0_4e90_9eb4_0d2ec6760400);
    const SUBLAYER: GUID = GUID::from_u128(0xd78d8eb9_b7c0_4e90_9eb4_0d2ec6760401);
    const FILTER_BASE: u128 = 0xd78d8eb9_b7c0_4e90_9eb4_0d2ec6761000;
    const NOT_FOUND: u32 = 0x80320003; // FWP_E_FILTER_NOT_FOUND
    const PROVIDER_NOT_FOUND: u32 = 0x80320005;
    const SUBLAYER_NOT_FOUND: u32 = 0x80320007;
    const MAX_FILTERS: u128 = 128;
    fn wide(s: &str) -> Vec<u16> { s.encode_utf16().chain(Some(0)).collect() }
    fn checked(code: u32, call: &str) -> Result<(), String> {
        if code == 0 { Ok(()) } else { Err(format!("{call}: 0x{code:08x}")) }
    }
    struct Engine(HANDLE);
    impl Engine {
        fn open() -> Result<Self, String> {
            let mut h = null_mut();
            // Persistent objects deliberately use a non-dynamic session.
            checked(unsafe { FwpmEngineOpen0(null(), 0xffff_ffff, null(), null(), &mut h) }, "FwpmEngineOpen0")?;
            Ok(Self(h))
        }
        fn exists(&self) -> Result<bool, String> {
            let mut p = null_mut();
            let code = unsafe { FwpmProviderGetByKey0(self.0, &PROVIDER, &mut p) };
            if code == PROVIDER_NOT_FOUND { return Ok(false); }
            checked(code, "FwpmProviderGetByKey0")?;
            unsafe { FwpmFreeMemory0(&mut p as *mut _ as *mut *mut c_void); }
            Ok(true)
        }
        fn transaction<F: FnOnce() -> Result<(), String>>(&self, f: F) -> Result<(), String> {
            checked(unsafe { FwpmTransactionBegin0(self.0, 0) }, "begin transaction")?;
            let result = f().and_then(|_| checked(unsafe { FwpmTransactionCommit0(self.0) }, "commit transaction"));
            if result.is_err() { unsafe { FwpmTransactionAbort0(self.0); } }
            result
        }
        fn delete_filter(&self, slot: u128) -> Result<(), String> {
            let key = GUID::from_u128(FILTER_BASE + slot);
            let code = unsafe { FwpmFilterDeleteByKey0(self.0, &key) };
            if code == NOT_FOUND { Ok(()) } else { checked(code, "delete owned filter") }
        }
        fn filter(&self, slot: u128, layer: GUID, weight: u8, action: u32, cond: &mut [FWPM_FILTER_CONDITION0], name: &str) -> Result<(), String> {
            let mut label = wide(name);
            let mut provider = PROVIDER;
            let mut filter: FWPM_FILTER0 = unsafe { zeroed() };
            filter.filterKey = GUID::from_u128(FILTER_BASE + slot);
            filter.displayData.name = label.as_mut_ptr();
            filter.flags = FWPM_FILTER_FLAG_PERSISTENT;
            filter.providerKey = &mut provider;
            filter.layerKey = layer;
            filter.subLayerKey = SUBLAYER;
            filter.weight.r#type = FWP_UINT8;
            filter.weight.Anonymous.uint8 = weight;
            filter.numFilterConditions = cond.len() as u32;
            filter.filterCondition = if cond.is_empty() { null_mut() } else { cond.as_mut_ptr() };
            filter.action.r#type = action;
            // Never set CLEAR_ACTION_RIGHT: our permits must not bypass other vendors' blocks.
            checked(unsafe { FwpmFilterAdd0(self.0, &filter, null_mut(), null_mut()) }, "FwpmFilterAdd0")
        }
        fn arm(&self, engine: &str, tor: &str, endpoint: Ipv4Addr, port: u16, wg: Option<&str>) -> Result<(), String> {
            if self.exists()? { return Err("Protection is already armed. Use recover explicitly before starting a new session.".into()); }
            let engine = AppId::new(engine)?;
            let tor = AppId::new(tor)?;
            let wg = wg.map(AppId::new).transpose()?;
            self.transaction(|| {
                let mut label = wide("whispr Hybrid VPN 0.4.0 guard");
                let mut provider: FWPM_PROVIDER0 = unsafe { zeroed() };
                provider.providerKey = PROVIDER;
                provider.displayData.name = label.as_mut_ptr();
                provider.flags = FWPM_PROVIDER_FLAG_PERSISTENT;
                checked(unsafe { FwpmProviderAdd0(self.0, &provider, null_mut()) }, "add provider")?;
                let mut pkey = PROVIDER;
                let mut sub: FWPM_SUBLAYER0 = unsafe { zeroed() };
                sub.subLayerKey = SUBLAYER;
                sub.displayData.name = label.as_mut_ptr();
                sub.flags = FWPM_SUBLAYER_FLAG_PERSISTENT;
                sub.providerKey = &mut pkey;
                sub.weight = u16::MAX;
                checked(unsafe { FwpmSubLayerAdd0(self.0, &sub, null_mut()) }, "add sublayer")?;
                let mut slot = 0;
                for (layer, v6) in [(FWPM_LAYER_ALE_AUTH_CONNECT_V4, false), (FWPM_LAYER_ALE_AUTH_CONNECT_V6, true)] {
                    self.filter(slot, layer, 1, FWP_ACTION_BLOCK, &mut [], "whispr: block unprotected outbound")?; slot += 1;
                    let mut loopback = value(FWPM_CONDITION_FLAGS, FWP_UINT32);
                    loopback.matchType = FWP_MATCH_FLAGS_ALL_SET;
                    loopback.conditionValue.Anonymous.uint32 = FWP_CONDITION_FLAG_IS_LOOPBACK;
                    self.filter(slot, layer, 15, FWP_ACTION_PERMIT, &mut [loopback], "whispr: loopback")?; slot += 1;
                    for app in [&engine, &tor] {
                        self.filter(slot, layer, 15, FWP_ACTION_PERMIT, &mut [app.condition(), protocol(6)], "whispr: owned TCP transport")?; slot += 1;
                    }
                    // Existing official WireGuard transports keep working; their app-data routes remain separate.
                    if let Some(app) = &wg {
                        self.filter(slot, layer, 15, FWP_ACTION_PERMIT, &mut [app.condition(), protocol(17)], "whispr: existing official WireGuard transport")?; slot += 1;
                    }
                    for proto in [6, 17] {
                        self.filter(slot, layer, 13, FWP_ACTION_BLOCK, &mut [protocol(proto), remote_port(53)], "whispr: no physical DNS fallback")?; slot += 1;
                    }
                    if !v6 {
                        for (addr, mask) in [(0x0a000000, 0xff000000), (0xac100000,0xfff00000), (0xc0a80000,0xffff0000), (0xa9fe0000,0xffff0000)] {
                            let mut range = FWP_V4_ADDR_AND_MASK { addr, mask };
                            let mut c = value(FWPM_CONDITION_IP_REMOTE_ADDRESS, FWP_V4_ADDR_MASK);
                            c.conditionValue.Anonymous.v4AddrMask = &mut range;
                            self.filter(slot, layer, 12, FWP_ACTION_PERMIT, &mut [c], "whispr: private network exception")?; slot += 1;
                        }
                        let mut address = value(FWPM_CONDITION_IP_REMOTE_ADDRESS, FWP_UINT32);
                        address.conditionValue.Anonymous.uint32 = u32::from_be_bytes(endpoint.octets());
                        self.filter(slot, layer, 15, FWP_ACTION_PERMIT, &mut [engine.condition(), protocol(17), remote_port(port), address], "whispr: UDP WireGuard endpoint only")?; slot += 1;
                        let mut broadcast = value(FWPM_CONDITION_IP_REMOTE_ADDRESS, FWP_UINT32);
                        broadcast.conditionValue.Anonymous.uint32 = u32::MAX;
                        self.filter(slot, layer, 15, FWP_ACTION_PERMIT, &mut [protocol(17), remote_port(67), broadcast], "whispr: DHCPv4 broadcast")?; slot += 1;
                    } else {
                        for (addr, len) in [([0xfc,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],7), ([0xfe,0x80,0,0,0,0,0,0,0,0,0,0,0,0,0,0],10), ([0xff,0x02,0,0,0,0,0,0,0,0,0,0,0,0,0,0],16)] {
                            let mut range = FWP_V6_ADDR_AND_MASK { addr, prefixLength:len };
                            let mut c = value(FWPM_CONDITION_IP_REMOTE_ADDRESS, FWP_V6_ADDR_MASK);
                            c.conditionValue.Anonymous.v6AddrMask = &mut range;
                            self.filter(slot, layer, 12, FWP_ACTION_PERMIT, &mut [c], "whispr: local IPv6 exception")?; slot += 1;
                        }
                    }
                }
                if slot >= 100 { return Err("Internal filter slot limit exceeded".into()); }
                Ok(())
            })
        }
        fn allow_tunnel(&self, guid: &str) -> Result<(), String> {
            if !self.exists()? { return Err("Guard is not armed".into()); }
            let id = parse_guid(guid)?;
            let mut luid: NET_LUID_LH = unsafe { zeroed() };
            checked(unsafe { ConvertInterfaceGuidToLuid(&id, &mut luid) }, "ConvertInterfaceGuidToLuid")?;
            let mut value64 = unsafe { luid.Value };
            self.transaction(|| {
                for (slot, layer) in [(100,FWPM_LAYER_ALE_AUTH_CONNECT_V4),(101,FWPM_LAYER_ALE_AUTH_CONNECT_V6)] {
                    self.delete_filter(slot)?;
                    let mut c = value(FWPM_CONDITION_IP_LOCAL_INTERFACE, FWP_UINT64);
                    c.conditionValue.Anonymous.uint64 = &mut value64;
                    self.filter(slot, layer, 14, FWP_ACTION_PERMIT, &mut [c], "whispr: exact TUN interface LUID")?;
                }
                Ok(())
            })
        }
        fn recover(&self) -> Result<(), String> {
            if !self.exists()? { println!("Protection is not armed."); return Ok(()); }
            self.transaction(|| {
                for slot in 0..MAX_FILTERS { self.delete_filter(slot)?; }
                let code = unsafe { FwpmSubLayerDeleteByKey0(self.0, &SUBLAYER) };
                if code != SUBLAYER_NOT_FOUND { checked(code, "delete owned sublayer")?; }
                checked(unsafe { FwpmProviderDeleteByKey0(self.0, &PROVIDER) }, "delete owned provider")
            })
        }
    }
    impl Drop for Engine { fn drop(&mut self) { unsafe { FwpmEngineClose0(self.0); } } }
    struct AppId(*mut FWP_BYTE_BLOB);
    impl AppId {
        fn new(path: &str) -> Result<Self, String> {
            let path = std::fs::canonicalize(path).map_err(|e| format!("application path: {e}"))?;
            let name = wide(&path.to_string_lossy());
            let mut blob = null_mut();
            checked(unsafe { FwpmGetAppIdFromFileName0(name.as_ptr(), &mut blob) }, "FwpmGetAppIdFromFileName0")?;
            Ok(Self(blob))
        }
        fn condition(&self) -> FWPM_FILTER_CONDITION0 {
            let mut c = value(FWPM_CONDITION_ALE_APP_ID, FWP_BYTE_BLOB_TYPE);
            c.conditionValue.Anonymous.byteBlob = self.0;
            c
        }
    }
    impl Drop for AppId { fn drop(&mut self) { unsafe { FwpmFreeMemory0(&mut self.0 as *mut _ as *mut *mut c_void); } } }
    fn value(field: GUID, kind: FWP_DATA_TYPE) -> FWPM_FILTER_CONDITION0 {
        let mut c: FWPM_FILTER_CONDITION0 = unsafe { zeroed() };
        c.fieldKey = field; c.matchType = FWP_MATCH_EQUAL; c.conditionValue.r#type = kind; c
    }
    fn protocol(n: u8) -> FWPM_FILTER_CONDITION0 { let mut c=value(FWPM_CONDITION_IP_PROTOCOL, FWP_UINT8); c.conditionValue.Anonymous.uint8=n; c }
    fn remote_port(n: u16) -> FWPM_FILTER_CONDITION0 { let mut c=value(FWPM_CONDITION_IP_REMOTE_PORT, FWP_UINT16); c.conditionValue.Anonymous.uint16=n; c }
    fn parse_guid(s: &str) -> Result<GUID,String> {
        let text=s.trim_matches(|c| c=='{' || c=='}').replace('-', "");
        u128::from_str_radix(&text,16).map(GUID::from_u128).map_err(|_| "Invalid interface GUID".into())
    }
    pub fn run(args: Vec<String>) -> Result<(),String> {
        let engine=Engine::open()?;
        match args.first().map(String::as_str) {
            Some("status") => { if engine.exists()? { println!("ARMED"); } else { println!("DISARMED"); } Ok(()) },
            Some("recover") => { engine.recover()?; println!("Owned guard policy removed; other firewall policy unchanged."); Ok(()) },
            Some("allow-tunnel") if args.len()==2 => engine.allow_tunnel(&args[1]),
            Some("arm") if args.len()==6 => {
                let ip=args[3].parse().map_err(|_| "Endpoint must be numeric IPv4")?;
                let port=args[4].parse::<u16>().map_err(|_| "Invalid UDP port")?;
                if port==0 { return Err("UDP port must be nonzero".into()); }
                let wg=if args[5]=="-" { None } else { Some(args[5].as_str()) };
                engine.arm(&args[1], &args[2], ip, port, wg)?;
                println!("ARMED: persistent protection; explicit recovery is required after a crash."); Ok(())
            },
            _ => Err("Use status | recover | allow-tunnel GUID | arm ENGINE TOR ENDPOINT PORT OFFICIAL_WG_OR_DASH".into())
        }
    }
}
