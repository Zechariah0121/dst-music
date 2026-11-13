using System;
using System.Diagnostics;

namespace DangoMusic {
    public static class GameProcessMonitor {
        // Dedicated server processes remain alive in some setups after the
        // client closes. Only the two actual Windows game clients count.
        public static bool? IsClientRunning() {
            return ReadPresence(new[] { "dontstarve_steam", "dontstarve_steam_x64" });
        }

        public static bool? ReadPresence(string[] processNames) {
            bool unknown = false;
            foreach (string name in processNames) {
                Process[] processes = null;
                try {
                    processes = Process.GetProcessesByName(name);
                    if (processes.Length > 0) return true;
                } catch {
                    // An enumeration failure is not evidence of a game exit.
                    unknown = true;
                } finally {
                    if (processes != null) foreach (Process process in processes) process.Dispose();
                }
            }
            return unknown ? (bool?)null : false;
        }
    }
}
