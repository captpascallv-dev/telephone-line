using System.Text.Json.Nodes;
using PascalCockpit.Contracts;

namespace PascalCockpit.Normalization;

/// <summary>
/// Job-scoped identity is dispatch/request/owner/native evidence for that job.
/// ACTIVE_WORK and registry templates may lag after a route switch; they do not
/// override a concrete job document. Model text is never a route.
/// </summary>
public static class JobIdentity
{
    public static int EvidenceRank(SourceFact f)
    {
        var rank = 10;
        foreach (var e in f.Evidence)
        {
            rank = Math.Max(rank, KindRank(e.Kind));
        }

        return rank;
    }

    public static int KindRank(string? kind)
    {
        if (string.IsNullOrWhiteSpace(kind)) return 10;
        if (kind.Equals("direct_request", StringComparison.OrdinalIgnoreCase)
            || kind.Equals("line_dispatch", StringComparison.OrdinalIgnoreCase))
        {
            return 40;
        }

        if (kind.Equals("direct_receipt", StringComparison.OrdinalIgnoreCase)
            || kind.Equals("line_receipt", StringComparison.OrdinalIgnoreCase)
            || kind.Equals("line_delivery", StringComparison.OrdinalIgnoreCase))
        {
            return 30;
        }

        if (kind.Equals("lead_owner", StringComparison.OrdinalIgnoreCase)
            || kind.Equals("cli_child", StringComparison.OrdinalIgnoreCase)
            || kind.Equals("cli_lifecycle", StringComparison.OrdinalIgnoreCase)
            || kind.Equals("process_observation", StringComparison.OrdinalIgnoreCase))
        {
            return 20;
        }

        if (kind.Equals("active_work", StringComparison.OrdinalIgnoreCase)
            || kind.Equals("project_registry", StringComparison.OrdinalIgnoreCase))
        {
            return 5;
        }

        return 10;
    }

    public static string? PreferIdentityValue(string? first, SourceFact firstFact, string? second, SourceFact secondFact)
    {
        var aMissing = IsMissing(first);
        var bMissing = IsMissing(second);
        if (aMissing && bMissing) return null;
        if (aMissing) return second;
        if (bMissing) return first;
        if (string.Equals(first, second, StringComparison.Ordinal)) return first;
        var aRank = EvidenceRank(firstFact);
        var bRank = EvidenceRank(secondFact);
        if (bRank != aRank) return bRank > aRank ? second : first;
        return first;
    }

    public static string? RouteFromModel(string? model)
    {
        if (string.IsNullOrWhiteSpace(model)) return null;
        if (model.StartsWith("cursor-", StringComparison.OrdinalIgnoreCase)
            || model.Contains("cursor-grok", StringComparison.OrdinalIgnoreCase)
            || model.StartsWith("cursor ", StringComparison.OrdinalIgnoreCase))
        {
            return "direct-cursor";
        }

        return null;
    }

    /// <summary>
    /// A grok-* model without cursor is not a grok-cli route. After a cursor
    /// switch it is a stale template, not this job's model.
    /// </summary>
    public static bool ModelFitsRoute(string? route, string? model)
    {
        if (IsMissing(model)) return true;
        if (IsMissing(route)) return true;
        var inferred = RouteFromModel(model);
        if (string.Equals(route, "direct-cursor", StringComparison.OrdinalIgnoreCase))
        {
            if (inferred == "direct-cursor") return true;
            if (LooksPlainGrokModel(model)) return false;
            return true;
        }

        if (inferred == "direct-cursor"
            && route is not null
            && !route.Contains("cursor", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return true;
    }

    public static bool LooksPlainGrokModel(string? model)
    {
        if (string.IsNullOrWhiteSpace(model)) return false;
        if (model.Contains("cursor", StringComparison.OrdinalIgnoreCase)) return false;
        return model.Contains("grok", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Nested objects that name this line/direct (new_/business_/current_) carry
    /// job-scoped native identity. File-level executor_model may lag.
    /// </summary>
    public static (string? Route, string? Model, string? Effort) HarvestJobAlignedNestedIdentity(
        JsonObject? data,
        string? lineId,
        string? directId)
    {
        if (data is null) return (null, null, null);
        if (IsMissing(lineId) && IsMissing(directId)) return (null, null, null);

        string? bestRoute = null;
        string? bestModel = null;
        string? bestEffort = null;
        var bestRouteScore = 0;
        var bestModelScore = 0;
        var bestModelNative = false;

        void Consider(JsonObject obj)
        {
            var score = NestedJobCiteScore(obj, lineId, directId);
            if (score <= 0) return;

            var route = NestedJobRoute(obj);
            if (!IsMissing(route) && LooksLikeRouteId(route)
                && (score > bestRouteScore
                    || (score == bestRouteScore && string.Equals(route, "direct-cursor", StringComparison.OrdinalIgnoreCase))))
            {
                bestRoute = route;
                bestRouteScore = score;
            }

            var native = JsonField.Str(obj, "native_model");
            var model = native
                ?? (HasStaleSwitchPair(obj) ? null : JsonField.Str(obj, "executor_model", "model", "model_id", "model_name"));
            if (!IsMissing(model))
            {
                var nativeHit = !IsMissing(native);
                var better = score > bestModelScore
                             || (score == bestModelScore && nativeHit && !bestModelNative)
                             || (score == bestModelScore && nativeHit == bestModelNative
                                 && RouteFromModel(model) == "direct-cursor"
                                 && RouteFromModel(bestModel) != "direct-cursor");
                if (better)
                {
                    bestModel = model;
                    bestModelScore = score;
                    bestModelNative = nativeHit;
                }
            }

            var effort = JsonField.Str(obj, "executor_effort", "executor_reasoning", "executor_reasoning_effort", "reasoning_effort", "effort");
            if (!IsMissing(effort) && score >= bestRouteScore)
                bestEffort = effort;
        }

        WalkNestedObjects(data, isRoot: true, depth: 0, Consider);
        if (!IsMissing(bestRoute) && !IsMissing(bestModel) && !ModelFitsRoute(bestRoute, bestModel))
            bestModel = null;

        return (bestRoute, bestModel, bestEffort);
    }

    public static void ApplyJobAlignedNestedIdentity(
        JsonObject values,
        JsonObject data,
        string? lineId,
        string? directId)
    {
        var (nestedRoute, nestedModel, nestedEffort) = HarvestJobAlignedNestedIdentity(data, lineId, directId);
        if (!IsMissing(nestedRoute))
            values["route"] = nestedRoute;
        var route = values["route"]?.GetValue<string>() ?? nestedRoute;
        if (!IsMissing(nestedModel) && ModelFitsRoute(route, nestedModel))
            values["model"] = nestedModel;
        if (!IsMissing(nestedEffort) && IsMissing(values["effort"]?.GetValue<string>()))
            values["effort"] = nestedEffort;

        route = values["route"]?.GetValue<string>();
        var model = values["model"]?.GetValue<string>();
        if (!IsMissing(route) && !IsMissing(model) && !ModelFitsRoute(route, model))
            values.Remove("model");

        var actor = values["actor_name"]?.GetValue<string>();
        if (!IsMissing(route)
            && (IsMissing(actor) || LooksLikeRouteId(actor))
            && !string.Equals(actor, route, StringComparison.Ordinal))
        {
            values["actor_name"] = route;
        }
    }

    public static bool LooksLikeRouteId(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return false;
        foreach (var route in RouteCatalog.EightRoutes)
        {
            if (value.Equals(route, StringComparison.OrdinalIgnoreCase)) return true;
        }

        return false;
    }

    public static string? NestedReceiptPath(JsonObject? data, params string[] keys)
    {
        if (data is null) return null;
        foreach (var key in keys)
        {
            var obj = JsonField.Obj(data, key);
            var nested = JsonField.Str(obj, "path");
            if (!string.IsNullOrWhiteSpace(nested)) return nested;
            var direct = JsonField.Str(data, key);
            if (!string.IsNullOrWhiteSpace(direct) && LooksLikePath(direct)) return direct;
        }

        return null;
    }

    public static bool LooksHandledVerdict(JsonObject? data)
    {
        var token = JsonField.Str(data, "verdict", "result", "state", "acceptance_status") ?? string.Empty;
        if (string.IsNullOrWhiteSpace(token) || token.Equals("unknown", StringComparison.OrdinalIgnoreCase))
            return false;
        if (token.Contains("FAIL", StringComparison.OrdinalIgnoreCase)
            && !token.Contains("PASS", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return token.Contains("PASS", StringComparison.OrdinalIgnoreCase)
               || token.Contains("ACCEPT", StringComparison.OrdinalIgnoreCase)
               || token.Contains("ADOPT", StringComparison.OrdinalIgnoreCase)
               || token.Equals("handled", StringComparison.OrdinalIgnoreCase);
    }

    public static bool SummaryContradictsInFlight(string? summary, bool inFlight)
    {
        if (!inFlight || string.IsNullOrWhiteSpace(summary)) return false;
        if (summary.Contains("尚未派出", StringComparison.Ordinal)
            || summary.Contains("未派出", StringComparison.Ordinal))
        {
            return true;
        }

        return summary.Contains("终止", StringComparison.Ordinal)
               && summary.Contains("平台安全", StringComparison.Ordinal);
    }

    static bool IsMissing(string? value) =>
        string.IsNullOrWhiteSpace(value) || value.Equals("unknown", StringComparison.OrdinalIgnoreCase);

    static bool LooksLikePath(string value) =>
        value.Contains('\\', StringComparison.Ordinal) || value.Contains('/', StringComparison.Ordinal);

    static readonly string[] LineCiteKeys =
    {
        "line_job_id", "current_line_job_id", "business_line_job_id", "new_line_job_id", "successor_line_job_id"
    };

    static readonly string[] DirectCiteKeys =
    {
        "direct_job_id", "current_direct_job_id", "business_direct_job_id", "new_direct_job_id"
    };

    static int NestedJobCiteScore(JsonObject obj, string? lineId, string? directId)
    {
        var lineHit = !IsMissing(lineId) && FieldEqualsAny(obj, lineId, LineCiteKeys);
        var directHit = !IsMissing(directId)
                        && (FieldEqualsAny(obj, directId, DirectCiteKeys)
                            || (!lineHit && FieldEqualsAny(obj, directId, "job_id")));
        if (lineHit && !IsMissing(directId) && FieldEqualsAny(obj, directId, "job_id"))
            directHit = true;
        if (lineHit && directHit) return 2;
        if (lineHit || directHit) return 1;
        return 0;
    }

    static bool FieldEqualsAny(JsonObject obj, string? expected, params string[] keys)
    {
        if (IsMissing(expected)) return false;
        foreach (var key in keys)
        {
            var raw = JsonField.Str(obj, key);
            if (!IsMissing(raw) && string.Equals(raw, expected, StringComparison.OrdinalIgnoreCase))
                return true;
        }

        return false;
    }

    static string? NestedJobRoute(JsonObject obj)
    {
        foreach (var key in new[] { "new_route", "fallback_route", "active_route", "route" })
        {
            var route = JsonField.Str(obj, key);
            if (!IsMissing(route) && LooksLikeRouteId(route)
                && !key.StartsWith("old_", StringComparison.OrdinalIgnoreCase))
            {
                return route;
            }
        }

        return null;
    }

    static bool HasStaleSwitchPair(JsonObject obj) =>
        !IsMissing(JsonField.Str(obj, "old_route"))
        && !IsMissing(JsonField.Str(obj, "new_route"));

    static void WalkNestedObjects(JsonObject obj, bool isRoot, int depth, Action<JsonObject> consider)
    {
        if (depth > 14) return;
        if (!isRoot) consider(obj);
        foreach (var kv in obj)
        {
            if (kv.Value is JsonObject child)
                WalkNestedObjects(child, isRoot: false, depth + 1, consider);
            else if (kv.Value is JsonArray arr)
            {
                foreach (var item in arr)
                {
                    if (item is JsonObject childObj)
                        WalkNestedObjects(childObj, isRoot: false, depth + 1, consider);
                }
            }
        }
    }
}
