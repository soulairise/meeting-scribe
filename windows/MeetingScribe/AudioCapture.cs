using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace MeetingScribe;

/// <summary>
/// 마이크와 시스템 오디오(루프백)를 각각 별도 트랙으로 16kHz 모노 WAV에 기록한다.
///
/// macOS 판과 같은 설계다. 두 트랙을 나눠두면 나중에 "나 / 상대"가 이미 갈라져 있어
/// 화자 구분 난이도가 크게 떨어진다.
/// </summary>
public sealed class AudioCapture : IDisposable
{
    public const int SampleRate = 16_000;

    private WasapiCapture? _mic;
    private WasapiLoopbackCapture? _system;
    private WaveFileWriter? _micWriter;
    private WaveFileWriter? _systemWriter;
    private MediaFoundationResampler? _micResampler;
    private MediaFoundationResampler? _systemResampler;

    public string Directory { get; }
    public string MicPath => Path.Combine(Directory, "mic.wav");
    public string SystemPath => Path.Combine(Directory, "system.wav");
    public string? MicError { get; private set; }
    public string? SystemError { get; private set; }

    private static readonly WaveFormat Target = new(SampleRate, 16, 1);

    public AudioCapture(string directory)
    {
        Directory = directory;
        System.IO.Directory.CreateDirectory(directory);
    }

    public void Start()
    {
        StartMic();
        StartSystem();
        if (_micWriter is null && _systemWriter is null)
            throw new InvalidOperationException(
                $"두 트랙 모두 시작하지 못했습니다.\n마이크: {MicError}\n시스템: {SystemError}");
    }

    private void StartMic()
    {
        try
        {
            _mic = new WasapiCapture { ShareMode = AudioClientShareMode.Shared };
            _micWriter = new WaveFileWriter(MicPath, Target);
            Wire(_mic, _micWriter, r => _micResampler = r);
            _mic.StartRecording();
        }
        catch (Exception ex)
        {
            MicError = ex.Message;
            _mic?.Dispose(); _mic = null;
            _micWriter?.Dispose(); _micWriter = null;
        }
    }

    private void StartSystem()
    {
        try
        {
            // 루프백은 재생 중인 오디오를 그대로 받는다. 사용자에게는 계속 들린다.
            _system = new WasapiLoopbackCapture();
            _systemWriter = new WaveFileWriter(SystemPath, Target);
            Wire(_system, _systemWriter, r => _systemResampler = r);
            _system.StartRecording();
        }
        catch (Exception ex)
        {
            SystemError = ex.Message;
            _system?.Dispose(); _system = null;
            _systemWriter?.Dispose(); _systemWriter = null;
        }
    }

    /// <summary>기기 포맷을 16kHz 모노로 변환해 WAV 에 흘려보낸다.</summary>
    private static void Wire(IWaveIn source, WaveFileWriter writer, Action<MediaFoundationResampler> keep)
    {
        var buffer = new BufferedWaveProvider(source.WaveFormat)
        {
            DiscardOnBufferOverflow = true,
            BufferDuration = TimeSpan.FromSeconds(5),
        };
        var resampler = new MediaFoundationResampler(buffer, Target) { ResamplerQuality = 30 };
        keep(resampler);

        var scratch = new byte[Target.AverageBytesPerSecond];
        source.DataAvailable += (_, e) =>
        {
            buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
            int read;
            while (buffer.BufferedBytes > source.WaveFormat.AverageBytesPerSecond / 10 &&
                   (read = resampler.Read(scratch, 0, scratch.Length)) > 0)
            {
                lock (writer) { writer.Write(scratch, 0, read); writer.Flush(); }
            }
        };
    }

    /// <summary>녹음을 멈추고 WAV 헤더를 확정한다. 여러 번 불러도 안전하다.</summary>
    public void Stop()
    {
        _mic?.StopRecording();
        _system?.StopRecording();
        Thread.Sleep(200);                       // 마지막 콜백이 끝나도록 잠시 기다린다

        FlushRemaining(_micResampler, _micWriter);
        FlushRemaining(_systemResampler, _systemWriter);

        _micWriter?.Dispose(); _micWriter = null;
        _systemWriter?.Dispose(); _systemWriter = null;
        _mic?.Dispose(); _mic = null;
        _system?.Dispose(); _system = null;
    }

    private static void FlushRemaining(MediaFoundationResampler? resampler, WaveFileWriter? writer)
    {
        if (resampler is null || writer is null) return;
        var scratch = new byte[16384];
        int read;
        try
        {
            while ((read = resampler.Read(scratch, 0, scratch.Length)) > 0)
                lock (writer) { writer.Write(scratch, 0, read); }
        }
        catch { /* 스트림이 이미 닫혔으면 무시한다 */ }
    }

    public void Dispose() => Stop();
}
