using PascalCockpit.Contracts;

namespace PascalCockpit.Views;

public sealed record HudAttentionLine(string Id, string Text, string FullText, IReadOnlyList<NavigationTarget> Targets);

public sealed record HudProjectRow(
    string ProjectId,
    string Name,
    string OverallLine,
    string OverallLineFull,
    string StatusLine,
    string StatusLineFull,
    bool IsSelected,
    bool IsPaused,
    bool IsActive,
    DataQuality Quality);

public sealed record HudModel(
    DateTimeOffset? CollectedAt,
    string CollectedAtText,
    string QualityText,
    DataQuality Quality,
    int PascalAttentionCount,
    IReadOnlyList<HudAttentionLine> PascalAttentions,
    IReadOnlyList<HudProjectRow> Projects,
    string? IssuesSummary,
    string? BannerMessage,
    string? SelectedProjectId,
    IReadOnlyList<HudProjectRow> HistoricalProjects,
    int CurrentCount,
    int HistoricalCount,
    int CurrentIssueCount,
    bool ShowingHistory,
    string FreshnessHint);

public static class HudPresentation
{
    public static string? ResolveSelection(CockpitSnapshot snapshot, string? previousSelectedProjectId) =>
        CurrentList.ResolveSelection(snapshot, previousSelectedProjectId, showHistory: false);

    public static string DisplayName(ProjectView project)
    {
        var name = string.IsNullOrWhiteSpace(project.Name) ? project.Id : project.Name.Trim();
        if (name.Contains("驾驶舱", StringComparison.Ordinal)
            && (project.IsActive && !project.IsPaused)
            && (project.Phase.Contains("修复", StringComparison.Ordinal)
                || project.Summary.Contains("退修", StringComparison.Ordinal)
                || project.Summary.Contains("实窗", StringComparison.Ordinal)
                || project.Id.Contains("cockpit", StringComparison.OrdinalIgnoreCase)))
        {
            return "驾驶舱状态修复";
        }

        return name;
    }

    public static HudModel Build(CockpitSnapshot? snapshot, string? previousSelectedProjectId, int statusMaxLen = StatusLanguage.DefaultHudMaxLen) =>
        Build(snapshot, previousSelectedProjectId, showHistory: false, statusMaxLen, UiLang.Zh);

    public static HudModel Build(CockpitSnapshot? snapshot, string? previousSelectedProjectId, bool showHistory, int statusMaxLen = StatusLanguage.DefaultHudMaxLen) =>
        Build(snapshot, previousSelectedProjectId, showHistory, statusMaxLen, UiLang.Zh);

    public static HudModel Build(CockpitSnapshot? snapshot, string? previousSelectedProjectId, bool showHistory, int statusMaxLen, UiLang lang)
    {
        if (snapshot is null)
        {
            return new HudModel(
                null,
                ConsumerCopy.T(lang, "wait_first"),
                ConsumerCopy.Localize("无快照", lang),
                DataQuality.Unavailable,
                0,
                Array.Empty<HudAttentionLine>(),
                Array.Empty<HudProjectRow>(),
                null,
                ConsumerCopy.Localize("暂无快照。等待采集结果。", lang),
                null,
                Array.Empty<HudProjectRow>(),
                0,
                0,
                0,
                showHistory,
                string.Empty);
        }

        var currentProjects = CurrentList.DefaultItems(snapshot);
        var historicalProjects = CurrentList.HistoricalItems(snapshot);
        var selected = CurrentList.ResolveSelection(snapshot, previousSelectedProjectId, showHistory);
        var pascalItems = currentProjects
            .SelectMany(p => p.Attention.Select(a => (Project: p, Item: a)))
            .Where(x => x.Item.Owner == AttentionOwner.Pascal)
            .Select(x => new HudAttentionLine(
                x.Item.Id,
                ConsumerCopy.Localize(StatusLanguage.AttentionLine(x.Item), lang),
                ConsumerCopy.Localize(StatusLanguage.AttentionLineFull(x.Item), lang),
                x.Item.Targets))
            .ToList();

        string? banner = null;
        if (snapshot.Quality == DataQuality.Unavailable)
            banner = ConsumerCopy.Localize("快照来源不可用：请查看来源问题，勿当作全部正常。", lang);
        else if (snapshot.Quality == DataQuality.Conflicting)
            banner = ConsumerCopy.Localize("快照存在来源冲突：请展开详情核实，勿当作全部正常。", lang);
        else if (snapshot.Quality == DataQuality.LastKnown)
            banner = ConsumerCopy.Localize("当前展示为上次已知状态，非本轮新鲜采集。", lang);
        else if (currentProjects.Count == 0)
            banner = ConsumerCopy.Localize(snapshot.Projects.Count == 0 ? "本轮快照没有项目。" : "当前没有进行中的任务。暂停和历史可按需查看。", lang);

        HudProjectRow Row(ProjectView p)
        {
            var overall = StatusLanguage.OverallJudgment(p, lang);
            return new(
                p.Id,
                DisplayName(p),
                overall.Label,
                overall.Label + " · " + overall.Basis,
                StatusLanguage.ProjectOneLiner(p, statusMaxLen, lang),
                StatusLanguage.ProjectOneLinerFull(p, lang),
                selected is not null && p.Id == selected,
                p.IsPaused,
                p.IsActive,
                p.Quality);
        }

        var visible = showHistory
            ? currentProjects.Concat(historicalProjects).Select(Row).ToList()
            : currentProjects.Select(Row).ToList();
        var historicalRows = historicalProjects.Select(Row).ToList();
        var issues = StatusLanguage.IssuesSummary(snapshot.Issues, snapshot, 3, lang);
        if (string.IsNullOrWhiteSpace(issues)) issues = null;
        var freshness = snapshot.Quality == DataQuality.LastKnown
            ? ConsumerCopy.Localize("沿用上次已知，不是这一轮刚采到的。", lang)
            : string.Empty;

        return new HudModel(
            snapshot.CollectedAt,
            StatusLanguage.CollectedAtText(snapshot.CollectedAt),
            StatusLanguage.SnapshotQualityText(snapshot.Quality, lang)
                + ConsumerCopy.L(lang,
                    "  当前 " + currentProjects.Count
                    + "  历史与暂停（" + historicalProjects.Count + "）",
                    "  current " + currentProjects.Count
                    + "  history and paused (" + historicalProjects.Count + ")"),
            snapshot.Quality,
            pascalItems.Count,
            pascalItems,
            visible,
            issues,
            banner,
            selected,
            historicalRows,
            currentProjects.Count,
            historicalProjects.Count,
            StatusLanguage.CurrentIssueCount(snapshot.Issues, snapshot),
            showHistory,
            freshness);
    }
}
