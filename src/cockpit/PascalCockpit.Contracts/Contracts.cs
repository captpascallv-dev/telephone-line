using System.Text.Json.Nodes;
namespace PascalCockpit.Contracts;
public enum DataQuality { Fresh, LastKnown, Unavailable, Conflicting }
public enum AttentionOwner { None, Lead, Secretary, Pascal }
public sealed record SourceIssue(string SourceId, string Code, string Detail, DateTimeOffset ObservedAt);
public sealed record EvidenceRef(string SourceId, string Location, string Kind, DateTimeOffset ObservedAt, DateTimeOffset? FactAt, DataQuality Quality, string? Reason = null);
public sealed record RawDocument(string Id, string Kind, string Location, JsonObject Data, DateTimeOffset ObservedAt, DateTimeOffset? FactAt = null, string? ProjectHint = null, string? Scope = null);
public sealed record CollectionBatch(DateTimeOffset CollectedAt, IReadOnlyList<RawDocument> Documents, IReadOnlyList<SourceIssue> Issues);
public sealed record CollectorSettings(IReadOnlyList<string> RegistryPaths, IReadOnlyList<string> AdditionalSourcePaths, int MaxFileBytes = 1048576, int MaxFilesPerRefresh = 512);
public sealed record ProcessIdentityObservation(int Pid, long ExpectedStartTicks, string State, DateTimeOffset ObservedAt);
public interface IProcessProbe { ValueTask<ProcessIdentityObservation> ObserveAsync(int pid, long expectedStartTicks, CancellationToken cancellationToken); }
public interface ICollector { Task<CollectionBatch> CollectAsync(CollectorSettings settings, CancellationToken cancellationToken); }
public sealed record SourceFact(string Kind, string EntityId, string? ProjectId, IReadOnlyDictionary<string,string> Links, JsonObject Values, IReadOnlyList<EvidenceRef> Evidence);
public sealed record FactBatch(DateTimeOffset CollectedAt, IReadOnlyList<SourceFact> Facts, IReadOnlyList<SourceIssue> Issues);
public interface INormalizer { FactBatch Normalize(CollectionBatch batch); }
public sealed record WorkAxes(string Process, string Turn, string Execution, string Transport, string Delivery, string Callback, string LeadHandling, string Acceptance, string Adoption, string Goal);
public sealed record NavigationTarget(string Kind, string Target, string Label, string ProjectId, string? EntityId = null);
public sealed record ArtifactView(string Id, string Label, string State, NavigationTarget? Target, IReadOnlyList<EvidenceRef> Evidence);
public sealed record ProgressView(int Completed, int Total, string Basis, IReadOnlyList<EvidenceRef> Evidence);
public sealed record AttentionItem(string Id, AttentionOwner Owner, string Description, string Reason, IReadOnlyList<NavigationTarget> Targets, IReadOnlyList<EvidenceRef> Evidence);
public sealed record WorkView(string Id, string Role, string? Route, string Summary, WorkAxes Axes, IReadOnlyList<ArtifactView> Artifacts, IReadOnlyList<NavigationTarget> Targets, IReadOnlyList<EvidenceRef> Evidence, DataQuality Quality);
public sealed record ProjectView(string Id, string Name, string Summary, string Phase, string? Goal, string? NextStep, bool IsActive, bool IsPaused, ProgressView? Progress, IReadOnlyList<WorkView> WorkItems, IReadOnlyList<AttentionItem> Attention, IReadOnlyList<NavigationTarget> Targets, DataQuality Quality, DateTimeOffset? LastFactAt);
public sealed record RouteCoverage(string RouteId, string Level, string? Gap, IReadOnlyList<EvidenceRef> Evidence);
public sealed record CockpitSnapshot(DateTimeOffset CollectedAt, IReadOnlyList<ProjectView> Projects, IReadOnlyList<SourceIssue> Issues, IReadOnlyList<RouteCoverage> Routes, DataQuality Quality);
public interface IProjector { CockpitSnapshot Project(FactBatch batch, CockpitSnapshot? previous = null); }
public sealed class NavigationRequestEventArgs : EventArgs {
    public NavigationTarget Target { get; }
    public NavigationRequestEventArgs(NavigationTarget target) { Target = target; }
}
