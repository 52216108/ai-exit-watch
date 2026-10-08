using System.Text.Json;

namespace WatchCore;

public sealed class SavedState
{
    public int Version { get; set; } = 1;
    public Settings Settings { get; set; } = new();
    public Snapshot? Baseline { get; set; }
    public List<Snapshot> Samples { get; set; } = [];
    public List<AlertEvent> Events { get; set; } = [];
}

public sealed class StateStore(string path)
{
    public string Path { get; } = path;
    public string? Error { get; private set; }
    private bool readBlocked;
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public SavedState Load()
    {
        try
        {
            if (!File.Exists(Path)) return new();
            var state = JsonSerializer.Deserialize<SavedState>(File.ReadAllBytes(Path), Json)
                ?? throw new InvalidDataException("空文件");
            if (state.Version != 1 || state.Settings == null || state.Samples == null || state.Events == null)
                throw new InvalidDataException("版本或数据结构不受支持");
            state.Settings.Validate();
            // 只接纳能安全供比较和展示的历史数据。
            foreach (var sample in state.Samples.Concat(state.Baseline == null ? [] : new[] { state.Baseline }))
                if (sample == null || sample.Endpoints == null || sample.References == null || sample.Geo == null ||
                    sample.Risks == null || sample.GeoErrors == null || sample.RiskErrors == null ||
                    sample.Endpoints.Any(e => e == null || e.Host == null) || sample.References.Any(e => e == null) ||
                    sample.Geo.Any(p => p.Value == null) || sample.Risks.Any(p => p.Value == null) ||
                    sample.Endpoints.Select(e => e.Host).Distinct().Count() != sample.Endpoints.Count)
                    throw new InvalidDataException("历史数据不完整");
            if (state.Events.Any(e => e == null)) throw new InvalidDataException("事件数据不完整");
            return state;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidDataException or ArgumentException)
        {
            readBlocked = true;
            Error = "本地状态无法读取，原文件已保留；本次仅临时运行，不会覆盖原件。退出应用后可先备份并移走 state.json，再重新启动。";
            return new();
        }
    }
    public bool Save(SavedState state)
    {
        if (readBlocked) return false;
        string? temporary = null;
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            temporary = Path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, state, Json);
                stream.Flush(true);
            }
            File.Move(temporary, Path, true);
            Error = null;
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Error = "本地状态保存失败，本次设置和检测结果可能无法在重启后保留。请检查用户目录权限和剩余空间。";
            return false;
        }
        finally { if (temporary != null && File.Exists(temporary)) { try { File.Delete(temporary); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { } } }
    }
}
