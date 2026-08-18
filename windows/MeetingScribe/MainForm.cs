using System.Diagnostics;
using NAudio.MediaFoundation;
using NAudio.Wave;

namespace MeetingScribe;

public sealed class MainForm : Form
{
    private readonly ComboBox _mode = new();
    private readonly Label _status = new();
    private readonly TextBox _live = new();
    private readonly Button _primary = new();
    private readonly LinkLabel _openFolder = new();
    private readonly System.Windows.Forms.Timer _tick = new() { Interval = 1000 };
    private readonly System.Windows.Forms.Timer _liveTick = new() { Interval = 6000 };

    private readonly Transcriber _transcriber = new();
    private AudioCapture? _capture;
    private CancellationTokenSource? _cts;
    private DateTime _startedAt;
    private bool _liveRunning;
    private bool _busy;
    private string? _resultPath;

    public MainForm()
    {
        Text = "MeetingScribe";
        ClientSize = new Size(460, 430);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Malgun Gothic", 9F);

        var title = new Label
        {
            Text = "MeetingScribe",
            Font = new Font("Malgun Gothic", 15F, FontStyle.Bold),
            AutoSize = true, Location = new Point(20, 16),
        };
        var subtitle = new Label
        {
            Text = "회의·강의를 녹음해 회의록으로 만듭니다",
            ForeColor = SystemColors.GrayText,
            AutoSize = true, Location = new Point(22, 46),
        };

        _mode.DropDownStyle = ComboBoxStyle.DropDownList;
        _mode.Items.AddRange(new object[] { "회의", "강의" });
        _mode.SelectedIndex = 0;
        _mode.Location = new Point(20, 76);
        _mode.Width = 120;

        _status.Text = "준비됨";
        _status.AutoSize = false;
        _status.Location = new Point(160, 79);
        _status.Size = new Size(280, 20);
        _status.TextAlign = ContentAlignment.MiddleRight;

        _live.Multiline = true;
        _live.ReadOnly = true;
        _live.ScrollBars = ScrollBars.Vertical;
        _live.Location = new Point(20, 112);
        _live.Size = new Size(420, 92);              // 대략 3~4줄
        _live.Font = new Font("Consolas", 9F);
        _live.BackColor = Color.White;
        _live.Text = "녹음을 시작하면 받아적는 내용이 여기에 표시됩니다.";

        _primary.Text = "녹음 시작";
        _primary.Location = new Point(20, 218);
        _primary.Size = new Size(420, 40);
        _primary.Click += OnPrimaryClick;

        _openFolder.Text = "저장 폴더 열기";
        _openFolder.Location = new Point(20, 268);
        _openFolder.AutoSize = true;
        _openFolder.LinkClicked += (_, _) => OpenPath(Pipeline.LibraryRoot);

        var note = new Label
        {
            Text = "결과는 문서 > MeetingScribe 폴더에 저장됩니다.\n"
                 + "요약에는 Claude Code CLI 로그인이 필요합니다.",
            ForeColor = SystemColors.GrayText,
            AutoSize = false,
            Location = new Point(20, 300),
            Size = new Size(420, 40),
        };

        Controls.AddRange(new Control[] { title, subtitle, _mode, _status, _live, _primary, _openFolder, note });

        _tick.Tick += (_, _) => UpdateElapsed();
        _liveTick.Tick += async (_, _) => await RefreshLiveAsync();

        // 모델은 녹음과 무관하게 미리 받아둔다. 없으면 라이브 자막만 늦게 뜬다.
        _ = Task.Run(async () =>
        {
            try
            {
                await _transcriber.EnsureModelAsync(new Progress<string>(SetStatusSafe));
                SetStatusSafe("준비됨");
            }
            catch (Exception ex) { SetStatusSafe($"모델 준비 실패: {ex.Message}"); }
        });
    }

    private Mode SelectedMode => _mode.SelectedIndex == 1 ? Mode.Lecture : Mode.Meeting;

    private void SetStatusSafe(string text)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { BeginInvoke(() => _status.Text = text); return; }
        _status.Text = text;
    }

    private void UpdateElapsed()
    {
        var t = DateTime.Now - _startedAt;
        _status.Text = $"녹음 중 — {(int)t.TotalMinutes:00}:{t.Seconds:00}";
    }

    private async void OnPrimaryClick(object? sender, EventArgs e)
    {
        if (_busy) return;

        if (_capture is null && _resultPath is null)         { StartRecording(); return; }
        if (_capture is not null)                            { await StopAndProcessAsync(); return; }
        Reset();
    }

    private void StartRecording()
    {
        try
        {
            var dir = Path.Combine(Pipeline.LibraryRoot, DateTime.Now.ToString("yyyyMMdd-HHmmss"));
            _capture = new AudioCapture(dir);
            _capture.Start();

            _live.Clear();
            _startedAt = DateTime.Now;
            _tick.Start();
            _liveTick.Start();
            _mode.Enabled = false;
            _primary.Text = "중지하고 문서 만들기";

            if (_capture.SystemError is not null)
                AppendLive($"[알림] 시스템 오디오를 잡지 못했습니다: {_capture.SystemError}");
            if (_capture.MicError is not null)
                AppendLive($"[알림] 마이크를 잡지 못했습니다: {_capture.MicError}");
        }
        catch (Exception ex)
        {
            _capture = null;
            MessageBox.Show(this, ex.Message, "녹음을 시작하지 못했습니다",
                            MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    /// <summary>녹음 중 파일 끝 25초만 전사해 자막을 갱신한다.</summary>
    private async Task RefreshLiveAsync()
    {
        if (_capture is null || _liveRunning || !_transcriber.ModelReady) return;
        _liveRunning = true;
        try
        {
            var tracks = new List<(string, List<Segment>)>();
            foreach (var (path, speaker) in new[] { (_capture.MicPath, "나"), (_capture.SystemPath, "상대") })
            {
                if (!File.Exists(path)) continue;
                var segs = await _transcriber.TranscribeAsync(path, tailSeconds: 25);
                if (segs.Count > 0) tracks.Add((speaker, segs));
            }
            var lines = Pipeline.FormatLive(tracks);
            if (lines.Count > 0) SetLive(lines.TakeLast(12));
        }
        catch { /* 라이브 자막 실패는 녹음을 방해하지 않는다 */ }
        finally { _liveRunning = false; }
    }

    private async Task StopAndProcessAsync()
    {
        if (_capture is null) return;
        _busy = true;
        _tick.Stop(); _liveTick.Stop();
        _primary.Enabled = false;
        _primary.Text = "처리 중…";

        var capture = _capture;
        var mode = SelectedMode;
        _cts = new CancellationTokenSource();

        try
        {
            capture.Stop();
            _capture = null;

            SetStatusSafe("전사 중…");
            var tracks = new List<(string, List<Segment>)>();
            foreach (var (path, speaker) in new[] { (capture.MicPath, "나"), (capture.SystemPath, "상대") })
            {
                if (!File.Exists(path) || new FileInfo(path).Length <= 44) continue;
                var segs = await _transcriber.TranscribeAsync(
                    path, null, new Progress<string>(SetStatusSafe), _cts.Token);
                if (segs.Count > 0) tracks.Add((speaker, segs));
            }

            var transcript = Pipeline.Merge(tracks);
            if (string.IsNullOrWhiteSpace(transcript))
                throw new InvalidOperationException("인식된 내용이 없습니다. 녹음 레벨을 확인해 주세요.");

            await File.WriteAllTextAsync(Path.Combine(capture.Directory, "전사문.md"), transcript, _cts.Token);

            SetStatusSafe($"{mode.Label()} 문서 작성 중…");
            var document = await Pipeline.SummarizeAsync(transcript, mode, "claude-sonnet-5", _cts.Token);

            var outPath = Path.Combine(capture.Directory, mode.OutputName());
            await File.WriteAllTextAsync(outPath, document, _cts.Token);
            _resultPath = outPath;

            var saved = Compress(capture.Directory);
            SetStatusSafe(saved is null ? "완료" : $"완료 — 녹음 {saved}");
            _primary.Text = "결과 열기";
        }
        catch (Exception ex)
        {
            SetStatusSafe("실패");
            MessageBox.Show(this, ex.Message, "처리 중 문제가 생겼습니다",
                            MessageBoxButtons.OK, MessageBoxIcon.Warning);
            _primary.Text = "새 녹음";
        }
        finally
        {
            _busy = false;
            _primary.Enabled = true;
            _mode.Enabled = true;
        }
    }

    /// <summary>WAV 를 AAC(.m4a)로 줄이고 원본을 지운다. 16kHz 모노 PCM 은 시간당 115MB 다.</summary>
    private static string? Compress(string directory)
    {
        long before = 0, after = 0;
        try { MediaFoundationApi.Startup(); } catch { return null; }

        foreach (var wav in Directory.GetFiles(directory, "*.wav"))
        {
            var size = new FileInfo(wav).Length;
            before += size;
            var m4a = Path.ChangeExtension(wav, ".m4a");
            try
            {
                using (var reader = new WaveFileReader(wav))
                    MediaFoundationEncoder.EncodeToAac(reader, m4a, 32_000);
                after += new FileInfo(m4a).Length;
                File.Delete(wav);                       // 변환 성공 후에만 지운다
            }
            catch { after += size; }                    // 실패하면 WAV 를 그대로 남긴다
        }
        if (before == 0) return null;
        return $"{before / 1048576.0:F1}MB → {after / 1048576.0:F1}MB";
    }

    private void AppendLive(string line)
    {
        if (InvokeRequired) { BeginInvoke(() => AppendLive(line)); return; }
        _live.AppendText((_live.TextLength > 0 ? Environment.NewLine : "") + line);
        ScrollLiveToEnd();
    }

    private void SetLive(IEnumerable<string> lines)
    {
        if (InvokeRequired) { BeginInvoke(() => SetLive(lines)); return; }
        _live.Text = string.Join(Environment.NewLine, lines);
        ScrollLiveToEnd();
    }

    private void ScrollLiveToEnd()
    {
        _live.SelectionStart = _live.TextLength;
        _live.ScrollToCaret();
    }

    private void Reset()
    {
        _resultPath = null;
        _live.Clear();
        _live.Text = "녹음을 시작하면 받아적는 내용이 여기에 표시됩니다.";
        _status.Text = "준비됨";
        _primary.Text = "녹음 시작";
    }

    private static void OpenPath(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? path);
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_resultPath is not null && _primary.Text == "결과 열기") OpenPath(_resultPath);
        _cts?.Cancel();
        _capture?.Dispose();
        _tick.Dispose(); _liveTick.Dispose();
        base.OnFormClosing(e);
    }
}
