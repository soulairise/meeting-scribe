using System.Text;
using Whisper.net;
using Whisper.net.Ggml;

namespace MeetingScribe;

public sealed record Segment(double Start, double End, string Text);

/// <summary>
/// whisper.cpp(Whisper.net) 로 한국어 음성을 전사한다.
///
/// macOS 판은 OS 내장 온디바이스 인식기를 쓰지만 윈도우에는 같은 것이 없다.
/// 그래서 모델을 한 번 내려받아 로컬에서 돌린다.
/// </summary>
public sealed class Transcriber : IAsyncDisposable
{
    /// 한국어 정확도와 내려받기 크기의 절충. 약 550MB.
    private const GgmlType Model = GgmlType.LargeV3Turbo;
    private const QuantizationType Quantization = QuantizationType.Q5_0;

    private WhisperFactory? _factory;
    private readonly string _modelPath;

    public Transcriber()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "MeetingScribe", "models");
        Directory.CreateDirectory(dir);
        _modelPath = Path.Combine(dir, $"ggml-{Model}-{Quantization}.bin");
    }

    public bool ModelReady => File.Exists(_modelPath) && new FileInfo(_modelPath).Length > 1_000_000;

    /// <summary>모델이 없으면 내려받는다. 최초 1회만 걸린다.</summary>
    public async Task EnsureModelAsync(IProgress<string>? progress, CancellationToken ct = default)
    {
        if (ModelReady) return;
        progress?.Report("음성인식 모델을 내려받는 중… (최초 1회, 약 550MB)");

        var temp = _modelPath + ".part";
        await using (var remote = await WhisperGgmlDownloader.GetGgmlModelAsync(Model, Quantization, cancellationToken: ct))
        await using (var local = File.Create(temp))
        {
            await remote.CopyToAsync(local, ct);
        }
        File.Move(temp, _modelPath, overwrite: true);
        progress?.Report("모델 준비 완료");
    }

    private async Task<WhisperFactory> FactoryAsync(IProgress<string>? progress, CancellationToken ct)
    {
        if (_factory is not null) return _factory;
        await EnsureModelAsync(progress, ct);
        _factory = WhisperFactory.FromPath(_modelPath);
        return _factory;
    }

    /// <summary>
    /// WAV 를 전사한다. <paramref name="tailSeconds"/> 를 주면 파일 끝에서 그만큼만 처리한다.
    /// 짧게 끊어 넣으면 인식 정확도가 높고, 녹음이 길어져도 갱신 속도가 일정하다.
    /// </summary>
    public async Task<List<Segment>> TranscribeAsync(
        string wavPath, double? tailSeconds = null,
        IProgress<string>? progress = null, CancellationToken ct = default)
    {
        var results = new List<Segment>();
        if (!File.Exists(wavPath)) return results;

        var factory = await FactoryAsync(progress, ct);
        await using var processor = factory.CreateBuilder()
            .WithLanguage("ko")
            .WithNoContext()
            .Build();

        await using var source = OpenPcm(wavPath, tailSeconds, out var offset);
        if (source is null) return results;

        await foreach (var segment in processor.ProcessAsync(source, ct))
        {
            var text = segment.Text.Trim();
            if (text.Length == 0) continue;
            results.Add(new Segment(
                segment.Start.TotalSeconds + offset,
                segment.End.TotalSeconds + offset,
                text));
        }
        return results;
    }

    /// <summary>WAV 를 열되, tail 이 주어지면 끝에서 그만큼만 담은 메모리 스트림을 만든다.</summary>
    private static Stream? OpenPcm(string path, double? tailSeconds, out double offsetSeconds)
    {
        offsetSeconds = 0;
        var bytes = ReadAllRetry(path);
        if (bytes is null || bytes.Length <= 44) return null;

        const int header = 44;
        int bytesPerSecond = AudioCapture.SampleRate * 2;              // 16-bit 모노
        int dataLength = (bytes.Length - header) / 2 * 2;
        if (dataLength <= 0) return null;

        // 녹음 중인 파일은 헤더의 길이 필드가 실제 데이터와 어긋날 수 있다.
        // 그래서 읽을 때마다 실제 크기로 헤더를 다시 만든다.
        int skip = 0, take = dataLength;
        if (tailSeconds is not null)
        {
            int tailBytes = (int)(tailSeconds.Value * bytesPerSecond);
            if (dataLength > tailBytes)
            {
                skip = (dataLength - tailBytes) / 2 * 2;
                take = tailBytes;
                offsetSeconds = (double)skip / bytesPerSecond;
            }
        }

        var output = new MemoryStream();
        output.Write(BuildHeader(take));
        output.Write(bytes, header + skip, take);
        output.Position = 0;
        return output;
    }

    /// <summary>녹음 중인 파일은 쓰기 잠금이 걸려 있을 수 있어 공유 모드로 읽는다.</summary>
    private static byte[]? ReadAllRetry(string path)
    {
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                              FileShare.ReadWrite | FileShare.Delete);
                using var ms = new MemoryStream();
                fs.CopyTo(ms);
                return ms.ToArray();
            }
            catch (IOException) { Thread.Sleep(80); }
        }
        return null;
    }

    private static byte[] BuildHeader(int dataBytes)
    {
        const int channels = 1, bits = 16;
        int byteRate = AudioCapture.SampleRate * channels * bits / 8;
        var ms = new MemoryStream();
        var w = new BinaryWriter(ms, Encoding.ASCII);
        w.Write("RIFF"u8.ToArray()); w.Write(36 + dataBytes); w.Write("WAVE"u8.ToArray());
        w.Write("fmt "u8.ToArray()); w.Write(16); w.Write((short)1); w.Write((short)channels);
        w.Write(AudioCapture.SampleRate); w.Write(byteRate);
        w.Write((short)(channels * bits / 8)); w.Write((short)bits);
        w.Write("data"u8.ToArray()); w.Write(dataBytes);
        w.Flush();
        return ms.ToArray();
    }

    public ValueTask DisposeAsync()
    {
        _factory?.Dispose();
        _factory = null;
        return ValueTask.CompletedTask;
    }
}
