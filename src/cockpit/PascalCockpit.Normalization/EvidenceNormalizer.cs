using System.Text.Json.Nodes;
using PascalCockpit.Contracts;

namespace PascalCockpit.Normalization;

/// <summary>
/// Normalizes CollectionBatch RawDocuments into SourceFacts.
/// Preserves evidence; keeps process/turn/execution/transport/delivery/callback/
/// lead_handling/acceptance/adoption/goal as independent string axes (unknown when absent).
/// Never invents ProjectId from directory titles; never hardcodes truth-case UUIDs.
/// </summary>
public sealed class EvidenceNormalizer : INormalizer
{
    public FactBatch Normalize(CollectionBatch batch)
    {
        ArgumentNullException.ThrowIfNull(batch);

        var facts = new List<SourceFact>();
        var issues = new List<SourceIssue>();
        foreach (var issue in batch.Issues ?? Array.Empty<SourceIssue>())
        {
            issues.Add(issue);
        }

        var docs = batch.Documents ?? Array.Empty<RawDocument>();
        var knownProjects = new HashSet<string>(StringComparer.Ordinal);
        var handlingRecords = new List<HandlingRecord>();
        var processObs = new List<(RawDocument Doc, int Pid, long Ticks, string State)>();
        var routesSeenLive = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var routesSeenProtocol = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var doc in docs)
        {
            if (!RawDocumentKinds.Known.Contains(doc.Kind))
            {
                issues.Add(new SourceIssue(
                    doc.Id,
                    "unknown_kind",
                    $"RawDocument.Kind '{doc.Kind}' is not a contract kind; not deserialized as success.",
                    doc.ObservedAt));
            }
        }

        foreach (var doc in docs.Where(d => d.Kind == RawDocumentKinds.ProjectRegistry))
        {
            DocumentNormalizers.NormalizeRegistry(doc, facts, issues, knownProjects);
        }

        foreach (var doc in docs)
        {
            if (!RawDocumentKinds.Known.Contains(doc.Kind))
            {
                continue;
            }

            switch (doc.Kind)
            {
                case RawDocumentKinds.ProjectRegistry:
                    break;
                case RawDocumentKinds.ActiveWork:
                    DocumentNormalizers.NormalizeActiveWork(doc, facts, issues, knownProjects, handlingRecords, routesSeenLive, routesSeenProtocol);
                    break;
                case RawDocumentKinds.CurrentResult:
                    DocumentNormalizers.NormalizeCurrentResult(doc, facts, issues, knownProjects);
                    break;
                case RawDocumentKinds.LeadRun:
                case RawDocumentKinds.LeadOwner:
                    DocumentNormalizers.NormalizeLead(doc, facts, issues, knownProjects);
                    break;
                case RawDocumentKinds.CliChild:
                case RawDocumentKinds.CliLifecycle:
                    DocumentNormalizers.NormalizeCli(doc, facts, issues, knownProjects);
                    break;
                case RawDocumentKinds.ProcessObservation:
                    DocumentNormalizers.NormalizeProcess(doc, facts, issues, knownProjects, processObs);
                    break;
                case RawDocumentKinds.LineDispatch:
                case RawDocumentKinds.LineReceipt:
                case RawDocumentKinds.LineDelivery:
                    DocumentNormalizers.NormalizeLine(doc, facts, issues, knownProjects, routesSeenLive, routesSeenProtocol);
                    break;
                case RawDocumentKinds.WakeIntent:
                case RawDocumentKinds.WakeAttempt:
                    DocumentNormalizers.NormalizeWake(doc, facts, issues, knownProjects, handlingRecords);
                    break;
                case RawDocumentKinds.DirectRequest:
                case RawDocumentKinds.DirectReceipt:
                    DocumentNormalizers.NormalizeDirect(doc, facts, issues, knownProjects, routesSeenLive, routesSeenProtocol);
                    break;
                case RawDocumentKinds.RouteStatus:
                    DocumentNormalizers.NormalizeRouteStatus(doc, facts, issues, routesSeenProtocol, routesSeenLive);
                    break;
                case RawDocumentKinds.BotRegistry:
                    DocumentNormalizers.NormalizeBotRegistry(doc, facts, issues, knownProjects);
                    break;
                case RawDocumentKinds.BotResultPointer:
                    DocumentNormalizers.NormalizeBotContribution(doc, facts, issues, knownProjects);
                    break;
                case RawDocumentKinds.BotAcceptance:
                    // Army/contribution AR adopt is not Lead acceptance of the current execution receipt.
                    DocumentNormalizers.NormalizeBotAcceptance(doc, facts, issues, knownProjects, handlingRecords);
                    break;
                case RawDocumentKinds.GenerationStatus:
                    DocumentNormalizers.NormalizeGenerationStatus(doc, facts, issues, knownProjects);
                    break;
                default:
                    issues.Add(new SourceIssue(doc.Id, "unhandled_kind", $"Kind '{doc.Kind}' is known but has no normalizer branch.", doc.ObservedAt));
                    break;
            }

            HandlingLogic.TryExtractHandling(doc, handlingRecords);
        }

        foreach (var doc in docs.Where(d => d.Kind == RawDocumentKinds.BotAcceptance))
        {
            var pid = NormUtil.ResolveProjectId(doc, knownProjects, issues);
            if (DocumentNormalizers.IsCapacityResume(doc.Data))
            {
                DocumentNormalizers.ApplyCapacityResume(facts, doc, pid);
                continue;
            }

            var line = JsonField.Str(doc.Data, "line_job_id", "current_line_job_id", "preserved_execution_line")
                       ?? DocumentNormalizers.LineIdFromReceiptPath(
                           JobIdentity.NestedReceiptPath(doc.Data, "line_receipt", "telephone_receipt"));
            var direct = JsonField.Str(doc.Data, "direct_job_id", "current_direct_job_id")
                         ?? DocumentNormalizers.LineIdFromReceiptPath(
                             JobIdentity.NestedReceiptPath(doc.Data, "route_receipt", "direct_receipt"));
            if (string.IsNullOrWhiteSpace(line) && string.IsNullOrWhiteSpace(direct))
                continue;
            DocumentNormalizers.AttachOrdinaryLeadAcceptance(
                facts, doc, pid, line, direct,
                JsonField.Str(doc.Data, "result", "state", "verdict"));
        }

        ApplyExplicitBindingPairs(facts, docs);
        HandlingLogic.ApplyHandlingAndConflicts(facts, issues, handlingRecords, processObs, batch.CollectedAt);
        ReconcileJobScopedIdentity(facts);
        MarkPendingAcceptanceWhereTransportOnly(facts);

        EmitAssociationAttentions(facts, handlingRecords);
        EmitRouteCoverage(facts, docs, routesSeenProtocol, routesSeenLive, batch.CollectedAt);

        return new FactBatch(batch.CollectedAt, facts, issues);
    }

    private static void MarkPendingAcceptanceWhereTransportOnly(List<SourceFact> facts)
    {
        for (var i = 0; i < facts.Count; i++)
        {
            var f = facts[i];
            if (f.Kind != "work") continue;
            var transport = f.Values["transport_state"]?.GetValue<string>();
            var acceptance = f.Values["acceptance_state"]?.GetValue<string>();
            var handling = f.Values["lead_handling_state"]?.GetValue<string>();
            var role = f.Values["role"]?.GetValue<string>();
            if (role is not null && (role.Contains("contrib", StringComparison.OrdinalIgnoreCase)
                || role.Contains("acceptance", StringComparison.OrdinalIgnoreCase)
                || role.Contains("army", StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            if (string.Equals(f.Values["historical"]?.GetValue<string>(), "true", StringComparison.OrdinalIgnoreCase))
                continue;
            var leadH = handling ?? string.Empty;
            if (leadH.Contains("consumed_old_terminal", StringComparison.OrdinalIgnoreCase)
                && !leadH.Contains("successor", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (leadH.Contains("lead_handled", StringComparison.OrdinalIgnoreCase)
                || leadH.Contains("fail_repair", StringComparison.OrdinalIgnoreCase)
                || leadH.Contains("quota", StringComparison.OrdinalIgnoreCase)
                || (acceptance is not null && (acceptance.StartsWith("handled", StringComparison.OrdinalIgnoreCase)
                    || acceptance.Equals("content_not_accepted", StringComparison.OrdinalIgnoreCase))))
            {
                continue;
            }

            if (!string.Equals(transport, "complete", StringComparison.Ordinal)) continue;
            if (!(string.IsNullOrWhiteSpace(acceptance) || acceptance == "unknown" || acceptance == "pending")) continue;

            var values = NormUtil.CloneValues(f.Values);
            values["acceptance_state"] = "pending";
            values["lead_handling_state"] = "awaiting_lead_acceptance";

            if (values["goal_state"]?.GetValue<string>() is null or "unknown")
            {
                values["goal_state"] = "unknown";
            }

            facts[i] = new SourceFact(f.Kind, f.EntityId, f.ProjectId, f.Links, values, f.Evidence);
        }
    }

    private static void ApplyExplicitBindingPairs(List<SourceFact> facts, IReadOnlyList<RawDocument> docs)
    {
        var pairs = new List<(string Line, string Direct)>();
        void Add(string? line, string? direct)
        {
            if (string.IsNullOrWhiteSpace(line) || string.IsNullOrWhiteSpace(direct)) return;
            if (pairs.Any(p => p.Line == line && p.Direct == direct)) return;
            pairs.Add((line, direct));
        }

        foreach (var f in facts)
        {
            f.Links.TryGetValue("line_job_id", out var line);
            f.Links.TryGetValue("direct_job_id", out var direct);
            Add(line, direct);
        }

        foreach (var doc in docs.Where(d => d.Kind == RawDocumentKinds.ActiveWork || d.Kind == RawDocumentKinds.BotAcceptance))
        {
            Add(JsonField.Str(doc.Data, "line_job_id", "current_line_job_id"),
                JsonField.Str(doc.Data, "direct_job_id", "current_direct_job_id"));
            Add(JsonField.Str(doc.Data, "last_failed_line_job_id"),
                JsonField.Str(doc.Data, "last_failed_direct_job_id"));
        }

        foreach (var pair in pairs)
        {
            for (var i = 0; i < facts.Count; i++)
            {
                var f = facts[i];
                if (f.Kind != "work") continue;
                var matchLine = f.Links.TryGetValue("line_job_id", out var l) && l == pair.Line
                                || f.EntityId.Contains(pair.Line, StringComparison.Ordinal);
                var matchDirect = f.Links.TryGetValue("direct_job_id", out var d) && d == pair.Direct
                                  || f.EntityId.Contains(pair.Direct, StringComparison.Ordinal);
                if (!matchLine && !matchDirect) continue;
                var links = new Dictionary<string, string>(f.Links, StringComparer.Ordinal);
                if (!links.ContainsKey("line_job_id"))
                    NormUtil.PutLink(links, "line_job_id", pair.Line);
                if (!links.ContainsKey("direct_job_id"))
                    NormUtil.PutLink(links, "direct_job_id", pair.Direct);
                facts[i] = new SourceFact(f.Kind, f.EntityId, f.ProjectId, links, f.Values, f.Evidence);
            }
        }
    }

    /// <summary>
    /// Same job: dispatch/request/owner beat ACTIVE_WORK/registry templates.
    /// Model text never becomes a grok-cli route.
    /// </summary>
    private static void ReconcileJobScopedIdentity(List<SourceFact> facts)
    {
        var processed = new HashSet<int>();
        for (var start = 0; start < facts.Count; start++)
        {
            if (facts[start].Kind != "work" || !processed.Add(start))
                continue;

            var cluster = new List<int> { start };
            var grow = true;
            while (grow)
            {
                grow = false;
                for (var j = 0; j < facts.Count; j++)
                {
                    if (facts[j].Kind != "work" || cluster.Contains(j)) continue;
                    if (!cluster.Any(i => SameJobIdentity(facts[i], facts[j]))) continue;
                    cluster.Add(j);
                    processed.Add(j);
                    grow = true;
                }
            }

            string? bestRoute = null;
            string? bestModel = null;
            string? bestEffort = null;
            var bestRouteRank = -1;
            var bestModelRank = -1;
            var bestEffortRank = -1;
            foreach (var i in cluster)
            {
                var f = facts[i];
                var rank = JobIdentity.EvidenceRank(f);
                var route = f.Values["route"]?.GetValue<string>();
                var model = f.Values["model"]?.GetValue<string>();
                var inferred = JobIdentity.RouteFromModel(model);
                if (!IsMissingIdentityValue(route) && rank >= bestRouteRank)
                {
                    bestRoute = route;
                    bestRouteRank = rank;
                }
                else if (!string.IsNullOrWhiteSpace(inferred) && rank >= bestRouteRank)
                {
                    bestRoute = inferred;
                    bestRouteRank = rank;
                }
            }

            foreach (var i in cluster)
            {
                var f = facts[i];
                var rank = JobIdentity.EvidenceRank(f);
                var model = f.Values["model"]?.GetValue<string>();
                var effort = f.Values["effort"]?.GetValue<string>();
                if (!IsMissingIdentityValue(model)
                    && JobIdentity.ModelFitsRoute(bestRoute, model)
                    && rank >= bestModelRank)
                {
                    bestModel = model;
                    bestModelRank = rank;
                }

                if (!IsMissingIdentityValue(effort) && rank >= bestEffortRank)
                {
                    bestEffort = effort;
                    bestEffortRank = rank;
                }
            }

            if (bestRoute is null && !string.IsNullOrWhiteSpace(bestModel))
                bestRoute = JobIdentity.RouteFromModel(bestModel);

            foreach (var i in cluster)
            {
                var f = facts[i];
                var rank = JobIdentity.EvidenceRank(f);
                var values = NormUtil.CloneValues(f.Values);
                var changed = false;
                if (!IsMissingIdentityValue(bestRoute)
                    && (rank < bestRouteRank || IsMissingIdentityValue(values["route"]?.GetValue<string>())))
                {
                    values["route"] = bestRoute;
                    changed = true;
                }

                var currentModel = values["model"]?.GetValue<string>();
                if (!IsMissingIdentityValue(bestModel)
                    && (rank < bestModelRank || IsMissingIdentityValue(currentModel) || !JobIdentity.ModelFitsRoute(bestRoute, currentModel)))
                {
                    values["model"] = bestModel;
                    changed = true;
                }
                else if (!IsMissingIdentityValue(currentModel)
                         && !JobIdentity.ModelFitsRoute(values["route"]?.GetValue<string>() ?? bestRoute, currentModel))
                {
                    values.Remove("model");
                    changed = true;
                }

                if (!IsMissingIdentityValue(bestEffort)
                    && (rank < bestEffortRank || IsMissingIdentityValue(values["effort"]?.GetValue<string>())))
                {
                    values["effort"] = bestEffort;
                    changed = true;
                }

                var actor = values["actor_name"]?.GetValue<string>();
                var routeNow = values["route"]?.GetValue<string>() ?? bestRoute;
                if (!IsMissingIdentityValue(routeNow)
                    && (IsMissingIdentityValue(actor) || JobIdentity.LooksLikeRouteId(actor))
                    && !string.Equals(actor, routeNow, StringComparison.Ordinal))
                {
                    values["actor_name"] = routeNow;
                    changed = true;
                }

                if (changed)
                    facts[i] = new SourceFact(f.Kind, f.EntityId, f.ProjectId, f.Links, values, f.Evidence);
            }
        }
    }

    private static bool SameJobIdentity(SourceFact a, SourceFact b)
    {
        if (!string.Equals(a.ProjectId, b.ProjectId, StringComparison.Ordinal))
            return false;
        a.Links.TryGetValue("line_job_id", out var al);
        b.Links.TryGetValue("line_job_id", out var bl);
        if (!string.IsNullOrWhiteSpace(al) && string.Equals(al, bl, StringComparison.OrdinalIgnoreCase))
            return true;
        a.Links.TryGetValue("direct_job_id", out var ad);
        b.Links.TryGetValue("direct_job_id", out var bd);
        return !string.IsNullOrWhiteSpace(ad) && string.Equals(ad, bd, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsMissingIdentityValue(string? value) =>
        string.IsNullOrWhiteSpace(value) || value.Equals("unknown", StringComparison.OrdinalIgnoreCase);

    private static void EmitAssociationAttentions(List<SourceFact> facts, List<HandlingRecord> handlingRecords)
    {
        foreach (var f in facts.Where(x => x.Kind == "work" && x.ProjectId is null).ToList())
        {
            facts.Add(new SourceFact(
                "attention",
                "attention:unassigned:" + f.EntityId,
                null,
                new Dictionary<string, string>(f.Links) { ["parent_work_id"] = f.EntityId },
                new JsonObject
                {
                    ["attention_owner"] = "Secretary",
                    ["attention_reason"] = "missing_reliable_project_association",
                    ["summary"] = "Work lacks reliable project link; left unassigned (no directory-title invent).",
                    ["lead_handling_state"] = JsonField.AxisOrUnknown(f.Values["lead_handling_state"]?.GetValue<string>())
                },
                f.Evidence));
        }

        var handledLines = new HashSet<string>(
            handlingRecords.Where(h => !string.IsNullOrWhiteSpace(h.OldLineJobId)).Select(h => h.OldLineJobId!),
            StringComparer.Ordinal);
        var handledDirects = new HashSet<string>(
            handlingRecords.Where(h => !string.IsNullOrWhiteSpace(h.OldDirectJobId)).Select(h => h.OldDirectJobId!),
            StringComparer.Ordinal);

        foreach (var f in facts.Where(x => x.Kind == "work").ToList())
        {
            var exec = f.Values["execution_state"]?.GetValue<string>();
            var handling = f.Values["lead_handling_state"]?.GetValue<string>();
            if (!string.Equals(exec, "failed", StringComparison.Ordinal)) continue;

            f.Links.TryGetValue("line_job_id", out var line);
            f.Links.TryGetValue("direct_job_id", out var direct);
            var acceptance = f.Values["acceptance_state"]?.GetValue<string>();
            var covered = (!string.IsNullOrWhiteSpace(line) && handledLines.Contains(line))
                          || (!string.IsNullOrWhiteSpace(direct) && handledDirects.Contains(direct))
                          || (handling is not null && handling.StartsWith("consumed", StringComparison.Ordinal))
                          || HandlingLogic.IsCompleteLeadHandled(handling, acceptance)
                          || PackageHasCompleteLeadHandling(facts, f);
            if (covered) continue;

            facts.Add(new SourceFact(
                "attention",
                "attention:handling_unknown:" + f.EntityId,
                f.ProjectId,
                new Dictionary<string, string>(f.Links) { ["parent_work_id"] = f.EntityId },
                new JsonObject
                {
                    ["attention_owner"] = "Lead",
                    ["attention_reason"] = "lead_handling_association_unknown",
                    ["summary"] = "Failure retained; Lead handling/successor evidence absent — not silently dropped.",
                    ["lead_handling_state"] = "unknown",
                    ["execution_state"] = "failed"
                },
                f.Evidence));
        }
    }

    private static void EmitRouteCoverage(
        List<SourceFact> facts,
        IReadOnlyList<RawDocument> docs,
        HashSet<string> routesSeenProtocol,
        HashSet<string> routesSeenLive,
        DateTimeOffset collectedAt)
    {
        var existing = new HashSet<string>(
            facts.Where(f => f.Kind == "route_coverage").Select(f => f.EntityId),
            StringComparer.Ordinal);

        var catalogPresent = docs.Any(d =>
            d.Kind == RawDocumentKinds.RouteStatus
            || (d.Data["protocol"]?.GetValue<string>()?.Contains("route-catalog", StringComparison.OrdinalIgnoreCase) ?? false));

        foreach (var route in RouteCatalog.EightRoutes)
        {
            var entityId = "route:" + route;
            if (existing.Contains(entityId)) continue;

            string level;
            string gap;
            if (routesSeenLive.Contains(route))
            {
                level = "live_sample_present";
                gap = "windows_live_identity_not_claimed_here";
            }
            else if (routesSeenProtocol.Contains(route))
            {
                level = "protocol_sample_present";
                gap = "no_live_verification_in_this_batch";
            }
            else if (catalogPresent)
            {
                level = "catalog_declared_only";
                gap = "catalog_claim_is_not_live_verification";
            }
            else
            {
                level = "unverified";
                gap = "no_protocol_sample_or_live_evidence_in_batch";
            }

            facts.Add(new SourceFact(
                "route_coverage",
                entityId,
                null,
                new Dictionary<string, string> { ["source_object_id"] = "route_catalog:" + route },
                new JsonObject
                {
                    ["route"] = route,
                    ["coverage_level"] = level,
                    ["coverage_gap"] = gap,
                    ["summary"] = route + ":" + level
                },
                new[]
                {
                    new EvidenceRef(
                        "route_catalog",
                        "RouteCatalog.EightRoutes",
                        "route_coverage",
                        collectedAt,
                        collectedAt,
                        DataQuality.Fresh,
                        "Frozen eight-route denominator; level from batch evidence only.")
                }));
        }
    }

    private static bool PackageHasCompleteLeadHandling(List<SourceFact> facts, SourceFact f)
    {
        var mine = PackageIds(f);
        if (mine.Count == 0) return false;
        foreach (var other in facts)
        {
            if (other.Kind != "work") continue;
            if (!string.Equals(other.ProjectId, f.ProjectId, StringComparison.Ordinal)) continue;
            var oh = other.Values["lead_handling_state"]?.GetValue<string>();
            var oa = other.Values["acceptance_state"]?.GetValue<string>();
            if (!HandlingLogic.IsCompleteLeadHandled(oh, oa)
                && !(oh ?? string.Empty).Contains("quota", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(oa, "content_not_accepted", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (PackageIds(other).Overlaps(mine)) return true;
        }

        return false;
    }

    private static HashSet<string> PackageIds(SourceFact f)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        if (f.Links.TryGetValue("line_job_id", out var line) && !string.IsNullOrWhiteSpace(line))
            ids.Add(line);
        if (f.Links.TryGetValue("direct_job_id", out var direct) && !string.IsNullOrWhiteSpace(direct))
            ids.Add(direct);
        var e = f.EntityId ?? string.Empty;
        const string linePrefix = "work:line:";
        const string directPrefix = "work:direct:";
        if (e.StartsWith(linePrefix, StringComparison.Ordinal))
            ids.Add(e[linePrefix.Length..]);
        else if (e.StartsWith(directPrefix, StringComparison.Ordinal))
            ids.Add(e[directPrefix.Length..]);
        return ids;
    }
}
