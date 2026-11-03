using System;
using System.Text;

// Compatibility filename: argument quoting only; no process creation or breakaway APIs.
public static class HybridDetachedLauncher {
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
}
