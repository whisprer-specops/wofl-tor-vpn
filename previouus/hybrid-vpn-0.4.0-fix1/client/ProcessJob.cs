using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public sealed class HybridProcessJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Basic {
        public long PerProcessUserTimeLimit,PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize,MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass,SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO {
        public ulong ReadOperationCount,WriteOperationCount,OtherOperationCount,ReadTransferCount,WriteTransferCount,OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)] struct Extended {
        public Basic BasicLimitInformation;
        public IO IoInfo;
        public UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateJobObject(IntPtr attributes,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(SafeFileHandle job,int informationClass,ref Extended info,uint length);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(SafeFileHandle job,IntPtr process);
    readonly SafeFileHandle job;
    readonly List<Process> children=new List<Process>();
    readonly List<FileStream> streams=new List<FileStream>();
    readonly List<Task> copies=new List<Task>();
    bool disposed;
    public HybridProcessJob() {
        job=CreateJobObject(IntPtr.Zero,null);
        if(job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var info=new Extended();info.BasicLimitInformation.LimitFlags=0x2000; // KILL_ON_JOB_CLOSE
        if(!SetInformationJobObject(job,9,ref info,(uint)Marshal.SizeOf<Extended>())) {
            int error=Marshal.GetLastWin32Error();job.Dispose();throw new Win32Exception(error);
        }
    }
    public Process Start(string exe,string[] arguments,string workingDirectory,string logPrefix) {
        if(disposed) throw new ObjectDisposedException(nameof(HybridProcessJob));
        var si=new ProcessStartInfo(exe) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=workingDirectory};
        foreach(var arg in arguments) si.ArgumentList.Add(arg);
        var p=new Process {StartInfo=si};
        if(!p.Start()) throw new Exception("Could not start owned transport");
        if(!AssignProcessToJobObject(job,p.Handle)) {
            int error=Marshal.GetLastWin32Error();try{p.Kill(true);p.WaitForExit(3000);}finally{p.Dispose();}
            throw new Win32Exception(error,"Could not contain owned process in kill-on-close job");
        }
        children.Add(p);
        var stdout=new FileStream(logPrefix+"-stdout.log",FileMode.Create,FileAccess.Write,FileShare.ReadWrite,1,FileOptions.Asynchronous);
        var stderr=new FileStream(logPrefix+"-stderr.log",FileMode.Create,FileAccess.Write,FileShare.ReadWrite,1,FileOptions.Asynchronous);
        streams.Add(stdout);streams.Add(stderr);
        copies.Add(p.StandardOutput.BaseStream.CopyToAsync(stdout));
        copies.Add(p.StandardError.BaseStream.CopyToAsync(stderr));
        return p;
    }
    public void Dispose() {
        if(disposed)return;disposed=true;
        job.Dispose(); // Kernel kills this job's children even if the script cannot run cleanup.
        foreach(var p in children){try{p.WaitForExit(5000);}catch{} p.Dispose();}
        try{Task.WaitAll(copies.ToArray(),5000);}catch{}
        foreach(var s in streams)s.Dispose();
    }
}
