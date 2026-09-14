using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using PascalCockpit.Contracts;

namespace PascalCockpit.App;

/// <summary>
/// Launch configuration. Credentials / tokens / cookies are never accepted.
/// send_messages_automatically is forced false for this product.
/// </summary>
public sealed class AppConfig
{
    public IReadOnlyList<string> RegistryPaths { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> AdditionalSourcePaths { get; init; } = Array.Empty<string>();
    public string? FrozenCollectionPath { get; init; }
    public int RefreshSeconds { get; init; } = 5;
    public int MaxFileBytes { get; init; } = 1_048_576;
    public int MaxFilesPerRefresh { get; init; } = 512;
    public bool ReadOnly { get; init; } = true;
    public bool AllowNetwork { get; init; }
    public bool SendMessagesAutomatically { get; init; }
    public string? LoadedFrom { get; init; }
    public IReadOnlyList<string> RejectedSecretKeys { get; init; } = Array.Empty<string>();

    public static readonly HashSet<string> ForbiddenKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "token", "access_token", "refresh_token", "password", "cookie", "cookies",
        "authorization", "api_key", "apikey", "secret", "client_secret",
        "credential", "credentials", "auth", "session"
    };

    public static AppConfig Load(string? explicitPath = null)
    {
        var path = explicitPath ?? FindConfigPath();
        if (path is null || !File.Exists(path))
        {
            return new AppConfig { LoadedFrom = null };
        }

        try
        {
            var json = File.ReadAllText(path);
            return Parse(json, path);
        }
        catch (Exception)
        {
            return new AppConfig { LoadedFrom = path };
        }
    }

    public static AppConfig Parse(string json, string? loadedFrom = null)
    {
        JsonNode? node;
        try { node = JsonNode.Parse(json); }
        catch (JsonException) { return new AppConfig { LoadedFrom = loadedFrom }; }

        if (node is not JsonObject obj)
            return new AppConfig { LoadedFrom = loadedFrom };

        var rejected = new List<string>();
        foreach (var kv in obj)
        {
            if (ForbiddenKeys.Contains(kv.Key))
                rejected.Add(kv.Key);
        }

        var registry = ReadStringList(obj, "registry_paths");
        var extra = ReadStringList(obj, "additional_source_paths");
        var frozen = obj["frozen_collection_path"]?.GetValue<string>();
        var refresh = ReadInt(obj, "refresh_seconds", 5);
        if (refresh < 1) refresh = 1;
        if (refresh > 3600) refresh = 3600;
        var maxBytes = ReadInt(obj, "max_file_bytes", 1_048_576);
        var maxFiles = ReadInt(obj, "max_files_per_refresh", 512);

        return new AppConfig
        {
            RegistryPaths = registry,
            AdditionalSourcePaths = extra,
            FrozenCollectionPath = string.IsNullOrWhiteSpace(frozen) ? null : frozen,
            RefreshSeconds = refresh,
            MaxFileBytes = maxBytes > 0 ? maxBytes : 1_048_576,
            MaxFilesPerRefresh = maxFiles > 0 ? maxFiles : 512,
            ReadOnly = ReadBool(obj, "read_only", true),
            AllowNetwork = ReadBool(obj, "allow_network", false),
            SendMessagesAutomatically = false,
            LoadedFrom = loadedFrom,
            RejectedSecretKeys = rejected
        };
    }

    public CollectorSettings ToCollectorSettings() =>
        new(RegistryPaths, AdditionalSourcePaths, MaxFileBytes, MaxFilesPerRefresh);

    public static string? FindConfigPath()
    {
        var env = Environment.GetEnvironmentVariable("PASCAL_COCKPIT_CONFIG");
        if (!string.IsNullOrWhiteSpace(env) && File.Exists(env))
            return env;

        if (File.Exists(ProductPaths.ConfigFile))
            return ProductPaths.ConfigFile;

        var baseDir = AppContext.BaseDirectory;
        foreach (var rel in new[]
                 {
                     System.IO.Path.Combine("config", "production.json"),
                     System.IO.Path.Combine("config", "development.json"),
                     System.IO.Path.Combine("..", "..", "..", "..", "config", "development.sample.json"),
                     System.IO.Path.Combine("..", "..", "..", "..", "..", "config", "development.sample.json")
                 })
        {
            var candidate = System.IO.Path.GetFullPath(System.IO.Path.Combine(baseDir, rel));
            if (File.Exists(candidate))
                return candidate;
        }

        return null;
    }

    static IReadOnlyList<string> ReadStringList(JsonObject obj, string key)
    {
        if (obj[key] is not JsonArray arr)
            return Array.Empty<string>();
        var list = new List<string>();
        foreach (var item in arr)
        {
            var s = item?.GetValue<string>();
            if (!string.IsNullOrWhiteSpace(s))
                list.Add(s);
        }
        return list;
    }

    static int ReadInt(JsonObject obj, string key, int fallback)
    {
        if (obj[key] is JsonValue v && v.TryGetValue<int>(out var n))
            return n;
        return fallback;
    }

    static bool ReadBool(JsonObject obj, string key, bool fallback)
    {
        if (obj[key] is JsonValue v && v.TryGetValue<bool>(out var b))
            return b;
        return fallback;
    }
}
