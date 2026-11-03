#ifndef WHISPR_POLICY_H
#define WHISPR_POLICY_H
/* Pure policy: filesystem/registry/service reads are supplied by the Windows adapter. */
typedef struct {
 int registered, older, cache_missing, newer, unknown_registration, links;
 int desktop_dir, desktop_known, desktop_complete;
 int core_dir, core_marker, core_complete, state_dir, key, profiles, resumable;
 int tasks, runtime_tasks, runtime_processes, desktop_owned, lease, guard, torvpn, uncertain;
} Snapshot;
typedef struct { const char *state; const char *action; int block; } Decision;
static Decision decide_install(const Snapshot *s){
 if(s->links)return (Decision){"linked-install-path","An install/state path is a reparse point. Setup stopped before following it; review that path first.",1};
 if(s->newer)return (Decision){"newer-version","A newer whispr VPN is registered. Use its installer; downgrade is blocked.",1};
 if(s->unknown_registration)return (Decision){"unrecognised-registration","An unrecognised product uses this upgrade family. Review it before setup.",1};
 if(s->cache_missing)return (Decision){"missing-installer-cache","Windows Installer registration exists but its cached MSI is missing. Recover that product using its matching original MSI before rerunning setup.",1};
 if(s->torvpn)return (Decision){"legacy-vpn-running","The old TorVPN service is running. Stop it using its own controls before continuing.",1};
 if(s->uncertain)return (Decision){"protected-state","Protected state could not be fully inspected in this UI context. The installer repeats the check after elevation, before file changes.",0};
 if(s->guard && !s->core_complete)return (Decision){"orphaned-protection","Persistent whispr protection exists without a complete client. Run the whispr recovery pack before setup; protection was not changed by inventory.",1};
 if(s->profiles && !s->key && !s->uncertain)return (Decision){"identity-missing","Saved exit profiles exist but the private device-key file is missing. Restore the saved identity before setup; a replacement identity will not be generated silently.",1};
 if(s->core_dir && (!s->core_marker || !s->core_complete) && !s->resumable)return (Decision){"partial-client","A partial/unrecognised Hybrid VPN client is present. Run the whispr recovery pack to preserve its identity and quarantine old files, then rerun this MSI.",1};
 if(!s->core_dir && (s->state_dir || s->tasks) && !s->resumable && !s->uncertain)return (Decision){"orphaned-client-state","Saved client state or tasks remain without a complete client. Recover the existing identity/tasks first; setup will not create a parallel client.",1};
 if(s->desktop_dir && !s->registered && !s->desktop_known && !s->uncertain)return (Decision){"unrecognised-desktop-folder","The desktop install folder exists without recognised files or MSI registration. Review/quarantine that folder before setup.",1};
 if(s->resumable)return (Decision){"resumable-client-setup","An interrupted, recognised client setup was detected. Install/repair the desktop, then choose Set up this PC to resume with the existing identity.",0};
 if(s->registered && !s->desktop_complete)return (Decision){"repair-managed-desktop","Registered desktop files are incomplete. This MSI will repair/upgrade the owned desktop files while retaining client keys, profiles and tasks.",0};
 if(s->registered)return (Decision){"existing-managed-desktop","An existing desktop MSI was found. Repair/upgrade it in place; the existing client and saved identity are retained.",0};
 if(s->desktop_dir)return (Decision){"recover-desktop-files","Recognised desktop files remain without registration. Setup will restore the desktop registration/files; saved client state stays in place.",0};
 if(s->core_dir)return (Decision){"existing-legacy-client","A complete legacy Hybrid VPN client was found. Add the desktop controls around it; its identity, exits and tasks stay unchanged.",0};
 return (Decision){"fresh-install","No existing whispr desktop/client/state/tasks were found. Install the desktop; first-time client setup remains an explicit action.",0};
}
static Decision decide_remove(const Snapshot *s){
 if(s->links)return (Decision){"linked-install-path","An install/state path is a reparse point. Review it before removal.",1};
 if(s->runtime_processes)return (Decision){"runtime-in-use","Close the desktop and disconnect/close any VPN tray/session using the bundled runtime, then retry removal.",1};
 if(s->desktop_owned || s->runtime_tasks || (s->lease && (s->core_dir || s->tasks)) || s->guard)return (Decision){"client-dependency","The connection client, a task or persistent protection still needs recovery/removal. Use Remove VPN client or the whispr recovery pack first. Keys and profiles are retained.",1};
 if(s->uncertain)return (Decision){"unverified-dependency","A client/runtime dependency could not be inspected. Removal stopped before deleting runtime files.",1};
 return (Decision){"remove-desktop","No remaining runtime dependency was found. Remove desktop files only; saved client keys/settings are retained.",0};
}
#endif
