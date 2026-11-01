using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

// A lifetime owner for the unchanged console-oriented Session.ps1.
// The host's input writer remains open; closing a terminal/tray cannot send EOF.
public sealed class HybridBackgroundSessionHost : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Basic {
        public long user,kernel;public uint flags;
        public UIntPtr minimum,maximum;public uint count;public UIntPtr affinity;public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO {public ulong a,b,c,d,e,f;}
    [StructLayout(LayoutKind.Sequential)] struct Extended {public Basic basic;public IO io;public UIntPtr a,b,c,d;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateJobObject(IntPtr attributes,string name);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool SetInformationJobObject(SafeFileHandle job,int info,ref Extended value,uint length);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool AssignProcessToJobObject(SafeFileHandle job,IntPtr process);
    readonly SafeFileHandle job;
    Process session;
    FileStream stdout,stderr;
    Task outputCopy,errorCopy;
    bool disposed;
    public HybridBackgroundSessionHost() {
        job=CreateJobObject(IntPtr.Zero,null);
        if(job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var info=new Extended();info.basic.flags=0x2000;
        if(!SetInformationJobObject(job,9,ref info,(uint)Marshal.SizeOf<Extended>())) {int error=Marshal.GetLastWin32Error();job.Dispose();throw new Win32Exception(error);}
    }
    public Process Start(string executable,string sessionScript,string directory,string logPrefix) {
        if(disposed) throw new ObjectDisposedException(nameof(HybridBackgroundSessionHost));
        executable=Path.GetFullPath(executable);sessionScript=Path.GetFullPath(sessionScript);directory=Path.GetFullPath(directory);logPrefix=Path.GetFullPath(logPrefix);
        if(session!=null) throw new InvalidOperationException("Only one owned session per host");
        stdout=new FileStream(logPrefix+"-stdout.log",FileMode.CreateNew,FileAccess.Write,FileShare.ReadWrite,1,FileOptions.Asynchronous);
        stderr=new FileStream(logPrefix+"-stderr.log",FileMode.CreateNew,FileAccess.Write,FileShare.ReadWrite,1,FileOptions.Asynchronous);
        var start=new ProcessStartInfo(executable) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=directory};
        foreach(string arg in new[]{"-NoLogo","-NoProfile","-File",sessionScript}) start.ArgumentList.Add(arg);
        session=new Process {StartInfo=start};
        if(!session.Start()) throw new InvalidOperationException("Could not start the background-owned session");
        if(!AssignProcessToJobObject(job,session.Handle)) {
            int error=Marshal.GetLastWin32Error();try {session.Kill(true);session.WaitForExit(5000);}catch{}
            throw new Win32Exception(error,"Could not contain the background session");
        }
        session.StandardInput.AutoFlush=true;
        outputCopy=session.StandardOutput.BaseStream.CopyToAsync(stdout);
        errorCopy=session.StandardError.BaseStream.CopyToAsync(stderr);
        return session;
    }
    public void Dispose() {
        if(disposed) return;disposed=true;
        job.Dispose(); // Failure of this host kills its session and descendants; guard stays armed.
        if(session!=null) {
            try {session.StandardInput.Close();}catch{}
            try {session.WaitForExit(5000);}catch{}
        }
        if(outputCopy!=null && errorCopy!=null) {try {Task.WaitAll(new[]{outputCopy,errorCopy},5000);}catch{}}
        if(stdout!=null) stdout.Dispose();if(stderr!=null) stderr.Dispose();
        if(session!=null) session.Dispose();
    }
}
