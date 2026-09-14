using System.IO;
using System.Text.Json.Nodes;
using PascalCockpit.Contracts;

namespace PascalCockpit.App;

/// <summary>
/// Isolated replay of a previously collected batch. Production configs do not set this path.
/// </summary>
public sealed class FrozenCollectionCollector : ICollector
{
    readonly string _path;

    public FrozenCollectionCollector(string path)
    {
        _path = path;
    }

    public Task<CollectionBatch> CollectAsync(CollectorSettings settings, CancellationToken cancellationToken)
    {
        _ = settings;
        cancellationToken.ThrowIfCancellationRequested();
        using var fs = File.OpenRead(_path);
        var node = JsonNode.Parse(fs) as JsonObject
                   ?? throw new InvalidDataException("frozen collection is not an object");
        var collectedAt = node["CollectedAt"] is JsonValue cav && cav.TryGetValue<DateTimeOffset>(out var cat)
            ? cat
            : DateTimeOffset.Parse(node["CollectedAt"]!.ToString());
        var docs = new List<RawDocument>();
        if (node["Documents"] is JsonArray arr)
        {
            foreach (var item in arr)
            {
                if (item is not JsonObject o) continue;
                var data = o["Data"]?.DeepClone() as JsonObject ?? new JsonObject();
                docs.Add(new RawDocument(
                    o["Id"]?.GetValue<string>() ?? "",
                    o["Kind"]?.GetValue<string>() ?? "",
                    o["Location"]?.GetValue<string>() ?? "",
                    data,
                    o["ObservedAt"] is JsonValue ov && ov.TryGetValue<DateTimeOffset>(out var oa) ? oa : collectedAt,
                    o["FactAt"] is JsonValue fv && fv.TryGetValue<DateTimeOffset>(out var fa) ? fa : null,
                    o["ProjectHint"]?.GetValue<string>(),
                    o["Scope"]?.GetValue<string>()));
            }
        }

        var issues = new List<SourceIssue>();
        if (node["Issues"] is JsonArray ia)
        {
            foreach (var item in ia)
            {
                if (item is not JsonObject o) continue;
                issues.Add(new SourceIssue(
                    o["SourceId"]?.GetValue<string>() ?? "",
                    o["Code"]?.GetValue<string>() ?? "",
                    o["Detail"]?.GetValue<string>() ?? "",
                    o["ObservedAt"] is JsonValue ov && ov.TryGetValue<DateTimeOffset>(out var oa) ? oa : collectedAt));
            }
        }

        return Task.FromResult(new CollectionBatch(collectedAt, docs, issues));
    }
}
