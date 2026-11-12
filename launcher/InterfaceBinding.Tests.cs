using System;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;

internal static class InterfaceBindingTests
{
    private static void Expect(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static string Indices(Adapter[] adapters)
    {
        return string.Join(",", adapters.Select(adapter => adapter.Index));
    }

    private static void TestSelection()
    {
        var path = Path.Combine(Path.GetTempPath(), "zapret-" + Guid.NewGuid() + ".json");
        var ethernet = new Adapter("Ethernet", 13);
        var wifi = new Adapter("Беспроводная сеть", 22);
        var vpn = new Adapter("VPN", 66);
        Adapter[] available = { ethernet, wifi, vpn };
        using (var settings = new InterfaceSettings(path, () => available))
        {
            try
            {
                Expect(settings.Refresh() == null, "Missing settings should allow all interfaces");
                settings.Save(new[] { ethernet });
                Expect(Indices(settings.Refresh()) == "13", "Single selection");
                settings.Save(new[] { ethernet, wifi });
                Expect(Indices(settings.Refresh()) == "13,22", "Multiple selections");

                available = new[] { wifi, new Adapter("VPN", 13) };
                Expect(Indices(settings.Refresh()) == "22", "Never use a stale index now assigned to VPN");
                available = new[] { new Adapter("Ethernet", 41), wifi, new Adapter("VPN", 13) };
                Expect(Indices(settings.Refresh()) == "41,22", "Restore Ethernet independently at its new index");
                Expect(settings.Read()[0].Index == 41, "Persist the new index");

                available = new[] { vpn };
                Expect(settings.Refresh().Length == 0, "When every selection is absent, intercept nothing");
                settings.Save(new Adapter[0]);
                Expect(settings.Refresh() == null, "Explicitly disabling the restriction should allow all interfaces");
            }
            finally { File.Delete(path); }
        }
        Console.WriteLine("Interface selection and index reassignment passed.");
    }

    private static int Main(string[] args)
    {
        ProcessJob.ContainChildren();
        TestSelection();
        TestWatcher(args[0], false);
        TestWatcher(args[0], true);
        return 0;
    }

    private static int WaitForWorker(string directory, int index, int exclude = 0)
    {
        for (int attempt = 0; attempt < 100; attempt++)
        {
            foreach (var file in Directory.GetFiles(directory, index + "-*.log"))
            {
                int pid = int.Parse(Path.GetFileNameWithoutExtension(file).Split('-')[1]);
                if (pid == exclude || !IsRunning(pid)) continue;
                string[] args = File.ReadAllLines(file);
                if (args.Length == 0) continue;
                if (index != 0)
                    Expect(args[0] == "--wf-raw=ifIdx=" + index + " and (outbound and tcp.DstPort=443)",
                        "Binding should compose with the preset filter without restricting SubIfIdx.");
                Expect(args.Contains("--comment=original strategy"), "Preserve quoted preset arguments");
                return pid;
            }
            Thread.Sleep(100);
        }
        throw new Exception("No worker for interface " + index);
    }

    private static bool IsRunning(int pid)
    {
        try
        {
            using (var process = System.Diagnostics.Process.GetProcessById(pid)) return !process.HasExited;
        }
        catch (ArgumentException) { return false; }
    }

    private static void TestWatcher(string engine, bool service)
    {
        var dir = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "zapret watch " + Guid.NewGuid())).FullName;
        var ethernet = new Adapter("Ethernet", 13);
        var wifi = new Adapter("Wi-Fi", 22);
        Adapter[] available = { ethernet, wifi };
        using (var stop = new ManualResetEvent(false))
        using (var settings = new InterfaceSettings(Path.Combine(dir, "interfaces.json"), () => Volatile.Read(ref available)))
        {
            Exception failure = null;
            var watcher = new Thread(() =>
            {
                try
                {
                    string args = "\"--comment=original strategy\" \"--fixture=" + dir + "\"";
                    WinwsLauncher.Watch(settings, engine, args, true, service, stop, Console.WriteLine);
                }
                catch (Exception error) { failure = error; }
            });
            watcher.Start();
            try
            {
                int unrestricted = WaitForWorker(dir, 0);
                settings.Save(new[] { ethernet });
                int originalEthernet = WaitForWorker(dir, 13);
                Expect(!IsRunning(unrestricted), "Stop the unrestricted worker before starting a restricted worker");
                settings.Save(new[] { ethernet, wifi });
                int originalWifi = WaitForWorker(dir, 22);
                Expect(IsRunning(originalEthernet), "Adding Wi-Fi should keep the Ethernet worker");

                Volatile.Write(ref available, new[] { new Adapter("Ethernet", 41), wifi, new Adapter("VPN", 13) });
                int replacement = WaitForWorker(dir, 41);
                Expect(!IsRunning(originalEthernet), "Stop the worker for the index now assigned to the VPN");
                Expect(IsRunning(originalWifi), "Keep the unaffected Wi-Fi worker");
                Expect(settings.Read()[0].Index == 41, "Persist the replacement index");

                Volatile.Write(ref available, new[] { new Adapter("VPN", 13) });
                for (int attempt = 0; attempt < 50 && (IsRunning(replacement) || IsRunning(originalWifi)); attempt++)
                    Thread.Sleep(100);
                Expect(!IsRunning(replacement) && !IsRunning(originalWifi), "Stop capture when all selections disappear");
                Expect(Directory.GetFiles(dir, "0-*.log").Length == 1, "Do not fall back to unrestricted capture");

                Volatile.Write(ref available, new[] { wifi });
                int returnedWifi = WaitForWorker(dir, 22, originalWifi);
                stop.Set();
                watcher.Join();
                Expect(!IsRunning(returnedWifi), "Stopping the watcher must stop the remaining worker");
            }
            finally
            {
                stop.Set();
                watcher.Join();
                foreach (string file in Directory.GetFiles(dir)) File.Delete(file);
                Directory.Delete(dir);
                if (failure != null) throw new Exception("Watcher failed", failure);
            }
        }
        Console.WriteLine(service ? "Service-mode watcher passed." : "Manual-mode watcher passed.");
    }
}

internal static class FakeWinws
{
    private static void Main(string[] args)
    {
        string save = args.FirstOrDefault(arg => arg.StartsWith("--wf-save="));
        if (save != null)
        {
            File.WriteAllText(save.Substring("--wf-save=".Length), "outbound\n  and tcp.DstPort=443\n");
            return;
        }
        string dir = args.Single(arg => arg.StartsWith("--fixture=")).Substring("--fixture=".Length);
        var binding = Regex.Match(args[0], @"^--wf-raw=ifIdx=(\d+) and ");
        string index = binding.Success ? binding.Groups[1].Value : "0";
        int pid = System.Diagnostics.Process.GetCurrentProcess().Id;
        File.WriteAllLines(Path.Combine(dir, index + "-" + pid + ".log"), args);
        Thread.Sleep(Timeout.Infinite);
    }
}
