#!/usr/bin/env python3
"""Build the embedded read-only x64 Windows Installer custom action."""
from pathlib import Path
import os, subprocess
r=Path(__file__).resolve().parent
subprocess.run([os.environ.get('MINGW_CC','x86_64-w64-mingw32-gcc'),'-std=c11','-O2','-Wall','-Wextra','-Werror','-shared','-static-libgcc','-Wl,--no-insert-timestamp','-Wl,--kill-at',str(r/'inventory.c'),'-o',str(r/'whispr-preflight.dll'),'-lmsi','-lshell32','-ladvapi32','-lfwpuclnt','-lbcrypt'],check=True)
