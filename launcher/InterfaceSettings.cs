using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

[DataContract]
internal sealed class Adapter
{
    [DataMember(IsRequired = true)] public string Name;
    [DataMember(IsRequired = true)] public int Index;

    public Adapter(string name, int index)
    {
        Name = name;
        Index = index;
    }
}

internal sealed class InterfaceSettings : IDisposable
{
    private static readonly StringComparer Names = StringComparer.OrdinalIgnoreCase;
    private readonly string path;
    private readonly Func<Adapter[]> enumerate;
    private readonly Mutex mutex;
    private readonly DataContractJsonSerializer json = new DataContractJsonSerializer(typeof(Adapter[]));

    public InterfaceSettings(string path, Func<Adapter[]> enumerate)
    {
        this.path = Path.GetFullPath(path);
        this.enumerate = enumerate;
        var acl = new MutexSecurity();
        foreach (var sid in new[] { WindowsIdentity.GetCurrent().User,
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
            acl.AddAccessRule(new MutexAccessRule(sid, MutexRights.FullControl, AccessControlType.Allow));

        using (var sha = SHA256.Create())
        {
            var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(this.path.ToUpperInvariant()));
            bool created;
            mutex = new Mutex(false, @"Global\zapret-interfaces-" + BitConverter.ToString(hash), out created, acl);
        }
    }

    public static Adapter[] Enumerate()
    {
        var adapters = new List<Adapter>();
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            var ip = adapter.GetIPProperties();
            int index = adapter.Supports(NetworkInterfaceComponent.IPv4) ? ip.GetIPv4Properties().Index :
                adapter.Supports(NetworkInterfaceComponent.IPv6) ? ip.GetIPv6Properties().Index : 0;
            if (index > 0) adapters.Add(new Adapter(adapter.Name, index));
        }
        return adapters.OrderBy(adapter => adapter.Index).ToArray();
    }

    public Adapter[] Read()
    {
        try
        {
            using (var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
            {
                var selected = (Adapter[])json.ReadObject(file);
                if (selected == null || selected.Any(adapter => adapter == null ||
                        string.IsNullOrWhiteSpace(adapter.Name) || adapter.Index < 1) ||
                    selected.Select(adapter => adapter.Name).Distinct(Names).Count() != selected.Length)
                    throw new InvalidDataException("Invalid network interface selection in " + path);
                return selected;
            }
        }
        catch (FileNotFoundException) { return new Adapter[0]; }
    }

    private T Locked<T>(Func<T> action)
    {
        try
        {
            if (!mutex.WaitOne(1000)) throw new IOException("Network interface settings are busy.");
        }
        catch (AbandonedMutexException) { }
        try { return action(); }
        finally { mutex.ReleaseMutex(); }
    }

    private void Write(Adapter[] selected)
    {
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var file = File.Open(temporary, FileMode.CreateNew, FileAccess.Write))
                json.WriteObject(file, selected);
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { File.Delete(temporary); }
    }

    public void Save(Adapter[] selected)
    {
        Locked(() => { Write(selected); return true; });
    }

    // null means unrestricted. An empty result means the selected interfaces are absent.
    public Adapter[] Refresh()
    {
        return Locked(() =>
        {
            var selected = Read();
            if (selected.Length == 0) return null;

            var available = enumerate();
            var active = new List<Adapter>();
            bool changed = false;
            foreach (var saved in selected)
            {
                var matches = available.Where(adapter => Names.Equals(saved.Name, adapter.Name)).ToArray();
                if (matches.Length != 1) continue;
                var current = matches[0];
                if (available.Count(adapter => adapter.Index == current.Index) != 1) continue;
                active.Add(current);
                if (saved.Index == current.Index) continue;
                saved.Index = current.Index;
                changed = true;
            }
            if (changed) Write(selected);
            return active.ToArray();
        });
    }

    public void Configure()
    {
        try
        {
            var selected = Read();
            Console.WriteLine(selected.Length == 0 ? "Current selection: all interfaces" :
                "Saved selection: " + string.Join(", ", selected.Select(item => item.Index + " " + item.Name)));
        }
        catch (SerializationException) { Console.WriteLine("The saved selection is invalid."); }
        catch (InvalidDataException) { Console.WriteLine("The saved selection is invalid."); }

        var adapters = enumerate();
        Console.WriteLine();
        foreach (var adapter in adapters)
            Console.WriteLine("  {0,5}  {1}", adapter.Index, adapter.Name);

        while (true)
        {
            Console.Write("Enter interface indices separated by spaces or commas (0 = all, Enter = cancel): ");
            string input = Console.ReadLine();
            if (string.IsNullOrWhiteSpace(input)) return;
            input = input.Trim();
            if (input == "0")
            {
                Save(new Adapter[0]);
                Console.WriteLine("Saved. All interfaces are allowed.");
                return;
            }

            var selected = new List<Adapter>();
            string[] tokens = Regex.Split(input, @"[\s,]+");
            foreach (string token in tokens)
            {
                int index;
                if (!int.TryParse(token, NumberStyles.None, CultureInfo.InvariantCulture, out index)) break;
                var matches = adapters.Where(adapter => adapter.Index == index).ToArray();
                if (matches.Length != 1 || adapters.Count(adapter => Names.Equals(adapter.Name, matches[0].Name)) != 1)
                    break;
                selected.Add(matches[0]);
            }
            if (selected.Count == tokens.Length)
            {
                Save(selected.Distinct().ToArray());
                Console.WriteLine("Saved. Running zapret will apply the selection automatically.");
                return;
            }
            Console.WriteLine("Use the indices from the list above.");
        }
    }

    public void Dispose()
    {
        mutex.Dispose();
    }
}
