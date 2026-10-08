using System.Diagnostics;
using System.Reflection;
using System.Text;
using Microsoft.Win32;
using WatchCore;

namespace AIExitWatch;

internal sealed class MainForm : Form
{
    private readonly StateStore store = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AIExitWatch", "state.json"));
    private readonly SavedState state;
    private readonly Detector detector = new();
    private AlertMachine alerts = new();
    private List<Issue> currentIssues = [];
    private Snapshot? latest;
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new();
    private CancellationTokenSource? running;
    private readonly CancellationTokenSource lifetime = new();
    private bool paused, sleeping, busy, quitting;
    private int generation;
    private bool pendingProbe;
    private string? probeError;
    private readonly bool startHidden;
    private readonly Label status = Heading("等待检测", 22), timing = Note("正在准备…"), storage = Note("");
    private readonly Label chain = Note("");
    private readonly DataGridView overview = Grid(), comparison = Grid();
    private readonly TextBox details = Readout(), history = Readout(), lockText = Readout();
    private readonly TabControl tabs = new() { Dock = DockStyle.Fill, Padding = new Point(18, 8) };
    private readonly Button probe = Button("立即检测"), baseline = Button("确认正常基准"), pause = Button("暂停监测");
    private readonly ComboBox interval = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 150 };
    private readonly NumericUpDown threshold = new() { Minimum = 500, Maximum = 60000, Increment = 500, Width = 150 };
    private readonly CheckBox geo = Check("查询中文归属地和 IP 情报（向第三方提交出口 IP）");
    private readonly CheckBox observe = Check("观察 Mihomo 中的 Claude 活动连接链路");
    private readonly CheckBox startup = Check("登录 Windows 时启动（移动应用文件夹后需重新设置）");
    private readonly ComboBox pipe = new() { Width = 440, DropDownStyle = ComboBoxStyle.DropDown };
    private readonly ComboBox landing = new() { Width = 440, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly CheckBox lockClaude = Check("Claude 网页与 API"), lockOpenAI = Check("ChatGPT、OpenAI API / Codex");
    private LockRuntime? lockRuntime;
    private ExitLockPlan? plan;
    private string? planPipe;
    private bool lockBusy;

    public MainForm(bool hidden)
    {
        startHidden = hidden;
        Text = "AI落地安全检测";
        Font = new Font("Microsoft YaHei UI", 10);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(1040, 780);
        MinimumSize = new Size(900, 660);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(245, 247, 250);
        using var iconStream = Assembly.GetExecutingAssembly().GetManifestResourceStream("AIExitWatch.AppIcon.ico")!;
        Icon = new Icon(iconStream);
        state = store.Load();
        interval.Items.AddRange(new object[] { 60, 120, 300, 600 });
        interval.SelectedItem = state.Settings.Interval;
        threshold.Value = state.Settings.SlowMilliseconds;
        geo.Checked = state.Settings.GeoEnabled;
        observe.Checked = state.Settings.ChainEnabled;
        pipe.Text = state.Settings.PipeName;
        try { startup.Checked = SystemInfo.StartupEnabled(); } catch (System.Security.SecurityException) { startup.Enabled = false; }
        lockClaude.Checked = lockOpenAI.Checked = true;

        tray = new NotifyIcon { Icon = Icon, Text = Text, Visible = true };
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开 AI落地安全检测", null, (_, _) => Restore());
        menu.Items.Add("立即检测", null, async (_, _) => { Restore(); await ProbeAsync(); });
        menu.Items.Add("暂停／继续监测", null, async (_, _) => await TogglePause());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Quit());
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => Restore();
        tray.BalloonTipClicked += (_, _) => Restore();

        var shell = Column();
        shell.Padding = new Padding(24, 20, 24, 16);
        shell.Controls.Add(status); shell.Controls.Add(timing); shell.Controls.Add(storage);
        shell.Controls.Add(tabs);
        shell.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        shell.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        shell.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        shell.Controls.Add(Note("观察本应用的网络出口 · 不调用 AI 模型 · 不更改系统代理或 TUN"));
        Controls.Add(shell);
        BuildOverview(); BuildDetails(); BuildComparison(); BuildLock(); BuildSettings(); BuildHistory();
        probe.Click += async (_, _) => await ProbeAsync();
        baseline.Click += (_, _) => ConfirmBaseline();
        pause.Click += async (_, _) => await TogglePause();
        timer.Tick += async (_, _) => { timer.Stop(); await ProbeAsync(); };
        SystemEvents.PowerModeChanged += PowerChanged;
        tabs.SelectedIndexChanged += (_, _) => { if (tabs.SelectedIndex == 1) RenderDetails(); if (tabs.SelectedIndex == 5) RenderHistory(); };
        Shown += async (_, _) => { if (startHidden) Hide(); await ProbeAsync(); };
        FormClosing += (_, e) => { if (!quitting) { e.Cancel = true; Hide(); } };
        FormClosed += (_, _) => {
            SystemEvents.PowerModeChanged -= PowerChanged;
            timer.Dispose(); lifetime.Cancel(); running?.Cancel(); tray.Visible = false; tray.Dispose();
            // 让取消中的请求先退出，避免在仍执行的异步回调中释放共享状态。
        };
        Render();
    }

    private static Label Heading(string text, float size = 14) => new() {
        Text = text, AutoSize = true, Font = new Font("Microsoft YaHei UI", size, FontStyle.Bold),
        ForeColor = Color.FromArgb(29, 43, 61), Margin = new Padding(0, 0, 0, 12)
    };
    private static Label Note(string text) => new() {
        Text = text, AutoSize = true, MaximumSize = new Size(930, 0), ForeColor = Color.FromArgb(80, 94, 110),
        Margin = new Padding(0, 0, 0, 10), UseMnemonic = false
    };
    private static Button Button(string text) => new() {
        Text = text, AutoSize = true, MinimumSize = new Size(100, 36), Padding = new Padding(10, 3, 10, 3),
        Margin = new Padding(0, 0, 10, 10), UseVisualStyleBackColor = true
    };
    private static CheckBox Check(string text) => new() { Text = text, AutoSize = true, Margin = new Padding(0, 8, 12, 12) };
    private static TextBox Readout() => new() {
        Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill,
        BackColor = Color.White, BorderStyle = BorderStyle.FixedSingle, WordWrap = true
    };
    private static TableLayoutPanel Column() => new() {
        Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 0, GrowStyle = TableLayoutPanelGrowStyle.AddRows
    };
    private static FlowLayoutPanel Flow(params Control[] controls)
    {
        var p = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = true, Margin = new Padding(0, 8, 0, 0) };
        p.Controls.AddRange(controls); return p;
    }
    private TableLayoutPanel Page(string title)
    {
        var page = new TabPage(title) { BackColor = Color.White, Padding = new Padding(20) };
        var column = Column(); page.Controls.Add(column); tabs.TabPages.Add(page); return column;
    }
    private static DataGridView Grid() => new() {
        Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false,
        AllowUserToResizeRows = false, RowHeadersVisible = false, MultiSelect = false,
        SelectionMode = DataGridViewSelectionMode.FullRowSelect, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
        BackgroundColor = Color.White, BorderStyle = BorderStyle.None, GridColor = Color.FromArgb(231, 236, 242),
        AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells, ColumnHeadersHeight = 40,
        DefaultCellStyle = new DataGridViewCellStyle { Padding = new Padding(6, 12, 6, 12), WrapMode = DataGridViewTriState.True,
            SelectionBackColor = Color.FromArgb(228, 241, 250), SelectionForeColor = Color.FromArgb(29, 43, 61) }
    };
    private static void Columns(DataGridView grid, params string[] names)
    {
        foreach (var name in names) grid.Columns.Add(name, name);
    }
    private void BuildOverview()
    {
        var p = Page("出口概览");
        Columns(overview, "检测目标", "出口 IP", "地区", "延迟 / 状态");
        p.Controls.Add(overview); p.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        p.Controls.Add(Heading("Mihomo 链路观察", 11)); p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        p.Controls.Add(chain); p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        p.Controls.Add(Flow(probe, baseline, pause)); p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var browser = Button("查看 Claude 登录环境检测");
        browser.Click += (_, _) => OpenBrowser();
        p.Controls.Add(Flow(browser));
        p.Controls.Add(Note("浏览器若使用独立代理或按进程分流，出口可能与本工具不同。首次结果须由你确认正常后设为基准。"));
    }
    private void BuildDetails()
    {
        var p = Page("出口详情");
        p.Controls.Add(details); p.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var refresh = Button("刷新本机 IPv6 状态");
        refresh.Click += (_, _) => RenderDetails();
        p.Controls.Add(Flow(refresh)); p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
    }
    private void BuildComparison()
    {
        var p = Page("多出口对照");
        p.Controls.Add(Note("国内、海外、Cloudflare 是参考来源，不能代表所有同类网站。分流导致不同 IP 可能正常；参考结果不参与基准告警。"));
        p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        Columns(comparison, "来源 / 目标", "出口 IP", "归属地 / 状态", "延迟");
        p.Controls.Add(comparison); p.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        p.Controls.Add(Note("来源：ip.3322.net · checkip.amazonaws.com · www.cloudflare.com/cdn-cgi/trace\nGoogle 出口尚未接入可靠来源。所有请求沿用本机网络设置。"));
        p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
    }
    private void BuildSettings()
    {
        var p = Page("设置");
        p.AutoScroll = true;
        p.Controls.Add(Heading("监测与通知"));
        p.Controls.Add(Flow(Note("检测间隔（秒）"), interval, Note("延迟阈值（毫秒）"), threshold));
        p.Controls.Add(geo);
        p.Controls.Add(Note("开启后将探测到的 IP 提交给 ipwho.is 和 api.ipquery.io；成功结果与失败冷却均为 15 分钟。不查询账号信息。"));
        p.Controls.Add(observe);
        var discover = Button("查找管道");
        discover.Click += (_, _) => {
            var names = SystemInfo.Pipes(); pipe.Items.Clear(); pipe.Items.AddRange(names);
            if (names.Length == 1) pipe.Text = names[0];
            Info(names.Length == 0 ? "未找到 Mihomo 管道。请先运行代理软件，或填写其本机命名管道。不会自动开启控制器。" :
                "已列出本机 Mihomo 管道，请确认属于你当前使用的代理实例。");
        };
        p.Controls.Add(Flow(Note("本机管道"), pipe, discover));
        p.Controls.Add(Note(@"支持本机命名管道，如 \\.\pipe\verge-mihomo。无需开启 TCP 控制器；不支持的代理软件仍可使用出口检测。"));
        p.Controls.Add(startup);
        Button save = Button("保存设置"), test = Button("发送测试通知");
        save.Click += async (_, _) => await SaveSettingsAsync();
        test.Click += (_, _) => Notify("AI落地安全检测 · 测试通知", "通知通道已调用。真实异常连续两次确认后提醒。");
        p.Controls.Add(Flow(save, test));
        p.Controls.Add(Note("Windows 通知设置、勿扰模式、共享屏幕和任务栏设置可能影响横幅。关闭主窗口后继续在托盘监测，退出或休眠期间不监测。"));
        p.Controls.Add(Note("本地设置、基准与最近 1,440 次检测 / 500 条事件保存在：\n" + store.Path));
    }
    private void BuildHistory()
    {
        var p = Page("历史");
        p.Controls.Add(history);
        p.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        p.Controls.Add(Note("仅保存在当前 Windows 用户的本地数据目录，不随分享包带走。通知不包含 IP 或节点名称。"));
    }
    private void BuildLock()
    {
        var p = Page("出口锁定");
        p.Controls.Add(Note("选择固定落地节点，导出保护脚本后手动导入 Clash Verge Rev。导出文件不代表保护已生效。"));
        p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        Button read = Button("读取固定节点"), export = Button("导出保护脚本…"), verify = Button("检查生效情况");
        read.Click += async (_, _) => await LockAction(async token => {
            using var reader = new Mihomo(state.Settings.PipeName);
            lockRuntime = await reader.RuntimeAsync(token);
            var names = lockRuntime.Candidates;
            landing.Items.Clear(); landing.Items.AddRange(names.Cast<object>().ToArray());
            if (names.Count > 0) landing.SelectedIndex = 0;
            UpdatePlan();
            if (names.Count == 0) lockText.Text = "未找到前置关系明确的固定物理节点。不会选用 DIRECT 或自动切换组。";
        });
        landing.SelectedIndexChanged += (_, _) => UpdatePlan();
        lockClaude.CheckedChanged += (_, _) => UpdatePlan();
        lockOpenAI.CheckedChanged += (_, _) => UpdatePlan();
        export.Click += (_, _) => ExportPlan();
        verify.Click += async (_, _) => await LockAction(async token => {
            var expected = plan ?? throw new InvalidDataException("请先读取并选择固定节点。");
            var expectedPipe = planPipe!;
            using var reader = new Mihomo(expectedPipe);
            var result = expected.Verify(await reader.RuntimeAsync(token));
            if (!ReferenceEquals(plan, expected) || planPipe != expectedPipe) return;
            lockText.Text = $"核验时间：{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss}\r\n{result.Status}：{result.Message}\r\n\r\n{LockInstructions(expected)}";
        });
        p.Controls.Add(Flow(read, landing)); p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        p.Controls.Add(Flow(lockClaude, lockOpenAI)); p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        p.Controls.Add(lockText); p.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        p.Controls.Add(Flow(export, verify)); p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        lockText.Text = "使用“设置”中已保存的本机 Mihomo 管道。这里只读节点和规则，不会修改或重启代理。";
    }

    private void UpdatePlan()
    {
        plan = null; planPipe = null;
        if (lockRuntime == null || landing.SelectedItem is not string name) return;
        try {
            plan = new(lockRuntime, name, lockClaude.Checked, lockOpenAI.Checked);
            planPipe = state.Settings.PipeName;
            lockText.Text = LockInstructions(plan);
        } catch (InvalidDataException ex) { lockText.Text = ex.Message; }
    }
    private static string LockInstructions(ExitLockPlan selected) =>
        "尚未确认生效\r\n" + selected.Path + "\r\n\r\n保护域名：" + string.Join("、", selected.Domains) +
        "\r\n\r\n1. 先备份 Clash Verge Rev 当前订阅扩展脚本。\r\n2. 将导出文件的完整 BEGIN / END 区块追加到脚本末尾；更新时替换旧区块，不覆盖原有链路脚本。\r\n3. 保存并应用订阅，保持规则模式。\r\n4. 重新打开 AI 页面或客户端，再点击“检查生效情况”。\r\n\r\n" +
        "固定节点失败即连接失败；节点不支持 UDP 时由相邻 REJECT 拦截。节点缺失、类型或前置关系改变则拒绝。\r\n" +
        "只保护经过 Mihomo 规则模式、匹配上述域名的新连接。不是系统级断网开关，不能阻止绕过代理的 DNS、WebRTC、IPv6；不能阻止同名节点自身的出口 IP 变化。OpenAI 范围包括 API / Codex。\r\n\r\n" +
        "撤销：只移除该 BEGIN / END 区块并手动重新应用订阅。核验仅反映读取时刻的配置，不持续保证全部流量。";
    private async Task LockAction(Func<CancellationToken, Task> action)
    {
        if (lockBusy) return;
        lockBusy = true;
        try { await action(lifetime.Token); }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception ex) when (ExpectedError(ex)) { if (!quitting) { lockText.Text = "未确认生效：读取失败，请检查 Mihomo 管道和代理运行状态。"; Info("Mihomo 读取失败：" + Detector.Explain(ex)); } }
        finally { lockBusy = false; }
    }
    private void ExportPlan()
    {
        if (lockBusy) { Info("请等当前节点读取或核验完成后再导出。"); return; }
        var selected = plan;
        var selectedPipe = planPipe;
        if (selected == null) { Info("请先读取并选择固定节点。"); return; }
        using var dialog = new SaveFileDialog { Filter = "JavaScript 保护脚本|*.js", FileName = "AI出口锁定.js", OverwritePrompt = true };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        if (quitting || lockBusy || !ReferenceEquals(plan, selected) || planPipe != selectedPipe)
        { Info("方案已变化，未写入文件。请重新确认节点后导出。"); return; }
        try { File.WriteAllText(dialog.FileName, selected.Script(), new UTF8Encoding(false)); Info("保护脚本已导出，尚未导入代理或确认生效。请按页面步骤手动操作。"); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Info("文件无法保存，请选择可写目录。"); }
    }

    private async Task ProbeAsync()
    {
        if (quitting || paused || sleeping) return;
        if (busy) { pendingProbe = true; return; }
        timer.Stop();
        busy = true; pendingProbe = false;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        running = cancellation;
        var epoch = generation;
        Render();
        try
        {
            var sample = await detector.ProbeAsync(state.Settings, cancellation.Token);
            if (epoch != generation || quitting || cancellation.IsCancellationRequested) return;
            latest = sample; probeError = null;
            currentIssues = Comparison.Issues(sample, state.Baseline, state.Settings);
            var events = alerts.Consume(currentIssues);
            state.Samples.Add(sample);
            if (state.Samples.Count > 1440) state.Samples.RemoveRange(0, state.Samples.Count - 1440);
            state.Events.AddRange(events);
            if (state.Events.Count > 500) state.Events.RemoveRange(0, state.Events.Count - 500);
            store.Save(state);
            foreach (var e in events) Notify(e.Title, "检测状态有变化，请打开应用查看详情。");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception ex) when (ExpectedError(ex))
        {
            if (!quitting) {
                latest = null; currentIssues = [];
                probeError = "检测未完成：" + Detector.Explain(ex);
            }
        }
        finally
        {
            busy = false; running = null;
            if (!quitting) {
                Render();
                if (!paused && !sleeping) { timer.Interval = pendingProbe ? 100 : state.Settings.Interval * 1000; timer.Start(); }
            }
        }
    }
    private async Task TogglePause()
    {
        paused = !paused;
        InvalidateProbe();
        if (!paused) { pendingProbe = true; await ProbeAsync(); }
        Render();
    }
    private void InvalidateProbe()
    {
        generation++; timer.Stop(); running?.Cancel(); alerts.ResetPending();
    }
    private void PowerChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (quitting || !IsHandleCreated) return;
        BeginInvoke((Action)(async () => {
            if (quitting) return;
            if (e.Mode == PowerModes.Suspend) { sleeping = true; InvalidateProbe(); }
            if (e.Mode == PowerModes.Resume) { sleeping = false; pendingProbe = true; await ProbeAsync(); }
            Render();
        }));
    }
    private void ConfirmBaseline()
    {
        var candidate = latest;
        var epoch = generation;
        if (busy || paused || sleeping || candidate == null || !candidate.CanBaseline(state.Settings)) { Info("当前三项 AI 检测、归属地或启用的链路数据不完整，不能设置基准。"); return; }
        var summary = string.Join("\n", candidate.Endpoints.Select(e => e.Host + "：" + e.IP));
        if (MessageBox.Show(this, $"请确认以下出口和当前链路符合预期：\n{summary}\n\n将以 {candidate.Date:HH:mm:ss} 的结果作为正常基准，并清除已有告警状态。", Text,
                MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK) return;
        // 模态窗口仍泵异步回调，不能把确认期间的新样本当成用户批准的基准。
        if (quitting || busy || paused || sleeping || epoch != generation || !ReferenceEquals(latest, candidate) ||
            !candidate.CanBaseline(state.Settings))
        { Info("检测状态已更新，未更改基准。请查看最新结果后重新确认。"); return; }
        state.Baseline = candidate; alerts = new(); currentIssues = Comparison.Issues(candidate, state.Baseline, state.Settings);
        store.Save(state); Render();
    }
    private async Task SaveSettingsAsync()
    {
        if (lockBusy) { Info("请等当前 Mihomo 读取完成后保存设置。"); return; }
        try
        {
            var updated = new Settings((int)interval.SelectedItem!, (int)threshold.Value, geo.Checked, observe.Checked, Mihomo.NormalizePipe(pipe.Text));
            updated.Validate();
            var sourceChanged = updated.GeoEnabled != state.Settings.GeoEnabled || updated.ChainEnabled != state.Settings.ChainEnabled ||
                (updated.PipeName != state.Settings.PipeName && (updated.ChainEnabled || state.Settings.ChainEnabled));
            if (sourceChanged && state.Baseline != null && MessageBox.Show(this,
                "更改检测来源需要重新确认基准。保存后会清除旧基准，是否继续？", Text, MessageBoxButtons.OKCancel) != DialogResult.OK) return;
            SystemInfo.SetStartup(startup.Checked);
            InvalidateProbe();
            if (sourceChanged) { state.Baseline = null; alerts = new(); }
            state.Settings = updated; latest = null; probeError = null; currentIssues = [];
            lockRuntime = null; landing.Items.Clear(); plan = null; planPipe = null; lockText.Text = "设置已更新，请重新读取固定节点。";
            store.Save(state);
            Render();
            pendingProbe = true; await ProbeAsync();
        }
        catch (Exception ex) when (ExpectedError(ex)) { Info("设置未能完成保存：" + (ex is ArgumentException or InvalidDataException ? ex.Message : "请检查用户权限。")); }
    }
    private void Render()
    {
        if (quitting) return;
        var isUnknown = latest == null;
        status.Text = paused ? "监测已暂停" : sleeping ? "系统休眠中" : isUnknown ? (busy ? "正在检测…" : probeError ?? "等待检测") :
            alerts.Active.Count > 0 ? $"发现 {alerts.Active.Count} 项持续异常" :
            currentIssues.Count > 0 ? "发现偏离 · 等待连续确认" : state.Baseline == null ? "检测完成 · 尚未确认基准" : "与基准一致";
        status.ForeColor = paused ? Color.Gray : alerts.Active.Count > 0 ? Color.FromArgb(181, 48, 51) :
            currentIssues.Count > 0 || state.Baseline == null ? Color.FromArgb(150, 100, 24) : Color.FromArgb(20, 122, 104);
        timing.Text = (latest == null ? "尚无本次运行的完整检测结果" : $"上次检测 {latest.Date:HH:mm:ss}") +
            $" · 每轮完成后间隔 {state.Settings.Interval} 秒" + (busy && latest != null ? " · 正在更新…" : "");
        storage.Text = store.Error ?? ""; storage.ForeColor = Color.DarkRed;
        storage.Visible = store.Error != null;
        probe.Enabled = !busy && !paused && !sleeping;
        baseline.Enabled = !busy && !paused && !sleeping && latest?.CanBaseline(state.Settings) == true;
        baseline.Text = state.Baseline == null ? "确认正常基准" : "更新基准…";
        pause.Text = paused ? "继续监测" : "暂停监测";
        tray.Text = "AI落地安全检测 · " + (paused ? "已暂停" : alerts.Active.Count > 0 ? "有异常" : "监测中");
        FillGrid(overview, Target.AI);
        FillGrid(comparison, Target.AI.Concat(Target.References));
        chain.Text = !state.Settings.ChainEnabled ? "未启用。可在设置中接入本机 Mihomo，只读观察，不改变代理配置。" :
            latest?.ChainPath ?? latest?.ChainError ?? "等待观察活动连接。";
        if (tabs.SelectedIndex == 1) RenderDetails();
        if (tabs.SelectedIndex == 5) RenderHistory();
    }
    private void FillGrid(DataGridView grid, IEnumerable<Target> targets)
    {
        grid.Rows.Clear();
        foreach (var target in targets)
        {
            var e = latest?.Endpoints.Concat(latest.References).FirstOrDefault(e => e.Host == target.Host);
            Geo? geoInfo = null;
            if (e?.IP != null) latest!.Geo.TryGetValue(e.IP, out geoInfo);
            grid.Rows.Add(target.Name, e?.IP ?? "未知", e?.Error ?? geoInfo?.Place ?? Presentation.Country(e?.Country),
                e?.Milliseconds is int ms ? $"{ms} ms" : latest == null ? "等待检测" : "未获取");
        }
        grid.ClearSelection();
    }
    private void RenderDetails()
    {
        StringBuilder b = new();
        b.AppendLine(latest == null ? "等待出口检测。" : $"检测时间：{latest.Date:yyyy-MM-dd HH:mm:ss}").AppendLine();
        foreach (var t in Target.AI)
        {
            var e = latest?.Endpoints.Find(e => e.Host == t.Host);
            b.AppendLine(t.Name + " · " + (e?.IP ?? "未知"));
            if (e?.Error != null) b.AppendLine(e.Error);
            else if (e?.IP != null)
            {
                if (latest!.Geo.TryGetValue(e.IP, out var g))
                {
                    b.AppendLine($"归属地：{g.Place}  邮编：{g.Postal ?? "未知"}");
                    b.AppendLine($"AS{g.ASN} · {g.ISP}\r\n出口时区：{g.Timezone ?? "未知"}");
                    if (g.Timezone != null)
                    {
                        try {
                            var tz = TimeZoneInfo.FindSystemTimeZoneById(g.Timezone);
                            var difference = tz.GetUtcOffset(DateTimeOffset.Now) - TimeZoneInfo.Local.GetUtcOffset(DateTimeOffset.Now);
                            b.AppendLine($"与本机时差：{difference.TotalHours:+0.##;-0.##;0} 小时");
                        } catch (Exception ex) when (ex is TimeZoneNotFoundException or InvalidTimeZoneException) { b.AppendLine("出口时区偏移未知。"); }
                    }
                }
                else b.AppendLine(state.Settings.GeoEnabled ? latest.GeoErrors.GetValueOrDefault(e.IP, "归属地未知") : "归属地 / 情报查询已关闭。");
                if (latest.Risks.TryGetValue(e.IP, out var r))
                    b.AppendLine($"VPN：{Presentation.Flag(r.VPN)}   代理：{Presentation.Flag(r.Proxy)}   Tor：{Presentation.Flag(r.Tor)}\r\n机房：{Presentation.Flag(r.Datacenter)}   移动网络：{Presentation.Flag(r.Mobile)}");
                else if (state.Settings.GeoEnabled) b.AppendLine("IP 情报：" + latest.RiskErrors.GetValueOrDefault(e.IP, "未知"));
            }
            b.AppendLine();
        }
        b.AppendLine("情报库未标记不代表住宅 IP、安全或平台认可。归属地为大致位置，不提供街道门牌。爬虫 / 滥用记录未接入。").AppendLine();
        b.AppendLine($"本机时区：{TimeZoneInfo.Local.DisplayName}\r\n系统语言：{Program.SystemLanguage}");
        b.AppendLine("系统语言不代表浏览器语言；时区或语言不同本身不触发告警。").AppendLine();
        b.AppendLine("本机 IPv6 · " + DateTimeOffset.Now.ToString("HH:mm:ss")).AppendLine(SystemInfo.IPv6());
        b.AppendLine().AppendLine("登录前检查：保持落地 IP 干净；关闭 IPv6；DNS 正常无泄露；关闭 WebRTC。请在实际登录 Claude 的浏览器中检查。此提示不代表以上项目已通过。");
        details.Text = b.ToString().Replace("\r\n", "\n").Replace("\n", "\r\n");
    }
    private void RenderHistory()
    {
        var lines = state.Events.AsEnumerable().Reverse().Select(e => $"{e.Date:yyyy-MM-dd HH:mm:ss}  {e.Title}\r\n{e.Message}\r\n");
        var samples = state.Samples.TakeLast(50).Reverse().Select(s =>
            $"{s.Date:yyyy-MM-dd HH:mm:ss}  " + string.Join("  |  ", s.Endpoints.Select(e => e.Host + "：" + (e.IP ?? e.Error))));
        history.Text = "告警事件（最近 500 条）\r\n\r\n" + string.Join("\r\n", lines) +
            "\r\n\r\n最近 50 次检测（本地最多保留 1,440 次）\r\n\r\n" + string.Join("\r\n", samples);
    }
    private void Notify(string title, string message) { if (!quitting) tray.ShowBalloonTip(8000, title, message, ToolTipIcon.Info); }
    private void Restore() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    private void Quit() { quitting = true; lifetime.Cancel(); InvalidateProbe(); Close(); }
    private void Info(string message) { if (!quitting) MessageBox.Show(this, message, Text, MessageBoxButtons.OK, MessageBoxIcon.Information); }
    private void OpenBrowser()
    {
        if (MessageBox.Show(this, "请在实际登录 Claude 的浏览器中检查：\n\n• 保持落地 IP 干净\n• 关闭 IPv6\n• DNS 正常无泄露\n• 关闭 WebRTC\n\n将打开 Net.Coffee 第三方检测网页。应用未验证上述项目已通过。", "浏览器登录环境",
            MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK) return;
        try { Process.Start(new ProcessStartInfo("https://ip.net.coffee/claude/") { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { Info("无法打开默认浏览器，请手动访问 https://ip.net.coffee/claude/"); }
    }
    private static bool ExpectedError(Exception ex) => ex is IOException or InvalidDataException or HttpRequestException or ArgumentException or
        InvalidOperationException or System.Text.Json.JsonException or UnauthorizedAccessException or OperationCanceledException or
        System.Security.SecurityException or KeyNotFoundException or FormatException or OverflowException;
}
