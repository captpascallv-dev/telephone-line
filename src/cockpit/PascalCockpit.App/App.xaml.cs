using System.IO;
using System.Windows;
using PascalCockpit.Collection;
using PascalCockpit.Contracts;
using PascalCockpit.Normalization;
using PascalCockpit.Projection;

namespace PascalCockpit.App;

public partial class App : Application
{
    SingleInstance? _singleInstance;
    CancellationTokenSource? _refreshCts;
    RefreshService? _refresh;
    PreferenceStore? _prefs;
    MainWindow? _main;

    void OnStartup(object sender, StartupEventArgs e)
    {
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        _singleInstance = new SingleInstance();
        if (!_singleInstance.TryAcquire())
        {
            Shutdown();
            return;
        }

        ProductPaths.EnsureDataDirectory();
        var config = AppConfig.Load(ReadExplicitConfigPath(e.Args));
        _prefs = new PreferenceStore(ProductPaths.SettingsFile);
        var preferences = _prefs.Load();

        var probe = new WindowsProcessProbe();
        var frozenPath = config.FrozenCollectionPath;
        ICollector collector = !string.IsNullOrWhiteSpace(frozenPath) && File.Exists(frozenPath)
            ? new FrozenCollectionCollector(frozenPath)
            : new FileCollector(probe);
        var normalizer = new EvidenceNormalizer();
        var projector = new StateProjector();
        _refresh = new RefreshService(collector, normalizer, projector);

        var host = new CockpitHostModel();
        _main = new MainWindow(host, _refresh, config, _prefs, preferences);
        _main.Closed += (_, _) =>
        {
            try { _refreshCts?.Cancel(); } catch (ObjectDisposedException) { }
            Shutdown();
        };
        _main.ShowActivated = false;
        _main.Show();

        DispatcherUnhandledException += (_, args) =>
        {
            WriteUiError(args.Exception);
            args.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            WriteUiError(args.Exception);
            args.SetObserved();
        };

        _refreshCts = new CancellationTokenSource();
        _ = _main.StartRefreshLoopAsync(_refreshCts.Token).ContinueWith(t =>
        {
            if (t.Exception is not null) WriteUiError(t.Exception);
        }, TaskContinuationOptions.OnlyOnFaulted);
    }

    static void WriteUiError(Exception ex)
    {
        try
        {
            var path = System.IO.Path.Combine(ProductPaths.DataDirectory, "ui-error.txt");
            System.IO.File.WriteAllText(path, DateTimeOffset.UtcNow.ToString("o") + Environment.NewLine + ex);
        }
        catch
        {
        }
    }

    void OnExit(object sender, ExitEventArgs e)
    {
        try { _refreshCts?.Cancel(); } catch (ObjectDisposedException) { }
        _refreshCts?.Dispose();
        _refresh?.Dispose();
        _singleInstance?.Dispose();
    }

    static string? ReadExplicitConfigPath(string[] args)
    {
        for (var i = 0; i < args.Length; i++)
        {
            var a = args[i];
            if ((a.Equals("--config", StringComparison.OrdinalIgnoreCase)
                 || a.Equals("-ConfigPath", StringComparison.OrdinalIgnoreCase))
                && i + 1 < args.Length)
            {
                return args[i + 1];
            }

            const string prefix = "--config=";
            if (a.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                return a[prefix.Length..];
        }

        return null;
    }
}
