using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.Serialization;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

internal sealed class WinwsLauncher : ServiceBase
{
    private const string ServiceFlag = "--zapret-service";
    private const string SettingsFlag = "--zapret-interfaces";
    private static readonly string Bin = AppDomain.CurrentDomain.BaseDirectory;
    private readonly string arguments;
    private readonly bool supportsBinding;
    private readonly ManualResetEvent stopping = new ManualResetEvent(false);
    private Thread watcher;

    private WinwsLauncher(string arguments, bool supportsBinding)
    {
        this.arguments = arguments;
        this.supportsBinding = supportsBinding;
        ServiceName = "zapret";
        CanShutdown = true;
    }

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == SettingsFlag)
            {
                Console.OutputEncoding = Encoding.UTF8;
                using (var settings = OpenSettings()) settings.Configure();
                return 0;
            }

            // Forward the original quoting to the Cygwin engine.
            string arguments = AfterFirstArgument(Environment.CommandLine);
            bool service = args.Length > 0 && args[0] == ServiceFlag;
            if (service)
            {
                arguments = AfterFirstArgument(arguments);
                args = args.Skip(1).ToArray();
            }
            bool supportsBinding = args.Length > 0 && !args[0].StartsWith("@") && !args[0].StartsWith("$") &&
                !args.Any(OverridesFilter);

            using (var launcher = new WinwsLauncher(arguments, supportsBinding))
            {
                // Session 0 also covers services installed before the explicit service flag was added.
                if (service || Process.GetCurrentProcess().SessionId == 0)
                {
                    ServiceBase.Run(launcher);
                    return launcher.ExitCode;
                }

                Console.CancelKeyPress += (sender, e) => { e.Cancel = true; launcher.stopping.Set(); };
                return launcher.Run(false, Console.Error.WriteLine);
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("zapret: " + error.Message);
            return 1;
        }
    }

    private static string AfterFirstArgument(string commandLine)
    {
        return Regex.Replace(commandLine, "^\\s*(?:\"[^\"]*\"|[^\\s]+)\\s*", "");
    }

    private static bool OverridesFilter(string argument)
    {
        string option = argument.Split('=')[0].TrimStart('-');
        if (!option.StartsWith("wf-", StringComparison.Ordinal)) return false;
        // getopt_long_only also accepts unambiguous prefixes of these options.
        return option == "wf-raw" || "wf-iface".StartsWith(option, StringComparison.Ordinal) ||
            "wf-save".StartsWith(option, StringComparison.Ordinal);
    }

    private static InterfaceSettings OpenSettings()
    {
        return new InterfaceSettings(Path.Combine(Bin, "..", "utils", "network_interfaces.json"),
            InterfaceSettings.Enumerate);
    }

    private int Run(bool service, Action<string> log)
    {
        ProcessJob.ContainChildren();
        using (var settings = OpenSettings())
            return Watch(settings, Path.Combine(Bin, "winws-engine.exe"), arguments, supportsBinding, service, stopping, log);
    }

    internal static int Watch(InterfaceSettings settings, string engine, string arguments, bool supportsBinding,
        bool service, WaitHandle stopping, Action<string> log)
    {
        var unrestricted = new[] { new Adapter("", 0) };
        var running = new Dictionary<int, Tuple<Adapter, Process>>();
        var failures = new HashSet<int>();
        string lastError = null;
        string presetFilter = null;
        try
        {
            while (!stopping.WaitOne(0))
            {
                Adapter[] selected;
                try
                {
                    selected = settings.Refresh();
                    lastError = null;
                }
                catch (Exception error)
                {
                    if (!(error is IOException || error is UnauthorizedAccessException ||
                        error is SerializationException || error is InvalidDataException ||
                        error is NetworkInformationException)) throw;
                    selected = new Adapter[0];
                    if (error.Message != lastError) log(error.Message);
                    lastError = error.Message;
                }

                if (selected != null && !supportsBinding)
                    throw new InvalidOperationException("Interface binding requires generated winws filters and explicit preset arguments.");
                var desired = (selected ?? unrestricted).ToDictionary(adapter => adapter.Index);
                foreach (var entry in running.ToArray())
                {
                    var previous = entry.Value.Item1;
                    var process = entry.Value.Item2;
                    Adapter current;
                    if (desired.TryGetValue(entry.Key, out current) &&
                        StringComparer.OrdinalIgnoreCase.Equals(previous.Name, current.Name))
                    {
                        if (!process.HasExited)
                        {
                            failures.Remove(entry.Key);
                            continue;
                        }
                        if (entry.Key == 0) return process.ExitCode;
                        if (failures.Add(entry.Key))
                            log(string.Format("winws exited for {0} ({1}) with code {2}. Retrying.",
                                previous.Name, previous.Index, process.ExitCode));
                    }
                    else
                    {
                        if (entry.Key != 0)
                            log(string.Format("Released {0} ({1}).", previous.Name, previous.Index));
                        failures.Remove(entry.Key);
                    }
                    running.Remove(entry.Key);
                    StopProcess(process);
                }

                if (selected != null && selected.Length > 0 && presetFilter == null)
                {
                    presetFilter = GenerateFilter(engine, arguments, service, stopping);
                    continue;
                }

                foreach (var adapter in desired.Values)
                {
                    if (stopping.WaitOne(0)) break;
                    if (running.ContainsKey(adapter.Index)) continue;
                    string filter = adapter.Index == 0 ? "" : "--wf-raw=\"ifIdx=" +
                        adapter.Index.ToString(CultureInfo.InvariantCulture) + " and (" + presetFilter + ")\" ";
                    var process = StartEngine(engine, filter + arguments, service);
                    running.Add(adapter.Index, Tuple.Create(adapter, process));
                    if (adapter.Index != 0 && !failures.Contains(adapter.Index))
                        log(string.Format("Started winws for {0} ({1}).", adapter.Name, adapter.Index));
                }
                stopping.WaitOne(1000);
            }
            return 0;
        }
        finally
        {
            foreach (var worker in running.Values) StopProcess(worker.Item2);
        }
    }

    private static Process StartEngine(string engine, string arguments, bool service)
    {
        return Process.Start(new ProcessStartInfo(engine, arguments)
        {
            WorkingDirectory = Path.GetDirectoryName(engine),
            UseShellExecute = false,
            CreateNoWindow = service
        });
    }

    private static string GenerateFilter(string engine, string arguments, bool service, WaitHandle stopping)
    {
        // --wf-iface also restricts subIfIdx, so constrain the generated preset filter by ifIdx alone.
        string path = Path.GetTempFileName();
        try
        {
            var probe = StartEngine(engine, "--wf-save=\"" + path + "\" " + arguments, service);
            try
            {
                var timer = Stopwatch.StartNew();
                while (!probe.WaitForExit(100))
                {
                    if (stopping.WaitOne(0)) return null;
                    if (timer.ElapsedMilliseconds >= 10000)
                        throw new System.TimeoutException("Timed out generating the preset's WinDivert filter.");
                }
                string filter = Regex.Replace(File.ReadAllText(path), @"\s+", " ").Trim();
                if (probe.ExitCode != 0 || filter.Length == 0 || filter.Contains("\"") ||
                    Encoding.UTF8.GetByteCount(filter) > 16340)
                    throw new InvalidOperationException("Could not generate the preset's WinDivert filter (exit " +
                        probe.ExitCode + ").");
                return filter;
            }
            finally { StopProcess(probe); }
        }
        finally { File.Delete(path); }
    }

    private static void StopProcess(Process process)
    {
        using (process)
        {
            try { if (!process.HasExited) process.Kill(); }
            catch (InvalidOperationException) { if (!process.HasExited) throw; }
            catch (Win32Exception) { if (!process.HasExited) throw; }
            if (!process.WaitForExit(5000))
                throw new System.TimeoutException("Could not stop winws before updating the interface binding.");
        }
    }

    protected override void OnStart(string[] args)
    {
        watcher = new Thread(() =>
        {
            int code = 1;
            try { code = Run(true, LogService); }
            catch (Exception error) { LogService(error.Message); }
            if (!stopping.WaitOne(0))
            {
                LogService("winws stopped unexpectedly. Exit code: " + code);
                Environment.Exit(code == 0 ? 1 : code);
            }
        });
        watcher.Start();
    }

    private void LogService(string message)
    {
        try { EventLog.WriteEntry(message); }
        catch (Win32Exception) { }
        catch (InvalidOperationException) { }
        catch (System.Security.SecurityException) { }
    }

    protected override void OnStop()
    {
        stopping.Set();
        watcher.Join();
    }

    protected override void OnShutdown()
    {
        OnStop();
    }
}
