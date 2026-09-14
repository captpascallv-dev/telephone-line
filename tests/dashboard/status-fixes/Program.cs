using System.Text.Json.Nodes;
using PascalCockpit.Contracts;
using PascalCockpit.Normalization;
using PascalCockpit.Projection;
using PascalCockpit.Views;

internal static class Program
{
    static int _failed;

    public static int Main(string[] args)
    {
        var only = args.Length > 0 && string.Equals(args[0], "st1-c6", StringComparison.OrdinalIgnoreCase);
        CurrentJobUsesDispatchNotStaleActiveWork();
        if (!only)
        {
            CurrentJobUsesNestedNativeModelWhenDispatchOmitsModel();
            GrokModelIsNotGrokCliRoute();
            HandledNestedAcceptanceGoesHistorical();
        }

        UnhandledOldReceiptAndParallelLanesStayCurrent();
        if (!only)
        {
            AcceptedDeliveryFoldsInstallRemaining();
            StatusDisplayReworkStaysCurrent();
        }

        PriorDeliveryDoesNotHideCurrentUnacceptedReturn();
        if (!only)
            CurrentRoundAcceptanceFoldsAfterUnacceptedReturn();
        AcceptedPackageOwnerContinuesUnfinishedProject();
        FailedRoundHandledIsNotNormalProgress();
        if (!only)
        {
            PreparedCorrectionIsNotRunningStaleRoute();
            PreparedForDispatchIsNotRunningStaleRoute();
            PreparedThenActualDispatchUsesRequestIdentity();
        }

        PreparedForDispatchThenActualDispatchUsesRequestIdentity();
        CurrentReturnedAcceptanceIsNotComputerResumeWait();
        ExplicitBudgetWaitIsNotComputerResume();
        DeliveryHistoryIsNotContentAcceptance();
        PackagePrefixDoesNotAcceptCurrentReturn();
        ExactTransportPackageAcceptanceStillFolds();
        LocalOnlyVisualDoesNotClaimPublicPublished();
        AcceptingDoesNotHideParallelUnhandledFailure();
        if (!only)
        {
            PreserveGenerationIsNotContinueGenerating();
            LocalOnlyDeliveryIsNotComplete();
            AcceptedStatusFixHistoryIsComplete();
            PublicationStepKeepsGithub();
            PendingCallbackWithoutReceiptIsNotReturned();
            UndispatchedRemainingStillShows();
        }

        Console.WriteLine(_failed == 0 ? "ALL_OK" : "FAILED=" + _failed);
        return _failed == 0 ? 0 : 1;
    }

    static void CurrentReturnedAcceptanceIsNotComputerResumeWait()
    {
        var project = "proj-cb-" + Guid.NewGuid().ToString("N")[..8];
        var line = Guid.NewGuid().ToString();
        var direct = Guid.NewGuid().ToString();
        var now = DateTimeOffset.Parse("2026-09-14T22:16:00+08:00");
        var snap = Project(new[]
        {
            Registry(project, "ACTIVE", now, remaining: "本轮回件尚未验收"),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["state"] = "LEAD_ACCEPTANCE_IN_PROGRESS",
                ["execution_state"] = "RETURNED",
                ["current_package_accepted"] = false,
                ["need_user_action"] = false,
                ["pascal_decision_required"] = false,
                ["visual_acceptance"] = "LIVE_UI_SUSPENDED_INDEPENDENT_CORRECTION_ACTIVE",
                ["computer_use_suspended"] = true,
                ["visual_acceptance_complete"] = false,
                ["local_applied"] = true,
                ["public_published"] = true,
                ["product_pass"] = false,
                ["current_handler"] = "原负责人正在核对本轮回件",
                ["next"] = "原负责人按冻结卡核验。最后实窗核验仍遵守电脑操作暂停。",
                ["summary"] = "本机和公开已交付；本轮可见状态修正已回件，原负责人正在验收，修正尚未更新到本机或公开。"
            }, project),
            Doc("line_dispatch", "jobs/" + line + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor"
            }, project),
            Doc("line_receipt", "jobs/" + line + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor",
                ["transport_complete"] = true,
                ["command_exit_code"] = 0,
                ["project_judgment"] = false
            }, project)
        }, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        var en = DetailsPresentation.Build(snap, p.Id, UiLang.En);
        var hud = StatusLanguage.ProjectOneLinerFull(p, UiLang.Zh);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        Expect("f1.overall_accepting", details.OverallJudgment.Contains("等待验收", StringComparison.Ordinal));
        Expect("f1.overall_not_pascal_wait", !details.OverallJudgment.Contains("需要你处理", StringComparison.Ordinal));
        Expect("f1.who_accepting", details.WhoDoingWhat.Contains("验收", StringComparison.Ordinal));
        Expect("f1.howfar_keeps_delivery", details.HowFar.Contains("本机", StringComparison.Ordinal)
                                            && details.HowFar.Contains("尚未验收", StringComparison.Ordinal));
        Expect("f1.stuck_not_computer", !details.StuckAt.Contains("恢复电脑", StringComparison.Ordinal)
                                        && !details.StuckAt.Contains("缺来源", StringComparison.Ordinal));
        Expect("f1.next_lead", details.NextOwner.Contains("验收", StringComparison.Ordinal));
        Expect("f1.pascal_not_computer", !details.NeedsPascal.Contains("恢复电脑", StringComparison.Ordinal));
        Expect("f1.hud_not_computer_only", !hud.Contains("恢复电脑操作", StringComparison.Ordinal)
                                          && hud.Contains("验收", StringComparison.Ordinal));
        Expect("f1.role_current_return", current.Any(r => r.RoleKind == "executor" && !r.IsHistorical
                                                         && (r.StatusText.Contains("验收", StringComparison.Ordinal)
                                                             || r.StatusText.Contains("交回", StringComparison.Ordinal))));
        Expect("f1.en_same", en.OverallJudgment.Contains("acceptance", StringComparison.OrdinalIgnoreCase)
                             && !en.NeedsPascal.Contains("computer", StringComparison.OrdinalIgnoreCase));
    }

    static void ExplicitBudgetWaitIsNotComputerResume()
    {
        var project = "c6-private-explicit-user-action";
        var now = DateTimeOffset.Parse("2026-09-14T14:13:16Z");
        var snap = Project(new[]
        {
            Doc("project_registry", "registry.json", now, new JsonObject
            {
                ["projects"] = new JsonArray(new JsonObject
                {
                    ["project_id"] = project,
                    ["display_name"] = "私有状态边界对照",
                    ["status"] = "ACTIVE",
                    ["product_pass"] = false
                })
            }, project),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["state"] = "WAITING_USER_DECISION",
                ["need_user_action"] = true,
                ["pascal_decision_required"] = true,
                ["waiting_for"] = "确认预算",
                ["current_handler"] = "原负责人等待预算确认",
                ["next"] = "请确认预算后继续",
                ["remaining"] = new JsonArray("预算确认"),
                ["local_applied"] = false,
                ["public_published"] = false,
                ["publication_complete"] = false,
                ["product_pass"] = false,
                ["current_package_accepted"] = false
            }, project)
        }, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        var en = DetailsPresentation.Build(snap, p.Id, UiLang.En);
        var hud = StatusLanguage.ProjectOneLinerFull(p, UiLang.Zh);
        Expect("f2.pascal_budget", details.NeedsPascal.Contains("预算", StringComparison.Ordinal)
                                     || details.WhoDoingWhat.Contains("预算", StringComparison.Ordinal));
        Expect("f2.not_computer", !details.NeedsPascal.Contains("恢复电脑", StringComparison.Ordinal)
                                   && !details.HowFar.Contains("恢复电脑", StringComparison.Ordinal)
                                   && !hud.Contains("恢复电脑", StringComparison.Ordinal));
        Expect("f2.not_published", !details.HowFar.Contains("公开版本已发布", StringComparison.Ordinal)
                                   && !details.WhoDoingWhat.Contains("本机和公开已交付", StringComparison.Ordinal)
                                   && !hud.Contains("公开版本已发布", StringComparison.Ordinal));
        Expect("f2.en_budget", en.NeedsPascal.Contains("budget", StringComparison.OrdinalIgnoreCase)
                               || en.WhoDoingWhat.Contains("budget", StringComparison.OrdinalIgnoreCase)
                               || en.OverallBasis.Contains("budget", StringComparison.OrdinalIgnoreCase)
                               || en.StuckAt.Contains("budget", StringComparison.OrdinalIgnoreCase));
    }

    static void DeliveryHistoryIsNotContentAcceptance()
    {
        var project = "c6-private-delivery-is-not-acceptance";
        var currentLine = "47743e3f-54c4-450e-9d41-edf4801f587e";
        var oldLine = "d18ef983-884c-458b-ab47-afddf95c83d8";
        var now = DateTimeOffset.Parse("2026-09-14T14:13:16Z");
        var snap = Project(new[]
        {
            Doc("project_registry", "registry.json", now, new JsonObject
            {
                ["projects"] = new JsonArray(new JsonObject
                {
                    ["project_id"] = project,
                    ["display_name"] = "私有状态边界对照",
                    ["status"] = "ACTIVE",
                    ["product_pass"] = false
                })
            }, project),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = currentLine,
                ["state"] = "RUNNING",
                ["current_package_accepted"] = false,
                ["product_pass"] = false,
                ["history"] = new JsonArray(new JsonObject
                {
                    ["line_job_id"] = oldLine,
                    ["state"] = "DELIVERED",
                    ["local_applied"] = true
                })
            }, project),
            Doc("line_dispatch", "jobs/" + currentLine + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = currentLine,
                ["route"] = "direct-cursor"
            }, project),
            Doc("line_receipt", "jobs/" + oldLine + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = oldLine,
                ["route"] = "direct-grok-cli",
                ["transport_complete"] = true,
                ["command_exit_code"] = 0,
                ["project_judgment"] = false
            }, project)
        }, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        var hist = RolePresentation.HistoricalRows(p, UiLang.Zh);
        Expect("f3.deliv.old_not_accepted", !hist.Any(r => r.Id.Contains(oldLine, StringComparison.Ordinal)
                                                           && r.StatusText.Contains("已验收", StringComparison.Ordinal))
                                            && !current.Any(r => r.Id.Contains(oldLine, StringComparison.Ordinal)
                                                                  && r.StatusText.Contains("已验收", StringComparison.Ordinal)));
        Expect("f3.deliv.current_running", current.Any(r => r.Id.Contains(currentLine, StringComparison.Ordinal)
                                                           && !r.IsHistorical));
    }

    static void PackagePrefixDoesNotAcceptCurrentReturn()
    {
        var project = "c6-private-package-prefix";
        var line = "05db805c-5719-442f-a2cd-2f5b0274ee8a";
        var now = DateTimeOffset.Parse("2026-09-14T14:13:16Z");
        var snap = Project(new[]
        {
            Doc("project_registry", "registry.json", now, new JsonObject
            {
                ["projects"] = new JsonArray(new JsonObject
                {
                    ["project_id"] = project,
                    ["display_name"] = "私有状态边界对照",
                    ["status"] = "ACTIVE",
                    ["product_pass"] = false
                })
            }, project),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["state"] = "RETURNED",
                ["execution_state"] = "returned",
                ["package_id"] = "PKG-C1-R1",
                ["current_package_accepted"] = false,
                ["product_pass"] = false
            }, project),
            Doc("line_dispatch", "jobs/" + line + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["route"] = "direct-cursor",
                ["package_id"] = "PKG-C1-R1"
            }, project),
            Doc("line_receipt", "jobs/" + line + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["route"] = "direct-cursor",
                ["transport_complete"] = true,
                ["command_exit_code"] = 0,
                ["project_judgment"] = false
            }, project),
            Doc("bot_acceptance", "OLD_ACCEPTANCE.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["package_id"] = "PKG-C1",
                ["verdict"] = "PASS",
                ["product_pass"] = false
            }, project)
        }, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        var hist = RolePresentation.HistoricalRows(p, UiLang.Zh);
        Expect("f3.prefix.current", current.Any(r => r.Id.Contains(line, StringComparison.Ordinal) && !r.IsHistorical));
        Expect("f3.prefix.not_folded", !hist.Any(r => r.Id.Contains(line, StringComparison.Ordinal)));
        Expect("f3.prefix.not_accepted", current.Any(r => r.Id.Contains(line, StringComparison.Ordinal)
                                                            && !r.StatusText.Contains("已验收", StringComparison.Ordinal)));
    }

    static void ExactTransportPackageAcceptanceStillFolds()
    {
        var project = "proj-exact-pkg-" + Guid.NewGuid().ToString("N")[..8];
        var line = Guid.NewGuid().ToString();
        var direct = Guid.NewGuid().ToString();
        var now = DateTimeOffset.Parse("2026-09-14T16:12:00+08:00");
        var snap = Project(new[]
        {
            Registry(project, "ACTIVE", now, remaining: "完整产品尚未完成", summary: "上一包已验收；整体未完成"),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["state"] = "RETURNED",
                ["package_id"] = "ST2-C1-R1",
                ["current_package_accepted"] = true,
                ["product_pass"] = false,
                ["current_handler"] = "原负责人继续后续工作"
            }, project),
            Doc("line_dispatch", "jobs/" + line + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor",
                ["package_id"] = "ST2-C1-R1"
            }, project),
            Doc("line_receipt", "jobs/" + line + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor",
                ["transport_complete"] = true,
                ["command_exit_code"] = 0,
                ["project_judgment"] = false
            }, project),
            Doc("bot_acceptance", "LEAD_ACCEPTANCE.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["package_id"] = "ST2-C1",
                ["transport_package_id"] = "ST2-C1-R1",
                ["verdict"] = "PASS",
                ["product_pass"] = false,
                ["current_package_accepted"] = true
            }, project)
        }, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        var hist = RolePresentation.HistoricalRows(p, UiLang.Zh);
        Expect("f3.exact.folded", hist.Any(r => r.Id.Contains(line, StringComparison.Ordinal)
                                                 && r.StatusText.Contains("已验收", StringComparison.Ordinal)));
        Expect("f3.exact.not_current", current.All(r => !r.Id.Contains(line, StringComparison.Ordinal)));
    }

    static void LocalOnlyVisualDoesNotClaimPublicPublished()
    {
        var project = "c6-private-local-only-visual";
        var now = DateTimeOffset.Parse("2026-09-14T14:13:16Z");
        var snap = Project(new[]
        {
            Doc("project_registry", "registry.json", now, new JsonObject
            {
                ["projects"] = new JsonArray(new JsonObject
                {
                    ["project_id"] = project,
                    ["display_name"] = "私有状态边界对照",
                    ["status"] = "ACTIVE",
                    ["product_pass"] = false
                })
            }, project),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["state"] = "LOCAL_DELIVERED_VISUAL_SUSPENDED",
                ["need_user_action"] = true,
                ["pascal_decision_required"] = true,
                ["waiting_for"] = "恢复电脑操作",
                ["current_handler"] = "原负责人等待实窗核验",
                ["next"] = "恢复电脑操作后由原负责人核验",
                ["remaining"] = new JsonArray("最后实窗核验", "公开发布"),
                ["local_applied"] = true,
                ["public_published"] = false,
                ["publication_complete"] = false,
                ["product_pass"] = false,
                ["current_package_accepted"] = true,
                ["execution_state"] = "RETURNED_ACCEPTED",
                ["lead_acceptance"] = "PASS",
                ["visual_acceptance"] = "PENDING_USER_RESUME_COMPUTER_USE",
                ["computer_use_suspended"] = true,
                ["visual_acceptance_complete"] = false
            }, project)
        }, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        var en = DetailsPresentation.Build(snap, p.Id, UiLang.En);
        var hud = StatusLanguage.ProjectOneLinerFull(p, UiLang.Zh);
        var overall = StatusLanguage.OverallJudgment(p, UiLang.Zh);
        Expect("f2p.howfar_local", details.HowFar.Contains("本机", StringComparison.Ordinal)
                                      && details.HowFar.Contains("实窗", StringComparison.Ordinal));
        Expect("f2p.keeps_computer", details.StuckAt.Contains("恢复电脑", StringComparison.Ordinal)
                                       && hud.Contains("恢复电脑", StringComparison.Ordinal));
        Expect("f2p.no_public_claim", !details.HowFar.Contains("公开版本已发布", StringComparison.Ordinal)
                                      && !details.WhoDoingWhat.Contains("公开版本已发布", StringComparison.Ordinal)
                                      && !details.WhoDoingWhat.Contains("本机和公开已交付", StringComparison.Ordinal)
                                      && !details.OverallBasis.Contains("公开版本已发布", StringComparison.Ordinal)
                                      && !details.OverallBasis.Contains("本机和公开已交付", StringComparison.Ordinal)
                                      && !hud.Contains("公开版本已发布", StringComparison.Ordinal)
                                      && !hud.Contains("本机和公开已交付", StringComparison.Ordinal)
                                      && !overall.Basis.Contains("公开版本已发布", StringComparison.Ordinal)
                                      && !overall.Basis.Contains("本机和公开已交付", StringComparison.Ordinal));
        Expect("f2p.keeps_local_progress", details.HowFar.Contains("本机文件已更新", StringComparison.Ordinal)
                                           && (details.WhoDoingWhat.Contains("本机文件已更新", StringComparison.Ordinal)
                                               || details.OverallBasis.Contains("本机文件已更新", StringComparison.Ordinal)
                                               || hud.Contains("本机文件已更新", StringComparison.Ordinal)));
        Expect("f2p.en_same", !en.WhoDoingWhat.Contains("public release", StringComparison.OrdinalIgnoreCase)
                               && !en.OverallBasis.Contains("public", StringComparison.OrdinalIgnoreCase)
                               && (en.HowFar.Contains("Local files", StringComparison.OrdinalIgnoreCase)
                                   || en.HowFar.Contains("local", StringComparison.OrdinalIgnoreCase)));
    }

    static void AcceptingDoesNotHideParallelUnhandledFailure()
    {
        var project = "proj-cb-fail-" + Guid.NewGuid().ToString("N")[..8];
        var line = Guid.NewGuid().ToString();
        var direct = Guid.NewGuid().ToString();
        var failLine = Guid.NewGuid().ToString();
        var failDirect = Guid.NewGuid().ToString();
        var now = DateTimeOffset.Parse("2026-09-14T22:16:00+08:00");
        var snap = Project(new[]
        {
            Registry(project, "ACTIVE", now, remaining: "本轮回件尚未验收"),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["state"] = "LEAD_ACCEPTANCE_IN_PROGRESS",
                ["execution_state"] = "RETURNED",
                ["current_package_accepted"] = false,
                ["need_user_action"] = false,
                ["pascal_decision_required"] = false,
                ["visual_acceptance"] = "LIVE_UI_SUSPENDED_INDEPENDENT_CORRECTION_ACTIVE",
                ["computer_use_suspended"] = true,
                ["visual_acceptance_complete"] = false,
                ["local_applied"] = true,
                ["public_published"] = true,
                ["product_pass"] = false,
                ["current_handler"] = "原负责人正在核对本轮回件",
                ["next"] = "原负责人按冻结卡核验。最后实窗核验仍遵守电脑操作暂停。",
                ["summary"] = "本机和公开已交付；本轮可见状态修正已回件，原负责人正在验收，修正尚未更新到本机或公开。"
            }, project),
            Doc("line_dispatch", "jobs/" + line + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor"
            }, project),
            Doc("line_receipt", "jobs/" + line + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor",
                ["transport_complete"] = true,
                ["command_exit_code"] = 0,
                ["project_judgment"] = false
            }, project),
            Doc("line_receipt", "jobs/" + failLine + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = failLine,
                ["direct_job_id"] = failDirect,
                ["route"] = "direct-cursor",
                ["transport_complete"] = true,
                ["success"] = false,
                ["command_exit_code"] = 1,
                ["project_judgment"] = false
            }, project)
        }, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        var en = DetailsPresentation.Build(snap, p.Id, UiLang.En);
        var hud = StatusLanguage.ProjectOneLinerFull(p, UiLang.Zh);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        Expect("f1p.overall_fault", details.OverallJudgment.Contains("故障", StringComparison.Ordinal));
        Expect("f1p.overall_not_only_accept", !details.OverallJudgment.Contains("等待验收", StringComparison.Ordinal));
        Expect("f1p.visible_failure", details.WhoDoingWhat.Contains("失败", StringComparison.Ordinal)
                                         && details.StuckAt.Contains("失败", StringComparison.Ordinal)
                                         && hud.Contains("失败", StringComparison.Ordinal)
                                         && details.OverallBasis.Contains("失败", StringComparison.Ordinal));
        Expect("f1p.keeps_accepting", details.WhoDoingWhat.Contains("验收", StringComparison.Ordinal)
                                        && hud.Contains("验收", StringComparison.Ordinal)
                                        && details.NextOwner.Contains("验收", StringComparison.Ordinal));
        Expect("f1p.not_pascal_only", !details.OverallJudgment.Contains("需要你处理", StringComparison.Ordinal)
                                        && !details.NeedsPascal.Contains("恢复电脑", StringComparison.Ordinal));
        Expect("f1p.role_lead_accepting", current.Any(r => r.RoleKind == "lead" && !r.IsHistorical
                                                          && r.StatusText.Contains("验收", StringComparison.Ordinal)));
        Expect("f1p.role_returned_accepting", current.Any(r => r.RoleKind == "executor" && !r.IsHistorical
                                                                && r.Id.Contains(line, StringComparison.Ordinal)
                                                                && (r.StatusText.Contains("验收", StringComparison.Ordinal)
                                                                    || r.StatusText.Contains("交回", StringComparison.Ordinal))));
        Expect("f1p.role_failed_current", current.Any(r => r.RoleKind == "executor" && !r.IsHistorical
                                                          && r.Id.Contains(failLine, StringComparison.Ordinal)
                                                          && r.StatusText.Contains("失败", StringComparison.Ordinal)));
        Expect("f1p.en_same", (en.OverallJudgment.Contains("Fault", StringComparison.OrdinalIgnoreCase)
                               || en.OverallJudgment.Contains("fault", StringComparison.OrdinalIgnoreCase)
                               || en.OverallJudgment.Contains("exception", StringComparison.OrdinalIgnoreCase))
                              && (en.WhoDoingWhat.Contains("fail", StringComparison.OrdinalIgnoreCase)
                                  || en.StuckAt.Contains("fail", StringComparison.OrdinalIgnoreCase))
                              && (en.WhoDoingWhat.Contains("accept", StringComparison.OrdinalIgnoreCase)
                                  || en.NextOwner.Contains("accept", StringComparison.OrdinalIgnoreCase)));
    }

    static void CurrentJobUsesDispatchNotStaleActiveWork()
    {
        var project = "proj-route-" + Guid.NewGuid().ToString("N")[..8];
        var line = Guid.NewGuid().ToString();
        var direct = Guid.NewGuid().ToString();
        var now = DateTimeOffset.Parse("2026-09-14T09:16:00+08:00");
        var docs = new[]
        {
            Registry(project, "ACTIVE", now, remaining: null),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["executor_route"] = "direct-grok-cli",
                ["executor_model"] = "grok-4.6",
                ["executor_reasoning"] = "high",
                ["state"] = "RUNNING",
                ["next"] = "11:09 再被平台安全提示终止；后续修正尚未派出"
            }, project),
            Doc("line_dispatch", "jobs/" + line + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor",
                ["executor_model"] = "cursor-grok-4.6-xhigh",
                ["reasoning_effort"] = "xhigh"
            }, project),
            Doc("direct_request", "jobs/" + direct + "/request.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["job_id"] = direct,
                ["line_job_id"] = line,
                ["route"] = "direct-cursor",
                ["model"] = "cursor-grok-4.6-xhigh",
                ["reasoning_effort"] = "xhigh",
                ["protocol_version"] = "direct-cursor-request-v1"
            }, project)
        };

        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var rows = RolePresentation.CurrentRows(p, UiLang.Zh);
        var exec = rows.FirstOrDefault(r => r.RoleKind == "executor" || r.RoleLabel.Contains("执行", StringComparison.Ordinal));
        Expect("route.entry", exec is not null && exec.ActorName.Contains("直达游标", StringComparison.Ordinal));
        Expect("route.not_gege", exec is not null && !exec.ActorName.Contains("格格", StringComparison.Ordinal)
                                 && (exec.Route is null || exec.Route == "direct-cursor"));
        Expect("route.model", exec is not null && exec.ModelText.Contains("cursor-grok-4.6-xhigh", StringComparison.Ordinal));
        Expect("route.effort", exec is not null && exec.EffortText.Contains("xhigh", StringComparison.Ordinal));
        Expect("route.summary_not_stale", !p.Summary.Contains("尚未派出", StringComparison.Ordinal)
                                           && !p.Summary.Contains("11:09", StringComparison.Ordinal));
        var en = RolePresentation.CurrentRows(p, UiLang.En);
        var execEn = en.FirstOrDefault(r => r.RoleKind == "executor" || r.RoleLabel.Contains("Executor", StringComparison.OrdinalIgnoreCase));
        Expect("route.entry_en", execEn is not null && execEn.ActorName.Contains("Direct Cursor", StringComparison.OrdinalIgnoreCase));
    }

    static void GrokModelIsNotGrokCliRoute()
    {
        Expect("model.route_from_cursor", JobIdentity.RouteFromModel("cursor-grok-4.6-xhigh") == "direct-cursor");
        Expect("model.grok_not_route", JobIdentity.RouteFromModel("grok-4.6") is null);
        Expect("model.plain_grok_not_route", JobIdentity.RouteFromModel("Grok 4.6") is null);
        Expect("model.fits_cursor", JobIdentity.ModelFitsRoute("direct-cursor", "cursor-grok-4.6-xhigh"));
        Expect("model.plain_grok_not_cursor", !JobIdentity.ModelFitsRoute("direct-cursor", "grok-4.6"));
        Expect("model.cursor_not_grokcli", !JobIdentity.ModelFitsRoute("direct-grok-cli", "cursor-grok-4.6-xhigh"));
    }

    static void CurrentJobUsesNestedNativeModelWhenDispatchOmitsModel()
    {
        var project = "proj-nested-" + Guid.NewGuid().ToString("N")[..8];
        var line = Guid.NewGuid().ToString();
        var direct = Guid.NewGuid().ToString();
        var now = DateTimeOffset.Parse("2026-09-14T09:16:00+08:00");
        var docs = new[]
        {
            Registry(project, "ACTIVE", now, remaining: null),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["executor_route"] = "direct-grok-cli",
                ["executor_model"] = "grok-4.6",
                ["executor_reasoning"] = "high",
                ["state"] = "RUNNING",
                ["current_route_switch"] = new JsonObject
                {
                    ["old_route"] = "direct-grok-cli",
                    ["new_route"] = "direct-cursor",
                    ["new_line_job_id"] = line,
                    ["new_direct_job_id"] = direct
                },
                ["native_live"] = new JsonObject
                {
                    ["business_line_job_id"] = line,
                    ["business_direct_job_id"] = direct,
                    ["native_model"] = "cursor-grok-4.6-xhigh",
                    ["service_tier"] = "default"
                }
            }, project),
            Doc("line_dispatch", "jobs/" + line + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor"
            }, project)
        };

        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var exec = RolePresentation.CurrentRows(p, UiLang.Zh)
            .FirstOrDefault(r => r.RoleKind == "executor" || r.RoleLabel.Contains("执行", StringComparison.Ordinal));
        Expect("nested.entry", exec is not null && exec.ActorName.Contains("直达游标", StringComparison.Ordinal));
        Expect("nested.route", exec is not null && exec.Route == "direct-cursor");
        Expect("nested.model", exec is not null && exec.ModelText.Contains("cursor-grok-4.6-xhigh", StringComparison.Ordinal));
        Expect("nested.not_plain_grok", exec is not null && !exec.ModelText.Contains("模型：grok-4.6", StringComparison.Ordinal)
                                           && !exec.ModelText.EndsWith("grok-4.6", StringComparison.Ordinal));
    }

    static void HandledNestedAcceptanceGoesHistorical()
    {
        var project = "proj-hist-" + Guid.NewGuid().ToString("N")[..8];
        var curLine = Guid.NewGuid().ToString();
        var curDirect = Guid.NewGuid().ToString();
        var oldLine = Guid.NewGuid().ToString();
        var oldDirect = Guid.NewGuid().ToString();
        var now = DateTimeOffset.Parse("2026-09-14T09:16:00+08:00");
        var docs = new[]
        {
            Registry(project, "ACTIVE", now, remaining: null),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = curLine,
                ["direct_job_id"] = curDirect,
                ["executor_route"] = "direct-cursor",
                ["executor_model"] = "cursor-grok-4.6-xhigh",
                ["state"] = "RUNNING"
            }, project),
            Doc("line_dispatch", "jobs/" + curLine + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = curLine,
                ["direct_job_id"] = curDirect,
                ["route"] = "direct-cursor"
            }, project),
            Doc("line_receipt", "jobs/" + oldLine + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = oldLine,
                ["direct_job_id"] = oldDirect,
                ["route"] = "direct-grok-cli",
                ["transport_complete"] = true,
                ["success"] = true
            }, project),
            Doc("direct_receipt", "jobs/" + oldDirect + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["job_id"] = oldDirect,
                ["line_job_id"] = oldLine,
                ["route"] = "direct-grok-cli",
                ["transport_complete"] = true,
                ["success"] = true
            }, project),
            Doc("bot_acceptance", "acceptance/ACCEPTANCE.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["verdict"] = "PASS",
                ["product_pass"] = true,
                ["line_receipt"] = new JsonObject
                {
                    ["path"] = @"C:\jobs\" + oldLine + @"\receipt.json"
                },
                ["route_receipt"] = new JsonObject
                {
                    ["path"] = @"C:\jobs\" + oldDirect + @"\receipt.json"
                }
            }, project, scope: "historical")
        };

        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        var hist = RolePresentation.HistoricalRows(p, UiLang.Zh);
        Expect("hist.old_line_not_current", current.All(r => !r.Id.Contains(oldLine, StringComparison.Ordinal)));
        Expect("hist.old_direct_not_current", current.All(r => !r.Id.Contains(oldDirect, StringComparison.Ordinal)));
        Expect("hist.old_in_history", hist.Any(r => r.Id.Contains(oldLine, StringComparison.Ordinal)
                                                    || r.Id.Contains(oldDirect, StringComparison.Ordinal)));
        Expect("hist.current_kept", current.Any(r => r.Id.Contains(curLine, StringComparison.Ordinal)
                                                      || (r.Route == "direct-cursor")));
    }

    static void UnhandledOldReceiptAndParallelLanesStayCurrent()
    {
        var project = "proj-para-" + Guid.NewGuid().ToString("N")[..8];
        var lineA = Guid.NewGuid().ToString();
        var directA = Guid.NewGuid().ToString();
        var lineB = Guid.NewGuid().ToString();
        var directB = Guid.NewGuid().ToString();
        var oldLine = Guid.NewGuid().ToString();
        var now = DateTimeOffset.Parse("2026-09-14T09:16:00+08:00");
        var docs = new[]
        {
            Registry(project, "ACTIVE", now, remaining: null),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = lineA,
                ["direct_job_id"] = directA,
                ["executor_route"] = "direct-cursor",
                ["state"] = "RUNNING",
                ["lanes"] = new JsonObject
                {
                    ["a"] = new JsonObject
                    {
                        ["role"] = "execution",
                        ["route"] = "direct-cursor",
                        ["line_job_id"] = lineA,
                        ["job_id"] = directA,
                        ["state"] = "RUNNING"
                    },
                    ["b"] = new JsonObject
                    {
                        ["role"] = "execution",
                        ["route"] = "direct-claude-code",
                        ["line_job_id"] = lineB,
                        ["job_id"] = directB,
                        ["state"] = "RUNNING"
                    }
                }
            }, project),
            Doc("line_receipt", "jobs/" + oldLine + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = oldLine,
                ["route"] = "direct-grok-cli",
                ["transport_complete"] = true,
                ["success"] = true
            }, project)
        };

        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        var execs = current.Where(r => r.RoleKind == "executor" || r.RoleLabel.Contains("执行", StringComparison.Ordinal)).ToList();
        Expect("para.two_executors", execs.Count >= 2);
        Expect("para.unhandled_old_current", current.Any(r => r.Id.Contains(oldLine, StringComparison.Ordinal)));
        Expect("para.unhandled_not_history", RolePresentation.HistoricalRows(p, UiLang.Zh)
            .All(r => !r.Id.Contains(oldLine, StringComparison.Ordinal)));
    }

    static void AcceptedDeliveryFoldsInstallRemaining()
    {
        var project = "proj-done-" + Guid.NewGuid().ToString("N")[..8];
        var now = DateTimeOffset.Parse("2026-09-14T09:16:00+08:00");
        var docs = new[]
        {
            Registry(project, "COMPLETED", now, remaining: "telephone pending activate", local: true, publication: true,
                summary: "本轮整项已接受", productPass: true),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["executor_route"] = "direct-grok-cli",
                ["state"] = "WAITING_EXTERNAL",
                ["goal_state"] = "complete",
                ["product_pass"] = true,
                ["current_package_accepted"] = true,
                ["remaining"] = new JsonArray("telephone pending activate"),
                ["next"] = "Wait for telephone pending activate",
                ["local_runtime_delivered"] = true,
                ["publication_complete"] = true
            }, project),
            Doc("bot_acceptance", "LOCAL_INCREMENT_ACCEPTANCE.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["product_pass"] = true,
                ["formal_product_acceptance"] = true,
                ["current_package_accepted"] = true,
                ["verdict"] = "PASS",
                ["summary"] = "local runtime delivered"
            }, project),
            Doc("bot_acceptance", "PUBLICATION_ACCEPTANCE.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["product_pass"] = true,
                ["publication_complete"] = true,
                ["current_package_accepted"] = true,
                ["verdict"] = "PASS"
            }, project)
        };

        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        Expect("fold.inactive", !p.IsActive);
        Expect("fold.not_default", CurrentList.DefaultItems(snap).All(x => x.Id != project));
        Expect("fold.history_list", CurrentList.HistoricalItems(snap).Any(x => x.Id == project));
        Expect("fold.no_install_wait", !p.Summary.Contains("等安装", StringComparison.Ordinal)
                                       && !p.Summary.Contains("等待安装", StringComparison.Ordinal));
        Expect("fold.accepted_summary", p.Summary.Contains("已接受", StringComparison.Ordinal) || p.Phase.Contains("已完成", StringComparison.Ordinal));
        Expect("fold.rows_kept", p.WorkItems.Count > 0);
    }

    static void StatusDisplayReworkStaysCurrent()
    {
        var project = "proj-rework-" + Guid.NewGuid().ToString("N")[..8];
        var line = Guid.NewGuid().ToString();
        var now = DateTimeOffset.Parse("2026-09-14T09:16:00+08:00");
        var docs = new[]
        {
            Registry(project, "ACTIVE", now, remaining: "正在修正状态显示；telephone pending", local: true, publication: true,
                summary: "正在修正状态显示；telephone pending", productPass: false),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["executor_route"] = "direct-cursor",
                ["executor_model"] = "cursor-grok-4.6-xhigh",
                ["state"] = "CORRECTING_STATUS_DISPLAY",
                ["product_pass"] = false,
                ["current_package_accepted"] = false,
                ["current_handler"] = "正在修正状态显示",
                ["remaining"] = new JsonArray("正在修正状态显示", "telephone pending"),
                ["next"] = "Fix status display; do not wait for telephone pending",
                ["local_runtime_delivered"] = true,
                ["publication_complete"] = true
            }, project),
            Doc("line_dispatch", "jobs/" + line + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["route"] = "direct-cursor",
                ["executor_model"] = "cursor-grok-4.6-xhigh"
            }, project)
        };

        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        Expect("rework.active", p.IsActive);
        Expect("rework.default", CurrentList.DefaultItems(snap).Any(x => x.Id == project));
        Expect("rework.phrase", p.Summary.Contains("正在修正状态显示", StringComparison.Ordinal)
                                || p.Phase.Contains("正在修正状态显示", StringComparison.Ordinal));
        var en = DetailsPresentation.Build(snap, project, UiLang.En);
        Expect("rework.en", en.Summary.Contains("Fixing status display", StringComparison.OrdinalIgnoreCase)
                             || en.Phase.Contains("Fixing status display", StringComparison.OrdinalIgnoreCase));
    }

    static void PriorDeliveryDoesNotHideCurrentUnacceptedReturn()
    {
        var now = DateTimeOffset.Parse("2026-09-14T03:04:55Z");
        var snap = RoundConversionSnap(now, accepted: false);
        var p = snap.Projects.Single(x => x.Id == "same-task-next-round");
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        Expect("f2.returned.visible", CurrentList.IsDefaultCurrent(p));
        Expect("f2.returned.active", p.IsActive);
        Expect("f2.returned.not_complete_phase", !p.Phase.Equals("已完成", StringComparison.Ordinal));
        Expect("f2.returned.not_both_accepted", !p.Summary.Contains("本机与公开交付已接受", StringComparison.Ordinal));
        Expect("f2.returned.keeps_remaining", p.Summary.Contains("尚未验收", StringComparison.Ordinal)
                                            || p.Summary.Contains("仍需负责人验收", StringComparison.Ordinal)
                                            || details.OverallJudgment.Contains("等待验收", StringComparison.Ordinal));
        Expect("f2.returned.current_role", current.Any(r => r.RoleKind == "executor" && !r.IsHistorical));
        Expect("f2.returned.not_history_only", !RolePresentation.HistoricalRows(p, UiLang.Zh)
            .Any(r => r.RoleKind == "executor" && current.All(c => c.Id != r.Id)));
        Expect("f2.returned.judgment", details.OverallJudgment != "已完成");
    }

    static void CurrentRoundAcceptanceFoldsAfterUnacceptedReturn()
    {
        var now = DateTimeOffset.Parse("2026-09-14T03:20:00Z");
        var snap = RoundConversionSnap(now, accepted: true);
        var p = snap.Projects.Single(x => x.Id == "same-task-next-round");
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        Expect("f2.accepted.hidden", !CurrentList.IsDefaultCurrent(p));
        Expect("f2.accepted.inactive", !p.IsActive);
        Expect("f2.accepted.complete", p.Phase.Contains("已完成", StringComparison.Ordinal)
                                      || p.Summary.Contains("已接受", StringComparison.Ordinal)
                                      || p.Summary.Contains("已完成", StringComparison.Ordinal));
        Expect("f2.accepted.history", CurrentList.HistoricalItems(snap).Any(x => x.Id == p.Id));
        Expect("f2.accepted.no_current_exec", RolePresentation.CurrentRows(p, UiLang.Zh).All(r => r.RoleKind != "executor"));
        Expect("f2.accepted.history_kept", p.WorkItems.Count > 0);
        Expect("f2.accepted.judgment", details.OverallJudgment == "已完成");
        Expect("f2.accepted.not_reopened", !p.Summary.Contains("正在修正", StringComparison.Ordinal)
                                            && !p.Phase.Contains("正在修正", StringComparison.Ordinal));
    }

    static void AcceptedPackageOwnerContinuesUnfinishedProject()
    {
        var project = "proj-cont-" + Guid.NewGuid().ToString("N")[..8];
        var oldLine = Guid.NewGuid().ToString();
        var oldDirect = Guid.NewGuid().ToString();
        var leadSession = Guid.NewGuid().ToString("N");
        const string handler = "原负责人正在检查本地启动入口，并继续后续接线工作";
        var now = DateTimeOffset.Parse("2026-09-14T11:36:00+08:00");
        var row = new JsonObject
        {
            ["project_id"] = project,
            ["display_name"] = project,
            ["status"] = "ACTIVE",
            ["product_pass"] = false,
            ["current_package_accepted"] = true,
            ["current_summary"] = "上一包已验收并合入；原负责人继续本地启动入口和后续接线，完整产品尚未完成。",
            ["current_handler"] = handler,
            ["remaining"] = "完整产品尚未完成",
            ["lead_thread_id"] = leadSession,
            ["lead_model"] = "gpt-6-astra",
            ["lead_reasoning_effort"] = "xhigh"
        };
        var docs = new[]
        {
            Doc("project_registry", "ACTIVE_PROJECT_REGISTRY.json", now, new JsonObject
            {
                ["projects"] = new JsonArray(row)
            }, project),
            Doc("lead_run", "lead-runs/run/lead-run.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["resume_session_id"] = leadSession,
                ["model"] = "gpt-6-astra",
                ["reasoning_effort"] = "xhigh"
            }, project),
            Doc("cli_lifecycle", "lead-runs/run/cli-drain-lifecycle.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["session_id"] = leadSession,
                ["process_exited"] = false,
                ["native_turn_complete"] = false,
                ["pid"] = 28764
            }, project),
            Doc("line_receipt", "jobs/" + oldLine + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = oldLine,
                ["direct_job_id"] = oldDirect,
                ["route"] = "direct-cursor",
                ["transport_complete"] = true,
                ["command_exit_code"] = 0,
                ["project_judgment"] = false
            }, project),
            Doc("direct_receipt", "jobs/" + oldDirect + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["job_id"] = oldDirect,
                ["line_job_id"] = oldLine,
                ["route"] = "direct-cursor",
                ["transport_complete"] = true,
                ["command_exit_code"] = 0,
                ["project_judgment"] = false
            }, project),
            Doc("bot_acceptance", "LEAD_ACCEPTANCE.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["verdict"] = "PASS",
                ["product_pass"] = true,
                ["current_package_accepted"] = true,
                ["line_job_id"] = oldLine,
                ["direct_job_id"] = oldDirect,
                ["line_receipt"] = new JsonObject { ["path"] = @"C:\jobs\" + oldLine + @"\receipt.json" }
            }, project, scope: "historical")
        };

        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        var hist = RolePresentation.HistoricalRows(p, UiLang.Zh);
        var lead = current.FirstOrDefault(r => r.RoleKind == "lead");
        Expect("cont.visible", CurrentList.IsDefaultCurrent(p));
        Expect("cont.active", p.IsActive);
        Expect("cont.not_folded", details.OverallJudgment != "已完成");
        Expect("cont.overall_moving", details.OverallJudgment == "正常推进");
        Expect("cont.old_exec_history", hist.Any(r => r.Id.Contains(oldLine, StringComparison.Ordinal)
                                                     || r.Id.Contains(oldDirect, StringComparison.Ordinal)));
        Expect("cont.old_exec_not_current", current.All(r => r.RoleKind != "executor"
                                                             || (!r.Id.Contains(oldLine, StringComparison.Ordinal)
                                                                 && !r.Id.Contains(oldDirect, StringComparison.Ordinal))));
        Expect("cont.lead_shows_handler", lead is not null
                                          && (lead.StatusText.Contains("本地启动入口", StringComparison.Ordinal)
                                              || lead.StatusText.Contains("后续接线", StringComparison.Ordinal)));
        Expect("cont.lead_not_unknown", lead is not null
                                        && !lead.StatusText.Contains("未获取", StringComparison.Ordinal)
                                        && !lead.StatusText.Contains("等待负责人处理", StringComparison.Ordinal)
                                        && !lead.StatusText.Contains("等待验收", StringComparison.Ordinal));
        Expect("cont.next_is_handler", (details.NextOwner ?? "").Contains("本地启动入口", StringComparison.Ordinal)
                                        || (details.NextOwner ?? "").Contains("后续接线", StringComparison.Ordinal)
                                        || (p.NextStep ?? "").Contains("本地启动入口", StringComparison.Ordinal));
        Expect("cont.next_not_handled_note", !(details.NextOwner ?? "").StartsWith("已处理", StringComparison.Ordinal)
                                               && !(p.NextStep ?? "").StartsWith("已处理", StringComparison.Ordinal));
    }

    static void FailedRoundHandledIsNotNormalProgress()
    {
        var project = "proj-fail-handled-" + Guid.NewGuid().ToString("N")[..8];
        var oldLine = Guid.NewGuid().ToString();
        var oldDirect = Guid.NewGuid().ToString();
        var leadSession = Guid.NewGuid().ToString("N");
        const string handler = "原负责人正在核对失败原因并准备退修";
        var now = DateTimeOffset.Parse("2026-09-14T12:01:41+08:00");
        var docs = new[]
        {
            Doc("project_registry", "ACTIVE_PROJECT_REGISTRY.json", now, new JsonObject
            {
                ["projects"] = new JsonArray(new JsonObject
                {
                    ["project_id"] = project,
                    ["display_name"] = project,
                    ["status"] = "ACTIVE",
                    ["product_pass"] = false,
                    ["current_package_accepted"] = false,
                    ["current_summary"] = "本轮产品验证未通过；原负责人已接手验收并整理退修。",
                    ["current_handler"] = handler,
                    ["current_state"] = "NATIVE_EFFECT_BOUNDARY_REPAIR_REQUIRED",
                    ["remaining"] = "本轮未通过，需要修复",
                    ["lead_thread_id"] = leadSession,
                    ["lead_model"] = "gpt-6-astra",
                    ["lead_reasoning_effort"] = "xhigh"
                })
            }, project),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = oldLine,
                ["direct_job_id"] = oldDirect,
                ["state"] = "PACKAGE_FAIL_REPAIR_REQUIRED",
                ["product_pass"] = false,
                ["current_package_accepted"] = false,
                ["pending_callback"] = false,
                ["current_handler"] = handler,
                ["current_summary"] = "本轮产品验证未通过；原负责人已接手验收并整理退修。",
                ["executor_route"] = "direct-cursor",
                ["executor_model"] = "cursor-grok-4.6-xhigh"
            }, project),
            Doc("line_receipt", "jobs/" + oldLine + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = oldLine,
                ["direct_job_id"] = oldDirect,
                ["route"] = "direct-cursor",
                ["transport_complete"] = true,
                ["command_exit_code"] = 0,
                ["success"] = false,
                ["failure_code"] = "output_limit",
                ["project_judgment"] = false
            }, project),
            Doc("direct_receipt", "jobs/" + oldDirect + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["job_id"] = oldDirect,
                ["line_job_id"] = oldLine,
                ["route"] = "direct-cursor",
                ["transport_complete"] = true,
                ["command_exit_code"] = 0,
                ["success"] = false,
                ["failure_code"] = "output_limit"
            }, project),
            Doc("lead_run", "lead-runs/run/lead-run.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["resume_session_id"] = leadSession,
                ["model"] = "gpt-6-astra",
                ["reasoning_effort"] = "xhigh",
                ["result"] = "FAIL_REPAIR_REQUIRED"
            }, project)
        };

        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        var lead = current.FirstOrDefault(r => r.RoleKind == "lead");
        Expect("fail.handled.visible", CurrentList.IsDefaultCurrent(p) && p.IsActive);
        Expect("fail.handled.not_green", details.OverallJudgment == "故障/部分异常");
        Expect("fail.handled.not_unknown", details.OverallJudgment != "状态待核实");
        Expect("fail.handled.not_wait_accept", !details.OverallJudgment.Contains("等待验收", StringComparison.Ordinal));
        Expect("fail.handled.impact_kept", (p.Summary ?? "").Contains("未通过", StringComparison.Ordinal)
                                           || (details.HowFar ?? "").Contains("未通过", StringComparison.Ordinal)
                                           || (details.StuckAt ?? "").Contains("未通过", StringComparison.Ordinal)
                                           || (lead?.StatusText ?? "").Contains("退修", StringComparison.Ordinal));
        Expect("fail.handled.lead_has_it", lead is not null
                                           && (lead.StatusText.Contains("退修", StringComparison.Ordinal)
                                               || lead.StatusText.Contains("接手", StringComparison.Ordinal)));
        Expect("fail.handled.no_pascal", details.NeedsPascal.Contains("不需要你处理", StringComparison.Ordinal)
                                          || details.NeedsPascal.Contains("不需", StringComparison.Ordinal));
        Expect("fail.handled.not_running", !p.Phase.Contains("执行中", StringComparison.Ordinal)
                                            && current.All(r => r.RoleKind != "executor"
                                                                 || (!r.StatusText.Contains("正在做", StringComparison.Ordinal)
                                                                     && !r.StatusText.Contains("执行中", StringComparison.Ordinal))));
    }

    static void PreparedCorrectionIsNotRunningStaleRoute() =>
        PreparedStateIsNotRunningStaleRoute("CURSOR_CORRECTION_PREPARED", "prep.");

    static void PreparedForDispatchIsNotRunningStaleRoute() =>
        PreparedStateIsNotRunningStaleRoute("PREPARED_FOR_DISPATCH", "prepfd.");

    static void PreparedStateIsNotRunningStaleRoute(string preparedState, string prefix)
    {
        var project = "proj-prep-" + Guid.NewGuid().ToString("N")[..8];
        var line = Guid.NewGuid().ToString();
        var direct = Guid.NewGuid().ToString();
        var leadSession = Guid.NewGuid().ToString("N");
        const string handler = "原负责人正在准备退修并安排接续";
        var now = DateTimeOffset.Parse("2026-09-14T12:12:32+08:00");
        var docs = new[]
        {
            Doc("project_registry", "ACTIVE_PROJECT_REGISTRY.json", now, new JsonObject
            {
                ["projects"] = new JsonArray(new JsonObject
                {
                    ["project_id"] = project,
                    ["display_name"] = project,
                    ["status"] = "ACTIVE",
                    ["product_pass"] = false,
                    ["current_package_accepted"] = false,
                    ["current_line_job_id"] = null,
                    ["current_direct_job_id"] = null,
                    ["current_state"] = preparedState,
                    ["current_stage"] = preparedState,
                    ["current_summary"] = "本轮产品验证未通过；原负责人已核对失败并准备下一份退修。",
                    ["current_handler"] = handler,
                    ["lead_thread_id"] = leadSession,
                    ["lead_model"] = "gpt-6-astra",
                    ["lead_reasoning_effort"] = "xhigh"
                })
            }, project),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["state"] = preparedState,
                ["executor_route"] = "direct-grok-cli",
                ["executor_model"] = "grok-4.6",
                ["executor_reasoning"] = "xhigh",
                ["package_id"] = "B-INTEGRATION",
                ["direct_state_root"] = @"C:\state\direct-grok",
                ["pending_callback"] = false,
                ["product_pass"] = false,
                ["current_package_accepted"] = false,
                ["current_handler"] = handler,
                ["native_started_this_hop"] = false,
                ["business_execution_started_this_hop"] = false,
                ["new_hop_native_start_observed"] = false
            }, project),
            Doc("lead_run", "lead-runs/run/lead-run.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["resume_session_id"] = leadSession,
                ["model"] = "gpt-6-astra",
                ["reasoning_effort"] = "xhigh"
            }, project)
        };

        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        var current = RolePresentation.CurrentRows(p, UiLang.Zh);
        var lead = current.FirstOrDefault(r => r.RoleKind == "lead");
        var exec = current.FirstOrDefault(r => r.RoleKind == "executor");
        Expect(prefix + "visible", CurrentList.IsDefaultCurrent(p) && p.IsActive);
        Expect(prefix + "not_running_phase", p.Phase.Contains("准备退修", StringComparison.Ordinal)
                                         || p.Phase.Contains("待实际派出", StringComparison.Ordinal)
                                         || p.Phase.Contains("已判退修", StringComparison.Ordinal));
        Expect(prefix + "not_executing_phase", !p.Phase.Contains("执行中", StringComparison.Ordinal));
        Expect(prefix + "not_green", details.OverallJudgment != "正常推进"
                                 && details.OverallJudgment != "状态待核实");
        Expect(prefix + "lead_preparing", lead is not null
                                         && (lead.StatusText.Contains("准备退修", StringComparison.Ordinal)
                                             || lead.StatusText.Contains("待实际派出", StringComparison.Ordinal)
                                             || lead.StatusText.Contains("等待退修", StringComparison.Ordinal)));
        Expect(prefix + "lead_not_waiting_return", lead is not null
                                             && !lead.StatusText.Contains("等待执行者交回", StringComparison.Ordinal));
        Expect(prefix + "no_stale_gege", exec is null
                                       || (!exec.ActorName.Contains("格格", StringComparison.Ordinal)
                                           && (exec.Route is null || exec.Route != "direct-grok-cli")
                                           && !exec.ModelText.Contains("grok-4.6", StringComparison.Ordinal)
                                           && !exec.TaskText.Contains("B-INTEGRATION", StringComparison.Ordinal)
                                           && !exec.StatusText.Contains("正在做", StringComparison.Ordinal)));
    }

    static void PreparedThenActualDispatchUsesRequestIdentity() =>
        PreparedThenActualDispatchUsesRequestIdentity("CURSOR_CORRECTION_PREPARED", "prepgo.");

    static void PreparedForDispatchThenActualDispatchUsesRequestIdentity() =>
        PreparedThenActualDispatchUsesRequestIdentity("PREPARED_FOR_DISPATCH", "prepfdgo.");

    static void PreparedThenActualDispatchUsesRequestIdentity(string leftoverPreparedState, string prefix)
    {
        var project = "proj-prep-go-" + Guid.NewGuid().ToString("N")[..8];
        var line = Guid.NewGuid().ToString();
        var direct = Guid.NewGuid().ToString();
        var now = DateTimeOffset.Parse("2026-09-14T12:13:10+08:00");
        var docs = new[]
        {
            Doc("project_registry", "ACTIVE_PROJECT_REGISTRY.json", now, new JsonObject
            {
                ["projects"] = new JsonArray(new JsonObject
                {
                    ["project_id"] = project,
                    ["display_name"] = project,
                    ["status"] = "ACTIVE",
                    ["product_pass"] = false,
                    ["current_line_job_id"] = line,
                    ["current_direct_job_id"] = direct,
                    ["current_state"] = leftoverPreparedState,
                    ["current_handler"] = "原负责人正在准备退修并安排接续"
                })
            }, project),
            Doc("active_work", "ACTIVE_WORK.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["state"] = leftoverPreparedState,
                ["executor_route"] = "direct-grok-cli",
                ["executor_model"] = "grok-4.6",
                ["package_id"] = "B-INTEGRATION",
                ["pending_callback"] = false,
                ["product_pass"] = false
            }, project),
            Doc("line_dispatch", "jobs/" + line + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor",
                ["executor_model"] = "cursor-grok-4.6-xhigh",
                ["reasoning_effort"] = "xhigh"
            }, project),
            Doc("direct_request", "jobs/" + direct + "/request.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["job_id"] = direct,
                ["line_job_id"] = line,
                ["route"] = "direct-cursor",
                ["model"] = "cursor-grok-4.6-xhigh",
                ["reasoning_effort"] = "xhigh",
                ["protocol_version"] = "direct-cursor-request-v1"
            }, project)
        };

        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        var rows = RolePresentation.CurrentRows(p, UiLang.Zh);
        var exec = rows.FirstOrDefault(r => r.RoleKind == "executor");
        Expect(prefix + "cursor", exec is not null && exec.ActorName.Contains("直达游标", StringComparison.Ordinal));
        Expect(prefix + "not_gege", exec is not null && !exec.ActorName.Contains("格格", StringComparison.Ordinal)
                                   && exec.Route == "direct-cursor");
        Expect(prefix + "model", exec is not null && exec.ModelText.Contains("cursor-grok-4.6-xhigh", StringComparison.Ordinal));
        Expect(prefix + "not_stale_package", exec is not null && !exec.TaskText.Contains("B-INTEGRATION", StringComparison.Ordinal));
    }

    static CockpitSnapshot RoundConversionSnap(DateTimeOffset now, bool accepted)
    {
        const string project = "same-task-next-round";
        const string line = "b56f49fe-a489-4b8f-80be-f6fbdc0aeb79";
        const string direct = "ce61ae2a-1edc-47b2-a57d-02f7c655f198";
        var row = new JsonObject
        {
            ["project_id"] = project,
            ["display_name"] = "Same task, next round",
            ["status"] = accepted ? "COMPLETED" : "ACTIVE",
            ["product_pass"] = accepted,
            ["local_delivered"] = true,
            ["publication_complete"] = true,
            ["current_line_job_id"] = line,
            ["current_direct_job_id"] = direct,
            ["current_package_accepted"] = accepted,
            ["current_summary"] = accepted
                ? "本轮整项已接受"
                : "旧状态问题已修复；本轮新增状态问题结果刚交回，尚未验收",
            ["remaining"] = accepted ? "本轮新增状态问题已验收" : "本轮新增状态问题仍需负责人验收"
        };
        var aw = new JsonObject
        {
            ["project_id"] = project,
            ["line_job_id"] = line,
            ["direct_job_id"] = direct,
            ["state"] = accepted ? "COMPLETE" : "RETURNED_LEAD_ACCEPTANCE",
            ["product_pass"] = accepted,
            ["current_package_accepted"] = accepted,
            ["goal_state"] = accepted ? "complete" : "not_complete",
            ["pending_callback"] = false,
            ["acceptance_pending"] = !accepted,
            ["executor_route"] = "direct-cursor",
            ["executor_model"] = "cursor-grok-4.6-xhigh",
            ["executor_effort"] = "xhigh",
            ["current_handler"] = accepted ? "本轮已接受" : "当前新状态问题等待负责人验收",
            ["remaining"] = new JsonArray(accepted ? "本轮新增状态问题已验收" : "本轮新增状态问题仍需负责人验收"),
            ["local_runtime_delivered"] = true,
            ["publication_complete"] = true
        };
        var docs = new List<RawDocument>
        {
            Doc("project_registry", "registry.json", now, new JsonObject { ["projects"] = new JsonArray(row) }, project),
            Doc("active_work", "ACTIVE_WORK.json", now, aw, project),
            Doc("line_dispatch", "jobs/" + line + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor"
            }, project),
            Doc("line_receipt", "jobs/" + line + "/receipt.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor",
                ["transport_complete"] = true,
                ["command_exit_code"] = 0,
                ["project_judgment"] = false
            }, project)
        };
        if (accepted)
        {
            docs.Add(Doc("bot_acceptance", "LEAD_ACCEPTANCE.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["verdict"] = "PASS",
                ["product_pass"] = true,
                ["formal_product_acceptance"] = true,
                ["current_package_accepted"] = true,
                ["line_receipt"] = new JsonObject { ["path"] = @"C:\jobs\" + line + @"\receipt.json" }
            }, project));
        }

        return Project(docs, now);
    }

    static void PreserveGenerationIsNotContinueGenerating()
    {
        var zh = StatusLanguage.OrdinaryNextFromSource(
            "Same original Lead accepts this Cursor correction02 after callback. Preserve completed 9125-day generation and all accepted evidence; repair only processed-prefix authentication.",
            blocked: false, accepting: false, inFlight: true, returned: false);
        Expect("next.not_continue_gen", !zh.Contains("继续生成", StringComparison.Ordinal));
        Expect("next.auth", zh.Contains("授权", StringComparison.Ordinal) || zh.Contains("验收", StringComparison.Ordinal));
    }

    static void LocalOnlyDeliveryIsNotComplete()
    {
        var now = DateTimeOffset.Parse("2026-09-14T02:18:23Z");
        var snap = BoundarySnap(now, productPass: false, registryStatus: "ACTIVE",
            summary: "telephone pending activate", local: true, published: false,
            state: "WAITING_EXTERNAL", goal: "waiting_external_condition",
            remaining: "telephone pending activate");
        var p = snap.Projects.Single(x => x.Id == "boundary-task");
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        Expect("local.visible", CurrentList.IsDefaultCurrent(p));
        Expect("local.not_both_accepted", !p.Summary.Contains("本机与公开交付已接受", StringComparison.Ordinal));
        Expect("local.not_folded_complete", p.IsActive && !p.Phase.Equals("已完成", StringComparison.Ordinal));
        Expect("local.next_keeps_remaining", (p.NextStep ?? details.NextOwner).Contains("telephone pending activate", StringComparison.OrdinalIgnoreCase)
                                            || (p.Summary ?? "").Contains("telephone pending activate", StringComparison.OrdinalIgnoreCase));
    }

    static void AcceptedStatusFixHistoryIsComplete()
    {
        var now = DateTimeOffset.Parse("2026-09-14T02:18:23Z");
        var snap = BoundarySnap(now, productPass: true, registryStatus: "COMPLETED",
            summary: "三个状态问题已修复并验收", local: true, published: true,
            state: "COMPLETE", goal: "complete", remaining: null);
        var p = snap.Projects.Single(x => x.Id == "boundary-task");
        Expect("done.hidden", !CurrentList.IsDefaultCurrent(p));
        Expect("done.complete_token", p.Summary.Contains("已完成", StringComparison.Ordinal)
                                        || p.Phase.Contains("已完成", StringComparison.Ordinal)
                                        || p.Summary.Contains("已接受", StringComparison.Ordinal));
        Expect("done.not_rework", !p.Summary.Contains("正在修正", StringComparison.Ordinal)
                                    && !p.Phase.Contains("正在修正", StringComparison.Ordinal));
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        Expect("done.next_not_rework", !details.NextOwner.Contains("正在修正", StringComparison.Ordinal));
        Expect("done.history", CurrentList.HistoricalItems(snap).Any(x => x.Id == p.Id));
    }

    static void PublicationStepKeepsGithub()
    {
        var now = DateTimeOffset.Parse("2026-09-14T02:18:23Z");
        var snap = BoundarySnap(now, productPass: false, registryStatus: "ACTIVE",
            summary: "三个状态问题已验收，正在更新 GitHub Latest", local: true, published: false,
            state: "PUBLISHING", goal: "not_complete", remaining: "同步 GitHub Latest");
        var p = snap.Projects.Single(x => x.Id == "boundary-task");
        Expect("pub.visible", CurrentList.IsDefaultCurrent(p));
        Expect("pub.github", p.Summary.Contains("GitHub", StringComparison.Ordinal)
                            || p.Phase.Contains("GitHub", StringComparison.Ordinal)
                            || (p.NextStep ?? "").Contains("GitHub", StringComparison.Ordinal));
        Expect("pub.not_rework", !p.Summary.Contains("正在修正", StringComparison.Ordinal)
                                 && !p.Phase.Contains("正在修正", StringComparison.Ordinal));
    }

    static void PendingCallbackWithoutReceiptIsNotReturned()
    {
        var now = DateTimeOffset.Parse("2026-09-14T02:18:23Z");
        var line = Guid.NewGuid().ToString();
        var direct = Guid.NewGuid().ToString();
        var docs = BoundaryDocs(now, productPass: false, registryStatus: "ACTIVE",
            summary: "本轮执行中", local: false, published: false,
            state: "DISPATCHED_WAITING_ROUTE_RESULT", goal: "not_complete",
            remaining: "执行交回后负责人验收", activeJob: true, line: line, direct: direct);
        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == "boundary-task");
        var exec = RolePresentation.CurrentRows(p, UiLang.Zh)
            .FirstOrDefault(x => x.RoleKind == "executor");
        Expect("f1.visible", CurrentList.IsDefaultCurrent(p));
        Expect("f1.not_returned", exec is not null
                                   && !exec.StatusText.Contains("已交回", StringComparison.Ordinal)
                                   && !exec.StatusText.Contains("正在验收", StringComparison.Ordinal));
        Expect("f1.effort", exec is not null && exec.EffortText.Contains("xhigh", StringComparison.Ordinal));
        var lead = RolePresentation.CurrentRows(p, UiLang.Zh).FirstOrDefault(x => x.RoleKind == "lead");
        Expect("f1.lead_not_accepting", lead is null || !lead.StatusText.Contains("正在验收", StringComparison.Ordinal));
        var details = DetailsPresentation.Build(snap, p.Id, UiLang.Zh);
        Expect("f1.not_wait_accept", !details.OverallJudgment.Contains("等待验收", StringComparison.Ordinal));
    }

    static void UndispatchedRemainingStillShows()
    {
        var project = "proj-undisp-" + Guid.NewGuid().ToString("N")[..8];
        var now = DateTimeOffset.Parse("2026-09-14T09:16:00+08:00");
        var docs = new[]
        {
            Registry(project, "ACTIVE", now, remaining: "后续修正尚未派出", local: false, publication: false,
                summary: "后续修正尚未派出")
        };
        var snap = Project(docs, now);
        var p = snap.Projects.Single(x => x.Id == project);
        Expect("undisp.visible", CurrentList.IsDefaultCurrent(p));
        Expect("undisp.keeps_text", p.Summary.Contains("尚未派出", StringComparison.Ordinal)
                                    || (p.NextStep ?? "").Contains("尚未派出", StringComparison.Ordinal));
    }

    static CockpitSnapshot BoundarySnap(
        DateTimeOffset now, bool productPass, string registryStatus, string summary,
        bool local, bool published, string state, string goal, string? remaining,
        bool activeJob = false, string? line = null, string? direct = null) =>
        Project(BoundaryDocs(now, productPass, registryStatus, summary, local, published, state, goal, remaining, activeJob, line, direct), now);

    static List<RawDocument> BoundaryDocs(
        DateTimeOffset now, bool productPass, string registryStatus, string summary,
        bool local, bool published, string state, string goal, string? remaining,
        bool activeJob, string? line, string? direct)
    {
        const string project = "boundary-task";
        var row = new JsonObject
        {
            ["project_id"] = project,
            ["display_name"] = "Boundary task",
            ["status"] = registryStatus,
            ["product_pass"] = productPass,
            ["current_summary"] = summary,
            ["local_delivered"] = local,
            ["publication_complete"] = published
        };
        if (remaining is not null) row["remaining"] = remaining;
        var aw = new JsonObject
        {
            ["project_id"] = project,
            ["state"] = state,
            ["goal_state"] = goal,
            ["product_pass"] = productPass,
            ["local_runtime_delivered"] = local,
            ["publication_complete"] = published,
            ["current_handler"] = productPass ? "交付完成" : remaining,
            ["remaining"] = remaining is null ? new JsonArray() : new JsonArray(remaining),
            ["next"] = productPass ? null : remaining
        };
        var docs = new List<RawDocument>
        {
            Doc("project_registry", "registry.json", now, new JsonObject { ["projects"] = new JsonArray(row) }, project),
            Doc("active_work", "ACTIVE_WORK.json", now, aw, project)
        };
        if (activeJob)
        {
            line ??= Guid.NewGuid().ToString();
            direct ??= Guid.NewGuid().ToString();
            aw["line_job_id"] = line;
            aw["direct_job_id"] = direct;
            aw["executor_route"] = "direct-cursor";
            aw["executor_model"] = "cursor-grok-4.6-xhigh";
            aw["executor_effort"] = "xhigh";
            aw["pending_callback"] = true;
            aw["acceptance_pending"] = true;
            aw["current_package_accepted"] = false;
            docs.Add(Doc("line_dispatch", "jobs/" + line + "/dispatch.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["line_job_id"] = line,
                ["direct_job_id"] = direct,
                ["route"] = "direct-cursor"
            }, project));
            docs.Add(Doc("direct_request", "jobs/" + direct + "/request.json", now, new JsonObject
            {
                ["project_id"] = project,
                ["job_id"] = direct,
                ["line_job_id"] = line,
                ["route"] = "direct-cursor",
                ["model"] = "cursor-grok-4.6-xhigh",
                ["protocol_version"] = "telephone-line-direct-cursor-request-v1"
            }, project));
        }

        return docs;
    }

    static CockpitSnapshot Project(IReadOnlyList<RawDocument> docs, DateTimeOffset now)
    {
        var facts = new EvidenceNormalizer().Normalize(new CollectionBatch(now, docs, Array.Empty<SourceIssue>()));
        return new StateProjector().Project(facts);
    }

    static RawDocument Registry(string project, string status, DateTimeOffset now, string? remaining, bool local = false, bool publication = false, string? summary = null, bool? productPass = null)
    {
        var row = new JsonObject
        {
            ["project_id"] = project,
            ["display_name"] = project,
            ["status"] = status,
            ["current_summary"] = summary ?? remaining ?? "in flight"
        };
        if (remaining is not null)
            row["remaining"] = remaining;
        if (local) row["local_delivered"] = true;
        if (publication) row["publication_complete"] = true;
        if (productPass is not null) row["product_pass"] = productPass.Value;
        return Doc("project_registry", "ACTIVE_PROJECT_REGISTRY.json", now, new JsonObject
        {
            ["projects"] = new JsonArray { row }
        });
    }

    static RawDocument Doc(string kind, string location, DateTimeOffset at, JsonObject data, string? projectHint = null, string? scope = null) =>
        new(kind + ":" + location, kind, location, data, at, at, projectHint, scope);

    static void Expect(string name, bool ok)
    {
        if (!ok)
        {
            _failed++;
            Console.WriteLine("FAIL " + name);
        }
        else
        {
            Console.WriteLine("ok   " + name);
        }
    }
}
