using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

// Launch only a headless host. Its children/transport job are managed by existing code.
public static class HybridDetachedLauncher {
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {
        public int Length;
        public IntPtr Descriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo {
        public int cb;
        public IntPtr reserved, desktop, title;
        public int x,y,xSize,ySize,xChars,yChars,fill;
        public uint flags;
        public short show, reservedBytes;
        public IntPtr reserved2,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx {
        public StartupInfo info;
        public IntPtr attributes;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {
        public IntPtr process,thread;
        public uint pid,tid;
    }
    [StructLayout(LayoutKind.Sequential)] struct FileTime { public uint low,high; }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true,ExactSpelling=true)]
    static extern SafeFileHandle CreateFileW(string path,uint access,uint share,ref SecurityAttributes attributes,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref IntPtr bytes);
    [DllImport("kernel32.dll",SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true,ExactSpelling=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    static extern bool CreateProcessW(string application,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,[MarshalAs(UnmanagedType.Bool)]bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfoEx startup,out ProcessInfo process);
    [DllImport("kernel32.dll",SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    static extern bool IsProcessInJob(IntPtr process,IntPtr job,[MarshalAs(UnmanagedType.Bool)]out bool result);
    [DllImport("kernel32.dll",SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    static extern bool GetProcessTimes(IntPtr process,out FileTime created,out FileTime exited,out FileTime kernel,out FileTime user);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] [return:MarshalAs(UnmanagedType.Bool)] static extern bool CloseHandle(IntPtr handle);

    public static string Quote(string value) {
        if(value==null) throw new ArgumentNullException(nameof(value));
        if(value.IndexOf('\0')>=0) throw new ArgumentException("NUL is invalid in a process argument");
        var result=new StringBuilder("\"");
        int slashes=0;
        foreach(char c in value) {
            if(c=='\\') { slashes++; continue; }
            if(c=='\"') { result.Append('\\',slashes*2+1);result.Append(c);slashes=0;continue; }
            result.Append('\\',slashes);slashes=0;result.Append(c);
        }
        result.Append('\\',slashes*2);result.Append('"');return result.ToString();
    }
    public static Process Start(string executable,string[] arguments,string directory,string logPrefix) {
        if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows is required");
        executable=Path.GetFullPath(executable);directory=Path.GetFullPath(directory);logPrefix=Path.GetFullPath(logPrefix);
        if(!File.Exists(executable)) throw new FileNotFoundException("PowerShell executable missing",executable);
        var command=new StringBuilder(Quote(executable));
        foreach(string arg in arguments) command.Append(' ').Append(Quote(arg));
        if(command.Length>=32767) throw new ArgumentException("Process command line is too long");
        var security=new SecurityAttributes {Length=Marshal.SizeOf<SecurityAttributes>(),Inherit=true};
        using(var input=CreateFileW("NUL",0x80000000,3,ref security,3,0x80,IntPtr.Zero))
        using(var output=CreateFileW(logPrefix+"-stdout.log",0x40000000,3,ref security,1,0x80,IntPtr.Zero))
        using(var error=CreateFileW(logPrefix+"-stderr.log",0x40000000,3,ref security,1,0x80,IntPtr.Zero)) {
            if(input.IsInvalid||output.IsInvalid||error.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot open background host log handles");
            IntPtr size=IntPtr.Zero,list=IntPtr.Zero,handles=IntPtr.Zero;
            bool initialized=false,createdProcess=false,started=false;
            var process=new ProcessInfo();
            try {
                InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);
                if(size==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                list=Marshal.AllocHGlobal(size);
                if(!InitializeProcThreadAttributeList(list,1,0,ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
                initialized=true;
                handles=Marshal.AllocHGlobal(IntPtr.Size*3);
                Marshal.WriteIntPtr(handles,0,input.DangerousGetHandle());
                Marshal.WriteIntPtr(handles,IntPtr.Size,output.DangerousGetHandle());
                Marshal.WriteIntPtr(handles,IntPtr.Size*2,error.DangerousGetHandle());
                if(!UpdateProcThreadAttribute(list,0,new IntPtr(0x00020002),handles,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
                bool parentInJob;
                if(!IsProcessInJob(new IntPtr(-1),IntPtr.Zero,out parentInJob)) throw new Win32Exception(Marshal.GetLastWin32Error());
                // No console, no inherited terminal pipes, and no inherited parent job.
                uint flags=0x08000000u|0x00080000u|0x00000004u;
                if(parentInJob) flags|=0x01000000u;
                var startup=new StartupInfoEx();startup.info.cb=Marshal.SizeOf<StartupInfoEx>();startup.info.flags=0x100;
                startup.info.input=input.DangerousGetHandle();startup.info.output=output.DangerousGetHandle();startup.info.error=error.DangerousGetHandle();startup.attributes=list;
                string commandText=command.ToString();
                createdProcess=CreateProcessW(executable,command,IntPtr.Zero,IntPtr.Zero,true,flags,IntPtr.Zero,directory,ref startup,out process);
                int creationError=createdProcess?0:Marshal.GetLastWin32Error();
                if(!createdProcess && parentInJob && creationError==5) {
                    // A SILENT_BREAKAWAY job may allow automatic escape but reject an explicit request.
                    // The retry is still suspended and must pass the same no-parent-job check below.
                    command=new StringBuilder(commandText);process=new ProcessInfo();
                    createdProcess=CreateProcessW(executable,command,IntPtr.Zero,IntPtr.Zero,true,flags&~0x01000000u,IntPtr.Zero,directory,ref startup,out process);
                    creationError=createdProcess?0:Marshal.GetLastWin32Error();
                }
                if(!createdProcess) throw new Win32Exception(creationError,"Could not create an independent background host; parent job may prohibit breakaway");
                bool childInJob;
                if(!IsProcessInJob(process.process,IntPtr.Zero,out childInJob)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if(childInJob) throw new InvalidOperationException("Background host still belongs to a parent job; refusing unsafe launch");
                FileTime created,exited,kernel,user;
                if(!GetProcessTimes(process.process,out created,out exited,out kernel,out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
                long ticks=DateTime.FromFileTimeUtc((long)(((ulong)created.high<<32)|created.low)).Ticks;
                if(ResumeThread(process.thread)==uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
                var managed=Process.GetProcessById((int)process.pid);
                try {
                    if(managed.StartTime.ToUniversalTime().Ticks!=ticks) throw new InvalidOperationException("Background host identity changed during launch");
                    started=true;return managed;
                } catch { managed.Dispose();throw; }
            } finally {
                if(createdProcess && !started) TerminateProcess(process.process,1);
                if(createdProcess && process.thread!=IntPtr.Zero) CloseHandle(process.thread);
                if(createdProcess && process.process!=IntPtr.Zero) CloseHandle(process.process);
                if(initialized) DeleteProcThreadAttributeList(list);
                if(handles!=IntPtr.Zero) Marshal.FreeHGlobal(handles);
                if(list!=IntPtr.Zero) Marshal.FreeHGlobal(list);
            }
        }
    }
}
