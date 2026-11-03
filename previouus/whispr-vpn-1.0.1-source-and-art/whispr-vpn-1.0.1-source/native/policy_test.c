#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "policy.h"
#define EXPECT(s,label,blocked) do{Decision d=decide_install(&(s));assert(!strcmp(d.state,label));assert(d.block==(blocked));}while(0)
int main(void){
 Snapshot s={0};EXPECT(s,"fresh-install",0);
 s.core_dir=1;s.core_marker=1;s.core_complete=1;EXPECT(s,"existing-legacy-client",0);
 s.registered=1;s.desktop_complete=1;EXPECT(s,"existing-managed-desktop",0);
 s.desktop_complete=0;EXPECT(s,"repair-managed-desktop",0);
 s.cache_missing=1;EXPECT(s,"missing-installer-cache",1);s.cache_missing=0;
 s.core_complete=0;EXPECT(s,"partial-client",1);
 s.resumable=1;EXPECT(s,"resumable-client-setup",0);
 s.resumable=0;s.core_dir=0;s.state_dir=1;EXPECT(s,"orphaned-client-state",1);
 s.profiles=1;s.key=0;EXPECT(s,"identity-missing",1);
 s.key=1;s.resumable=1;EXPECT(s,"resumable-client-setup",0);
 s.uncertain=1;EXPECT(s,"protected-state",0);
 s.newer=1;EXPECT(s,"newer-version",1);
 s=(Snapshot){0};s.desktop_dir=1;EXPECT(s,"unrecognised-desktop-folder",1);s.desktop_known=1;EXPECT(s,"recover-desktop-files",0);
 s=(Snapshot){0};assert(!decide_remove(&s).block);s.runtime_tasks=1;assert(decide_remove(&s).block);s.runtime_tasks=0;s.guard=1;assert(decide_remove(&s).block);s.guard=0;s.runtime_processes=1;assert(decide_remove(&s).block);
 s=(Snapshot){0};s.lease=1;assert(!decide_remove(&s).block);s.core_dir=1;assert(decide_remove(&s).block);s=(Snapshot){0};s.links=1;EXPECT(s,"linked-install-path",1);
 s=(Snapshot){0};s.guard=1;EXPECT(s,"orphaned-protection",1);s=(Snapshot){0};s.links=1;assert(decide_remove(&s).block);s=(Snapshot){0};s.core_dir=1;s.uncertain=1;EXPECT(s,"protected-state",0);
 puts("PASS: fresh, legacy, managed, partial, cache-missing, orphaned, missing-key, resumable, protected, newer and removal-dependency policy cases.");return 0;
}
