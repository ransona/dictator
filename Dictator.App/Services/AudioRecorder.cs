using NAudio.Wave;

namespace Dictator.App.Services;

internal enum RecordingState
{
    Idle,
    Recording,
    Paused
}

internal sealed class AudioRecorder : IDisposable
{
    private WaveInEvent? waveIn;
    private WaveFileWriter? writer;
    private TaskCompletionSource<bool>? stopCompletionSource;
    private string? tempFilePath;
    private long totalBytesWritten;

    public RecordingState State { get; private set; } = RecordingState.Idle;

    public TimeSpan RecordedDuration
        => writer?.WaveFormat is null
            ? TimeSpan.Zero
            : TimeSpan.FromSeconds(totalBytesWritten / (double)writer.WaveFormat.AverageBytesPerSecond);

    public void Start()
    {
        if (State != RecordingState.Idle)
        {
            return;
        }

        waveIn = new WaveInEvent
        {
            WaveFormat = new WaveFormat(16000, 16, 1),
            BufferMilliseconds = 100
        };
        tempFilePath = Path.Combine(Path.GetTempPath(), $"dictator-{Guid.NewGuid():N}.wav");
        writer = new WaveFileWriter(tempFilePath, waveIn.WaveFormat);
        stopCompletionSource = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        totalBytesWritten = 0;

        waveIn.DataAvailable += OnDataAvailable;
        waveIn.RecordingStopped += OnRecordingStopped;
        waveIn.StartRecording();
        State = RecordingState.Recording;
    }

    public void Pause()
    {
        if (State == RecordingState.Recording)
        {
            State = RecordingState.Paused;
        }
    }

    public void Resume()
    {
        if (State == RecordingState.Paused)
        {
            State = RecordingState.Recording;
        }
    }

    public async Task<byte[]?> StopAsync(bool cancel)
    {
        if (State == RecordingState.Idle || waveIn is null || stopCompletionSource is null)
        {
            return null;
        }

        State = RecordingState.Idle;
        waveIn.StopRecording();
        await stopCompletionSource.Task;

        var bytes = tempFilePath is not null && File.Exists(tempFilePath)
            ? await File.ReadAllBytesAsync(tempFilePath)
            : Array.Empty<byte>();
        Cleanup();

        if (cancel || bytes.Length <= 44)
        {
            return null;
        }

        return bytes;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (State != RecordingState.Recording || writer is null)
        {
            return;
        }

        writer.Write(e.Buffer, 0, e.BytesRecorded);
        writer.Flush();
        totalBytesWritten += e.BytesRecorded;
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception is not null)
        {
            stopCompletionSource?.TrySetException(e.Exception);
            return;
        }

        writer?.Dispose();
        writer = null;
        stopCompletionSource?.TrySetResult(true);
    }

    private void Cleanup()
    {
        if (waveIn is not null)
        {
            waveIn.DataAvailable -= OnDataAvailable;
            waveIn.RecordingStopped -= OnRecordingStopped;
            waveIn.Dispose();
            waveIn = null;
        }

        if (!string.IsNullOrWhiteSpace(tempFilePath) && File.Exists(tempFilePath))
        {
            File.Delete(tempFilePath);
        }

        tempFilePath = null;
        stopCompletionSource = null;
        writer = null;
        totalBytesWritten = 0;
    }

    public void Dispose()
    {
        waveIn?.Dispose();
        writer?.Dispose();
    }
}
