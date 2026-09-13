using System.Windows;
using System.Windows.Controls;
using PascalCockpit.Contracts;

namespace PascalCockpit.Views;

public partial class DetailsView : UserControl
{
    private CockpitSnapshot? _snapshot;
    private string? _selectedProjectId;
    private bool _showDiagnostics;
    private UiLang _lang = UiLang.Zh;

    public DetailsView()
    {
        InitializeComponent();
    }

    public event EventHandler<NavigationRequestEventArgs>? NavigationRequested;

    public string? SelectedProjectId => _selectedProjectId;

    public DetailsModel? CurrentModel { get; private set; }

    public UiLang UiLanguage => _lang;

    public void SetLanguage(UiLang lang)
    {
        _lang = lang;
        this.Language = System.Windows.Markup.XmlLanguage.GetLanguage(lang == UiLang.En ? "en-US" : "zh-CN");
        if (_snapshot is null)
        {
            ApplyChrome();
            return;
        }

        var model = DetailsPresentation.Build(_snapshot, _selectedProjectId, _lang);
        _selectedProjectId = model.SelectedProjectId;
        CurrentModel = model;
        ApplyModel(model);
    }

    public void SetSnapshot(CockpitSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        _snapshot = snapshot;
        var model = DetailsPresentation.Build(snapshot, _selectedProjectId, _lang);
        _selectedProjectId = model.SelectedProjectId;
        CurrentModel = model;
        ApplyModel(model);
    }

    public void SelectProject(string? projectId)
    {
        _selectedProjectId = projectId;
        if (_snapshot is null) return;
        var model = DetailsPresentation.Build(_snapshot, _selectedProjectId, _lang);
        _selectedProjectId = model.SelectedProjectId;
        CurrentModel = model;
        ApplyModel(model);
    }

    protected void RequestNavigation(NavigationTarget target)
    {
        if (_snapshot is null || _selectedProjectId is null) return;
        if (!DetailsPresentation.IsAllowedNavigation(_snapshot, _selectedProjectId, target)) return;
        NavigationRequested?.Invoke(this, new NavigationRequestEventArgs(target));
    }

    private void ApplyChrome()
    {
        NowTitle.Text = ConsumerCopy.T(_lang, "now");
        HowFarTitle.Text = ConsumerCopy.T(_lang, "how_far");
        StuckTitle.Text = ConsumerCopy.T(_lang, "stuck");
        NextTitle.Text = ConsumerCopy.T(_lang, "next");
        PascalNeedTitle.Text = ConsumerCopy.T(_lang, "need_you");
        GoalLabel.Text = ConsumerCopy.T(_lang, "goal");
        ProgressTitle.Text = ConsumerCopy.T(_lang, "progress");
        PascalSectionTitle.Text = ConsumerCopy.T(_lang, "pascal_section");
        CurrentWorkTitle.Text = ConsumerCopy.T(_lang, "current_roles");
        NoCurrentWorkText.Text = ConsumerCopy.T(_lang, "no_current_roles");
        ArtifactTitle.Text = ConsumerCopy.T(_lang, "artifacts");
        NoArtifactText.Text = ConsumerCopy.T(_lang, "no_artifacts");
        LeadTitle.Text = ConsumerCopy.T(_lang, "lead_pending");
        SecretaryTitle.Text = ConsumerCopy.T(_lang, "secretary");
        HistoryTitle.Text = ConsumerCopy.T(_lang, "history_roles");
        NoHistoryText.Text = ConsumerCopy.T(_lang, "no_history");
        NavTitle.Text = ConsumerCopy.T(_lang, "nav");
        NoNavText.Text = ConsumerCopy.T(_lang, "no_nav");
        DiagnosticsToggle.Content = ConsumerCopy.T(_lang, _showDiagnostics ? "diag_close" : "diag_open");
    }

    private void ApplyModel(DetailsModel model)
    {
        ApplyChrome();
        if (!string.IsNullOrWhiteSpace(model.EmptyMessage))
        {
            EmptyText.Visibility = Visibility.Visible;
            EmptyText.Text = model.EmptyMessage;
            ContentPanel.Visibility = Visibility.Collapsed;
            return;
        }

        EmptyText.Visibility = Visibility.Collapsed;
        ContentPanel.Visibility = Visibility.Visible;

        NameText.Text = model.Name;
        OverallJudgmentText.Text = model.OverallJudgment;
        OverallBasisText.Text = model.OverallBasis;
        SelectedIdText.Text = string.Empty;
        SelectedIdText.Visibility = Visibility.Collapsed;
        var metaParts = new List<string> { ConsumerCopy.T(_lang, "quality_short") + model.ProjectQualityText };
        if (!string.IsNullOrWhiteSpace(model.LastFactAtText))
            metaParts.Add(ConsumerCopy.T(_lang, "fact_time") + model.LastFactAtText);
        MetaText.Text = string.Join(" · ", metaParts);
        if (string.IsNullOrWhiteSpace(model.FreshnessHint))
        {
            FreshnessText.Visibility = Visibility.Collapsed;
        }
        else
        {
            FreshnessText.Visibility = Visibility.Visible;
            FreshnessText.Text = model.FreshnessHint;
        }

        WhoText.Text = model.WhoDoingWhat;
        HowFarText.Text = model.HowFar;
        StuckText.Text = model.StuckAt;
        NextStepText.Text = model.NextOwner;
        PascalNeedText.Text = model.NeedsPascal;
        GoalText.Text = model.Goal;
        GoalLabel.Visibility = string.IsNullOrWhiteSpace(model.Goal)
            || model.Goal is "未声明" or "未用一句话写明目标" or "not stated" or "no one-line goal"
            ? Visibility.Collapsed : Visibility.Visible;
        GoalText.Visibility = GoalLabel.Visibility;
        PhaseText.Text = model.Phase;
        SummaryText.Text = model.Summary;
        DiagnosticsText.Text = model.DiagnosticsText;
        DiagnosticsText.Visibility = _showDiagnostics ? Visibility.Visible : Visibility.Collapsed;
        TechnicalPanel.Visibility = _showDiagnostics ? Visibility.Visible : Visibility.Collapsed;
        DiagnosticsToggle.Content = ConsumerCopy.T(_lang, _showDiagnostics ? "diag_close" : "diag_open");

        if (string.IsNullOrWhiteSpace(model.ProgressText))
        {
            ProgressPanel.Visibility = Visibility.Collapsed;
            ProgressText.Text = string.Empty;
        }
        else
        {
            ProgressPanel.Visibility = Visibility.Visible;
            ProgressText.Text = model.ProgressText;
        }

        PascalSectionTitle.Visibility = model.PascalAttentions.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        PascalList.ItemsSource = model.PascalAttentions;
        PascalList.Visibility = model.PascalAttentions.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        CurrentWorkList.ItemsSource = model.CurrentWorks;
        NoCurrentWorkText.Visibility = model.CurrentWorks.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (string.IsNullOrWhiteSpace(model.UnassignedReviewText))
        {
            UnassignedReviewText.Visibility = Visibility.Collapsed;
            UnassignedReviewText.Text = string.Empty;
        }
        else
        {
            UnassignedReviewText.Visibility = Visibility.Visible;
            UnassignedReviewText.Text = model.UnassignedReviewText;
        }

        ArtifactList.ItemsSource = model.Artifacts;
        NoArtifactText.Visibility = model.Artifacts.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        LeadList.ItemsSource = model.LeadAttentions;
        SecretaryList.ItemsSource = model.SecretaryAttentions;

        HistoricalWorkList.ItemsSource = model.HistoricalWorks;
        NoHistoryText.Visibility = model.HistoricalWorks.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        NavPanel.Children.Clear();
        if (model.NavigationButtons.Count == 0)
        {
            NoNavText.Visibility = Visibility.Visible;
        }
        else
        {
            NoNavText.Visibility = Visibility.Collapsed;
            foreach (var nav in model.NavigationButtons)
            {
                var button = new Button
                {
                    Content = nav.Label,
                    Tag = nav.Target,
                    Style = (Style)FindResource("NavButton"),
                    ToolTip = nav.Target.Kind + " → " + nav.Target.Target
                };
                button.Click += OnNavClick;
                NavPanel.Children.Add(button);
            }
        }
    }

    private void OnNavClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: NavigationTarget target })
            RequestNavigation(target);
    }

    private void OnDiagnosticsToggle(object sender, RoutedEventArgs e)
    {
        _showDiagnostics = !_showDiagnostics;
        DiagnosticsText.Visibility = _showDiagnostics ? Visibility.Visible : Visibility.Collapsed;
        TechnicalPanel.Visibility = _showDiagnostics ? Visibility.Visible : Visibility.Collapsed;
        DiagnosticsToggle.Content = ConsumerCopy.T(_lang, _showDiagnostics ? "diag_close" : "diag_open");
    }
}
