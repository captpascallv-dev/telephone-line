using System.IO;
using System.Runtime.InteropServices;

namespace PascalCockpit.App;

/// <summary>
/// Independent product directories. Not TelephoneLine, not CodexUsageHUD,
/// not the legacy autopilot dashboard, and never a shared Codex host path.
/// </summary>
public static class ProductPaths
{
    public const string ProductIdentity = "PascalCockpit";
    public const string DefaultMutexName = @"Local\PascalCockpit.App.SingleInstance.v1";
    public const string SettingsFileName = "window-preferences.json";
    public const string ConfigFileName = "app-config.json";

    public static string MutexName
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("PASCAL_COCKPIT_INSTANCE_NAME");
            if (string.IsNullOrWhiteSpace(env))
                return DefaultMutexName;
            return env.StartsWith(@"Local\", StringComparison.OrdinalIgnoreCase)
                ? env
                : @"Local\" + env.Trim();
        }
    }

    public static string DataDirectory
    {
        get
        {
            var overrideDir = Environment.GetEnvironmentVariable("PASCAL_COCKPIT_DATA_DIR");
            if (!string.IsNullOrWhiteSpace(overrideDir))
                return System.IO.Path.GetFullPath(overrideDir);

            if (OperatingSystem.IsWindows())
            {
                var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                return System.IO.Path.Combine(local, ProductIdentity);
            }

            var xdg = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
            if (!string.IsNullOrWhiteSpace(xdg))
                return System.IO.Path.Combine(xdg, ProductIdentity);

            return System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".local",
                "share",
                ProductIdentity);
        }
    }

    public static string SettingsFile => System.IO.Path.Combine(DataDirectory, SettingsFileName);

    public static string ConfigFile => System.IO.Path.Combine(DataDirectory, ConfigFileName);

    public static void EnsureDataDirectory()
    {
        Directory.CreateDirectory(DataDirectory);
    }

    public static bool IsLegacyOrSharedHostPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        var n = path.Replace('\\', '/');
        return n.Contains("CodexUsageHUD", StringComparison.OrdinalIgnoreCase)
            || n.Contains("TelephoneLine", StringComparison.OrdinalIgnoreCase)
            || n.Contains("PascalGlobalAutopilot", StringComparison.OrdinalIgnoreCase)
            || n.Contains("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsWindowsRuntime => RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
}
