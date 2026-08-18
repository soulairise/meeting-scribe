using System.Diagnostics;
using System.Text;

namespace MeetingScribe;

public enum Mode { Meeting, Lecture }

public static class Pipeline
{
    public static string Label(this Mode m) => m == Mode.Meeting ? "회의" : "강의";
    public static string TemplateName(this Mode m) => m == Mode.Meeting ? "meeting.md" : "lecture.md";
    public static string OutputName(this Mode m) => m == Mode.Meeting ? "회의록.md" : "강의기록.md";

    public static string LibraryRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "MeetingScribe");

    private static string TemplateDir =>
        Path.Combine(AppContext.BaseDirectory, "templates");

    /// <summary>여러 트랙의 구간을 시각 순으로 합쳐 화자 표시가 붙은 전사문을 만든다.</summary>
    public static string Merge(IEnumerable<(string Speaker, List<Segment> Segments)> tracks)
    {
        var rows = tracks
            .SelectMany(t => t.Segments.Select(s => (s.Start, t.Speaker, s.Text)))
            .Where(r => !string.IsNullOrWhiteSpace(r.Text))
            .OrderBy(r => r.Start)
            .ToList();

        var sb = new StringBuilder();
        string? last = null;
        foreach (var (start, speaker, text) in rows)
        {
            var stamp = $"[{(int)start / 60:00}:{(int)start % 60:00}]";
            if (speaker != last)
            {
                sb.AppendLine().Append("**").Append(speaker).Append("** ").Append(stamp).Append(' ').AppendLine(text.Trim());
                last = speaker;
            }
            else sb.Append(stamp).Append(' ').AppendLine(text.Trim());
        }
        return sb.ToString().Trim();
    }

    public static List<string> FormatLive(IEnumerable<(string Speaker, List<Segment> Segments)> tracks) =>
        tracks.SelectMany(t => t.Segments.Select(s => (s.Start, t.Speaker, s.Text)))
              .Where(r => !string.IsNullOrWhiteSpace(r.Text))
              .OrderBy(r => r.Start)
              .Select(r => $"{(int)r.Start / 60:00}:{(int)r.Start % 60:00}  {r.Speaker}  {r.Text.Trim()}")
              .ToList();

    /// <summary>Claude Code CLI 를 찾는다. GUI 는 셸 PATH 를 물려받지 못해 직접 뒤진다.</summary>
    public static string? FindClaude()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = new[]
        {
            Path.Combine(home, ".local", "bin", "claude.exe"),
            Path.Combine(home, ".local", "bin", "claude.cmd"),
            Path.Combine(home, "AppData", "Roaming", "npm", "claude.cmd"),
            "claude.cmd", "claude.exe",
        };
        foreach (var c in candidates)
        {
            if (File.Exists(c)) return c;
            var resolved = ResolveOnPath(c);
            if (resolved is not null) return resolved;
        }
        return null;
    }

    private static string? ResolveOnPath(string name)
    {
        if (Path.IsPathRooted(name)) return null;
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            var candidate = Path.Combine(dir, name);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>전사문을 LLM 에 넘겨 용어 교정과 요약·할일 문서를 만든다.</summary>
    public static async Task<string> SummarizeAsync(string transcript, Mode mode, string model, CancellationToken ct = default)
    {
        var claude = FindClaude()
            ?? throw new InvalidOperationException(
                "Claude Code CLI를 찾을 수 없습니다.\n명령 프롬프트에서 claude 명령이 동작하는지 확인해 주세요.");

        var templatePath = Path.Combine(TemplateDir, mode.TemplateName());
        if (!File.Exists(templatePath))
            throw new FileNotFoundException($"템플릿을 찾을 수 없습니다: {templatePath}");

        var terms = File.Exists(Path.Combine(TemplateDir, "terms.txt"))
            ? await File.ReadAllTextAsync(Path.Combine(TemplateDir, "terms.txt"), ct)
            : "";

        var prompt = (await File.ReadAllTextAsync(templatePath, ct))
            .Replace("{{TERMS}}", terms.Trim())
            .Replace("{{TRANSCRIPT}}", transcript);

        var psi = new ProcessStartInfo(claude)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(false),
        };
        psi.ArgumentList.Add("--print");
        psi.ArgumentList.Add("--model");
        psi.ArgumentList.Add(model);

        using var process = Process.Start(psi)
            ?? throw new InvalidOperationException("Claude CLI 실행에 실패했습니다");
        await process.StandardInput.WriteAsync(prompt);
        process.StandardInput.Close();

        var stdout = await process.StandardOutput.ReadToEndAsync(ct);
        var stderr = await process.StandardError.ReadToEndAsync(ct);
        await process.WaitForExitAsync(ct);

        if (process.ExitCode != 0)
            throw new InvalidOperationException($"LLM 호출 실패: {stderr[..Math.Min(300, stderr.Length)]}");
        return stdout.Trim();
    }
}
