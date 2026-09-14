using PascalCockpit.Contracts;

namespace PascalCockpit.Views;

public sealed record DetailsAttentionRow(string Id, AttentionOwner Owner, string OwnerLabel, string Text, IReadOnlyList<NavigationTarget> Targets);

public sealed record DetailsArtifactRow(string Id, string Label, string State, NavigationTarget? Target);

public sealed record DetailsWorkRow(
    string Id,
    string RoleKind,
    string RoleLabel,
    string ActorName,
    string TaskText,
    string ModelText,
    string EffortText,
    string StatusText,
    string BlockerText,
    string? Route,
    string Summary,
    string AxesPhrase,
    string QualityLabel,
    bool IsHistorical,
    IReadOnlyList<DetailsArtifactRow> Artifacts,
    IReadOnlyList<NavigationTarget> Targets)
{
    public string AutomationName =>
        string.Join(" · ", new[] { RoleLabel, ActorName, StatusText, ModelText, EffortText }
            .Where(s => !string.IsNullOrWhiteSpace(s)));

    public override string ToString() => AutomationName;
}

public sealed record DetailsNavButton(string Label, NavigationTarget Target);

public sealed record DetailsModel(
    string? SelectedProjectId,
    string? EmptyMessage,
    string Name,
    string OverallJudgment,
    string OverallBasis,
    string Goal,
    string Phase,
    string NextStep,
    string Summary,
    string? ProgressText,
    string ProjectQualityText,
    string? LastFactAtText,
    IReadOnlyList<DetailsWorkRow> CurrentWorks,
    IReadOnlyList<DetailsWorkRow> HistoricalWorks,
    IReadOnlyList<DetailsAttentionRow> PascalAttentions,
    IReadOnlyList<DetailsAttentionRow> LeadAttentions,
    IReadOnlyList<DetailsAttentionRow> SecretaryAttentions,
    IReadOnlyList<DetailsArtifactRow> Artifacts,
    IReadOnlyList<DetailsNavButton> NavigationButtons,
    string WhoDoingWhat,
    string HowFar,
    string StuckAt,
    string NextOwner,
    string NeedsPascal,
    string FreshnessHint,
    string DiagnosticsText,
    string? UnassignedReviewText);

public static class DetailsPresentation
{
    public static DetailsModel Build(CockpitSnapshot? snapshot, string? selectedProjectId, UiLang lang = UiLang.Zh)
    {
        if (snapshot is null)
        {
            return Empty("暂无快照。", lang);
        }

        if (snapshot.Projects.Count == 0)
        {
            return Empty("本轮快照没有项目。", lang);
        }

        var project = snapshot.Projects.FirstOrDefault(p =>
            !string.IsNullOrWhiteSpace(selectedProjectId) && p.Id == selectedProjectId);
        if (project is null)
        {
            var id = CurrentList.ResolveSelection(snapshot, selectedProjectId, showHistory: false);
            project = snapshot.Projects.FirstOrDefault(p => p.Id == id);
        }
        if (project is null)
        {
            return Empty("选中项目已不在当前快照中。", lang);
        }

        var current = RolePresentation.CurrentRows(project, lang);
        var historical = RolePresentation.HistoricalRows(project, lang);

        var pascal = project.Attention.Where(a => a.Owner == AttentionOwner.Pascal).Select(a => ToAtt(a, lang)).ToList();
        var lead = project.Attention.Where(a => a.Owner == AttentionOwner.Lead).Select(a => ToAtt(a, lang)).ToList();
        var secretary = project.Attention.Where(a => a.Owner == AttentionOwner.Secretary).Select(a => ToAtt(a, lang)).ToList();

        var artifacts = current.SelectMany(w => w.Artifacts)
            .Concat(historical.SelectMany(w => w.Artifacts))
            .GroupBy(a => a.Id)
            .Select(g => g.First())
            .ToList();

        var nav = CollectNavigation(project, snapshot)
            .Select(t => new DetailsNavButton(string.IsNullOrWhiteSpace(t.Label) ? t.Target : t.Label, t))
            .GroupBy(b => b.Target.Kind + "|" + b.Target.Target)
            .Select(g => g.First())
            .ToList();

        var progress = StatusLanguage.ProgressText(project.Progress);
        if (string.IsNullOrWhiteSpace(progress)) progress = null;
        else progress = ConsumerCopy.Localize(progress, lang);

        string? lastFact = null;
        if (project.LastFactAt is { } fa)
            lastFact = StatusLanguage.CollectedAtText(fa);

        var situation = Situation(project, lang);
        var overall = StatusLanguage.OverallJudgment(project, lang);
        return new DetailsModel(
            project.Id,
            null,
            HudPresentation.DisplayName(project),
            overall.Label,
            overall.Basis,
            situation.Goal,
            situation.Phase,
            situation.Next,
            situation.Summary,
            progress,
            StatusLanguage.DataQualityShort(project.Quality, lang),
            lastFact,
            current,
            historical,
            pascal,
            lead,
            secretary,
            artifacts,
            nav,
            situation.Who,
            situation.HowFar,
            situation.Stuck,
            situation.Next,
            situation.Pascal,
            project.Quality == DataQuality.LastKnown ? ConsumerCopy.Localize("沿用上次已知，不是这一轮刚采到的。", lang) : string.Empty,
            BuildDiagnostics(project, snapshot, lang),
            RolePresentation.HasExplicitNoReviewer(project)
                ? ConsumerCopy.T(lang, "review_not_assigned")
                : null);
    }

    /// <summary>
    /// Only allow navigation targets that already appear on the snapshot for the selected project / its works.
    /// </summary>
    public static bool IsAllowedNavigation(CockpitSnapshot snapshot, string? projectId, NavigationTarget target)
    {
        if (string.IsNullOrWhiteSpace(projectId)) return false;
        var project = snapshot.Projects.FirstOrDefault(p => p.Id == projectId);
        if (project is null) return false;
        return CollectNavigation(project, snapshot).Any(t =>
            t.Kind == target.Kind
            && t.Target == target.Target
            && t.ProjectId == target.ProjectId
            && t.EntityId == target.EntityId);
    }

    public static IReadOnlyList<NavigationTarget> CollectNavigation(ProjectView project, CockpitSnapshot snapshot)
    {
        var list = new List<NavigationTarget>();
        void AddRange(IEnumerable<NavigationTarget> targets)
        {
            foreach (var t in targets)
            {
                if (t.ProjectId != project.Id) continue;
                list.Add(t);
            }
        }

        AddRange(project.Targets);
        foreach (var a in project.Attention) AddRange(a.Targets);
        foreach (var w in project.WorkItems)
        {
            AddRange(w.Targets);
            foreach (var art in w.Artifacts)
            {
                if (art.Target is { } at) list.Add(at);
            }
        }

        // Snapshot routes do not carry navigation; ignore foreign projects
        _ = snapshot;
        return list;
    }

    private static DetailsModel Empty(string zhMessage, UiLang lang) => new(
        null,
        ConsumerCopy.Localize(zhMessage, lang),
        string.Empty,
        ConsumerCopy.Localize("状态待核实", lang),
        ConsumerCopy.Localize("缺少足够来源", lang),
        ConsumerCopy.Localize("未声明", lang),
        ConsumerCopy.Localize("未声明", lang),
        ConsumerCopy.Localize("未声明", lang),
        string.Empty,
        null,
        string.Empty,
        null,
        Array.Empty<DetailsWorkRow>(),
        Array.Empty<DetailsWorkRow>(),
        Array.Empty<DetailsAttentionRow>(),
        Array.Empty<DetailsAttentionRow>(),
        Array.Empty<DetailsAttentionRow>(),
        Array.Empty<DetailsArtifactRow>(),
        Array.Empty<DetailsNavButton>(),
        string.Empty,
        string.Empty,
        string.Empty,
        string.Empty,
        string.Empty,
        string.Empty,
        string.Empty,
        null);

    private static (string Who, string HowFar, string Stuck, string Next, string Pascal, string Phase, string Goal, string Summary) Situation(ProjectView project, UiLang lang)
    {
        var life = VisibleLifecycle.Describe(project);
        var current = project.WorkItems.Where(w => !StatusLanguage.IsHistoricalWork(w) && !StatusLanguage.IsDiagnosticNoise(w)).ToList();
        var unhandled = StatusLanguage.UnhandledCurrentFailures(current);
        if (life.Kind is "visual_pending" or "correction_prepared" or "lead_accepting" or "user_action")
        {
            var phaseLife = LooksRaw(project.Phase) ? life.HudLine : project.Phase;
            var goalLife = LooksRaw(project.Goal) ? "未用一句话写明目标" : StatusLanguage.OrUndeclared(project.Goal);
            var summaryLife = LooksRaw(project.Summary) ? life.HudLine : StateProjectorStrip(project.Summary);
            if (unhandled.Count > 0)
            {
                const string failPhrase = "当前执行失败，待处理";
                var extra = StatusLanguage.SecondaryLiveFact(current, life);
                var whoZh = "原负责人。" + failPhrase;
                if (!string.IsNullOrWhiteSpace(extra) && !whoZh.Contains(extra, StringComparison.Ordinal))
                    whoZh = whoZh + "；" + extra;
                var overlayStuck = RolePresentation.FailedItemsStuck(current, lang);
                var overlayNext = life.Kind == "lead_accepting"
                    ? "原负责人处理当前失败，并验收另一份回件"
                    : "原负责人处理当前失败";
                return (
                    ConsumerCopy.Localize(whoZh, lang),
                    ConsumerCopy.Localize(life.HowFar, lang),
                    string.IsNullOrWhiteSpace(overlayStuck) ? ConsumerCopy.Localize(failPhrase, lang) : overlayStuck,
                    ConsumerCopy.Localize(overlayNext, lang),
                    ConsumerCopy.Localize(life.Pascal, lang),
                    ConsumerCopy.Localize(phaseLife, lang),
                    ConsumerCopy.Localize(goalLife, lang),
                    ConsumerCopy.Localize(summaryLife, lang));
            }

            return (
                ConsumerCopy.Localize(life.Who, lang),
                ConsumerCopy.Localize(life.HowFar, lang),
                ConsumerCopy.Localize(life.Stuck, lang),
                ConsumerCopy.Localize(life.Next, lang),
                ConsumerCopy.Localize(life.Pascal, lang),
                ConsumerCopy.Localize(phaseLife, lang),
                ConsumerCopy.Localize(goalLife, lang),
                ConsumerCopy.Localize(summaryLife, lang));
        }

        var lineZh = StatusLanguage.ProjectOneLinerFull(project, UiLang.Zh);
        var blocked = current.Any(w => (w.Axes.LeadHandling ?? "").Equals("blocked_after_acceptance", StringComparison.OrdinalIgnoreCase));
        var accepting = current.Any(w =>
            (w.Axes.LeadHandling ?? "").Equals("lead_accepting", StringComparison.OrdinalIgnoreCase)
            || (w.Axes.Acceptance ?? "").Equals("acceptance_in_progress", StringComparison.OrdinalIgnoreCase));
        var repairOut = current.Any(w => (w.Axes.LeadHandling ?? "").Equals("repair_dispatched", StringComparison.OrdinalIgnoreCase));
        var repairPrepared = current.Any(w =>
            (w.Axes.LeadHandling ?? "").Equals("repair_prepared", StringComparison.OrdinalIgnoreCase)
            && !w.Axes.Execution.Equals("active", StringComparison.OrdinalIgnoreCase)
            && !w.Axes.Execution.Equals("running", StringComparison.OrdinalIgnoreCase));
        var failRepair = current.Any(StatusLanguage.IsOpenFailRepair);
        var inFlight = current.Any(w =>
            !StatusLanguage.HasLiveHandler(w)
            && (w.Axes.Execution.Equals("active", StringComparison.OrdinalIgnoreCase)
                || w.Axes.Execution.Equals("running", StringComparison.OrdinalIgnoreCase)));
        var failed = current.Any(w =>
            !StatusLanguage.HasLiveHandler(w)
            && w.Axes.Execution.Equals("failed", StringComparison.OrdinalIgnoreCase));
        var failedStuck = RolePresentation.FailedItemsStuck(current, lang);
        var ownerContinuing = !string.IsNullOrWhiteSpace(StatusLanguage.OwnerContinuingText(project));
        var pascal = project.Attention.Any(a => a.Owner == AttentionOwner.Pascal);
        var who = blocked || accepting || repairPrepared || failRepair
            ? "原负责人"
            : inFlight || repairOut ? "原执行者"
            : ownerContinuing ? "原负责人"
            : "当前负责人按最新回执处理";
        var comparisonOpen = current.Any(w =>
            (w.Axes.Goal ?? "").Equals("not_complete", StringComparison.OrdinalIgnoreCase));
        var execs = current.Where(w =>
            string.Equals(w.ActorKind, "executor", StringComparison.OrdinalIgnoreCase)
            || (w.Role ?? "").Contains("exec", StringComparison.OrdinalIgnoreCase)).ToList();
        var allExecAccepted = execs.Count > 0 && execs.All(w =>
            (w.Axes.Acceptance ?? "").Equals("handled_accepted", StringComparison.OrdinalIgnoreCase)
            || StatusLanguage.IsExplicitAccepted(w.Axes.Acceptance));
        var howFar = StatusLanguage.ProgressText(project.Progress);
        if (string.IsNullOrWhiteSpace(howFar))
            howFar = blocked
                ? "结果已经交回，负责人已判退修"
                : accepting ? "结果已经交回，负责人正在验收"
                : comparisonOpen && allExecAccepted ? "执行已验收，整体尚未通过"
                : repairPrepared && !inFlight ? "准备退修，待实际派出"
                : failRepair && !inFlight ? "本轮未通过，原负责人已接手"
                : repairOut && !inFlight ? "退修已派出，等待本轮结果"
                : inFlight || repairOut ? "本轮还在做，还没交回"
                : ownerContinuing ? (StatusLanguage.OwnerContinuingText(project) ?? "原负责人正在继续")
                : "目前没有更细的进度数字";
        var stuckZh = blocked || lineZh.Contains("平台限制", StringComparison.Ordinal)
            ? "后续处理被平台限制中断，退修尚未派出"
            : repairPrepared && !inFlight
                ? "退修尚未实际派出"
            : failRepair
                ? "本轮未通过，故障影响仍在；原负责人已接手，不需你操作"
            : lineZh.Contains("验收发现问题", StringComparison.Ordinal)
                ? "卡在验收发现的问题上，需要原执行者退修"
            : !string.IsNullOrWhiteSpace(failedStuck)
                ? null
            : failed && !accepting
                ? "当前执行失败，待处理"
            : accepting || inFlight || repairOut || ownerContinuing || lineZh.Contains("还没交回", StringComparison.Ordinal)
                || lineZh.Contains("正在验收", StringComparison.Ordinal)
                ? "目前没有已知阻点"
            : "无法判断卡点的具体部分：缺少足够来源";
        var stuck = !string.IsNullOrWhiteSpace(failedStuck)
            ? failedStuck
            : ConsumerCopy.Localize(stuckZh ?? "当前执行失败，待处理", lang);
        var returned = !inFlight && current.Any(w =>
            w.Axes.Execution.Equals("returned", StringComparison.OrdinalIgnoreCase)
            || w.Axes.Execution.Equals("succeeded", StringComparison.OrdinalIgnoreCase)
            || w.Axes.Transport.Equals("complete", StringComparison.OrdinalIgnoreCase)
            || w.Axes.Delivery.Equals("complete", StringComparison.OrdinalIgnoreCase)
            || w.Axes.Delivery.Equals("returned", StringComparison.OrdinalIgnoreCase));
        var sourceNext = StatusLanguage.OrdinaryNextFromSource(project.NextStep, blocked, accepting, inFlight, returned);
        var nextZh = !string.IsNullOrWhiteSpace(sourceNext)
            ? sourceNext
            : (blocked || lineZh.Contains("平台限制", StringComparison.Ordinal) ? "按当前源处理平台反馈后接原负责人"
            : failed && accepting ? "原负责人处理当前失败，并验收另一份回件"
            : failed ? "原负责人处理当前失败"
            : accepting || lineZh.Contains("负责人正在验收", StringComparison.Ordinal) ? "原负责人继续验收"
            : lineZh.Contains("继续生成", StringComparison.Ordinal) ? "原执行者继续生成，完成后负责人验收"
            : repairPrepared && !inFlight ? "原负责人准备退修，待实际派出"
            : failRepair && !inFlight ? "原负责人继续核对失败并准备退修"
            : inFlight || lineZh.Contains("还没交回", StringComparison.Ordinal) ? "原执行者继续做，完成后负责人验收"
            : ownerContinuing ? (StatusLanguage.OwnerContinuingText(project) ?? "原负责人继续当前工作")
            : repairOut && !inFlight ? "等待本轮结果交回后负责人处理"
            : repairOut ? "原执行者正在按退修继续做"
            : lineZh.Contains("验收发现问题", StringComparison.Ordinal) ? "原执行者退修"
            : lineZh.Contains("待负责人验收", StringComparison.Ordinal) || lineZh.Contains("等待负责人验收", StringComparison.Ordinal) ? "负责人验收"
            : "按最新结论继续");
        var next = ConsumerCopy.Localize(nextZh, lang);
        var platformOpen = (blocked
            || (project.NextStep ?? "").Contains("平台", StringComparison.Ordinal)
            || (project.NextStep ?? "").Contains("platform", StringComparison.OrdinalIgnoreCase))
            && !pascal;
        var needPascal = pascal ? "需要你决定"
            : platformOpen ? "未明确谁发起平台反馈，不能保证无需你处理"
            : "现在不需要你处理";
        var phase = LooksRaw(project.Phase) ? lineZh : project.Phase;
        var goal = LooksRaw(project.Goal) ? "未用一句话写明目标" : StatusLanguage.OrUndeclared(project.Goal);
        var summary = LooksRaw(project.Summary)
            ? lineZh
            : StateProjectorStrip(project.Summary);
        var whoLine = StatusLanguage.CleanConsumerPhrase(who + "。" + lineZh);
        if (!StatusLanguage.IsConsumerPhrase(whoLine))
            whoLine = who + "。" + (StatusLanguage.IsConsumerPhrase(lineZh) ? lineZh : "正在处理，细节见上面几句");
        return (
            ConsumerCopy.Localize(whoLine, lang),
            ConsumerCopy.Localize(howFar, lang),
            stuck,
            next,
            ConsumerCopy.Localize(needPascal, lang),
            ConsumerCopy.Localize(phase, lang),
            ConsumerCopy.Localize(goal, lang),
            ConsumerCopy.Localize(summary, lang));
    }

    private static bool LooksRaw(string? value) =>
        string.IsNullOrWhiteSpace(value)
        || value is "unknown" or "未声明"
        || StatusLanguage.LooksLikeTechnicalDump(value)
        || (value.Contains('_', StringComparison.Ordinal) && value.Any(char.IsAscii) && !value.Any(ch => ch > 127));

    private static string StateProjectorStrip(string summary)
    {
        var s = summary;
        while (s.StartsWith("(last-known)", StringComparison.OrdinalIgnoreCase)
               || s.StartsWith("[historical]", StringComparison.OrdinalIgnoreCase))
        {
            s = s.Replace("(last-known)", "", StringComparison.OrdinalIgnoreCase)
                .Replace("[historical]", "", StringComparison.OrdinalIgnoreCase)
                .Trim();
        }

        return string.IsNullOrWhiteSpace(s) ? "未声明" : s;
    }

    private static string BuildDiagnostics(ProjectView project, CockpitSnapshot snapshot, UiLang lang)
    {
        var lines = new List<string>
        {
            ConsumerCopy.L(lang,
                "以下是原始字段，只在你主动打开时查看。",
                "Raw fields below. Open only when you want diagnostics."),
            "项目内部名：" + project.Id,
            "阶段字段：" + project.Phase,
            "质量：" + project.Quality
        };
        if (!string.IsNullOrWhiteSpace(project.NextStep))
            lines.Add("源里写的下一步原文：" + project.NextStep);
        foreach (var w in project.WorkItems.Take(8))
        {
            lines.Add("工作 " + w.Role + "：" + StatusLanguage.WorkAxesHumanPhrase(w.Axes));
        }

        var issues = StatusLanguage.IssuesSummary(snapshot.Issues, 8);
        if (!string.IsNullOrWhiteSpace(issues))
            lines.Add(issues);
        return string.Join(Environment.NewLine, lines);
    }

    private static DetailsAttentionRow ToAtt(AttentionItem a, UiLang lang) => new(
        a.Id,
        a.Owner,
        StatusLanguage.AttentionOwnerLabel(a.Owner, lang),
        ConsumerCopy.Localize(StatusLanguage.AttentionLineFull(a), lang),
        a.Targets);
}
