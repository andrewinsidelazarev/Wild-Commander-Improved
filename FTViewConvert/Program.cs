// FTView Convert — перекодирование видео в MJPEG AVI для плагина FTView
// (VDAC2/FT812, звук на General Sound или FT812).
//
// Выход: MJPEG baseline 4:2:0 со стандартными таблицами Хаффмана и своей
// матрицей квантования (меньше квадратиков, см. IntraMatrix), 24 кадра/с,
// ~2 Мбит/с (как у проверенного образца Muse, около 250 КБ/с с SD), звук PCM
// 8 бит без знака (araw) моно 22 050 или 32 000 Гц (на выбор): его выводит ЦАП
// GS (до 37,5 кГц — частота его прерываний), а без GS — звуковой блок FT812.
// Индекс idx1 и готовая таблица перемотки плеера (см. SeekIndex): первая
// перемотка не разбирает idx1 целиком.
// Разрешение — с точными пропорциями исходника (см. OutputSize): стороны кратны
// 16 (блок JPEG 4:2:0), площадь не больше 512×384 = 196 608 точек — предел
// плеера, при котором работают и звук FT812, и таблица перемотки в RAM_G;
// ширина до 1024, высота до 768 (кадр вписывается во весь экран), не больше
// исходника. Галочка «Crop 4:3» симметрично обрезает боковые стороны кадра
// шире 4:3 (см. Crop43): картинка занимает весь экран FT812 без полос.
//
// ffmpeg.exe вшит ресурсом и при первом запуске распаковывается в
// %LOCALAPPDATA%\FTViewConvert. Сборка — build.ps1 рядом, иконка —
// make_icon.py.
//
// Результат по умолчанию кладётся рядом с исходником, папку и имя можно
// сменить. Перед запуском программа сама пробует записать туда файл и, если
// Windows не даёт, объясняет причину: права папки, «Контролируемый доступ к
// папкам» Защитника Windows, файл открыт в другой программе.
//
// Пакетный режим без окна: FTViewConvert.exe --batch <вход> <журнал> [22050|32000] [nonorm] [crop43]
// (код выхода 0 — успех); --probe <вход> <журнал> [crop43] — только расчёт размера.
using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace FTViewConvert
{
    // Параметры исходного видео по выводу «ffmpeg -i».
    class SourceInfo
    {
        public int Width, Height;        // кадр в пикселях
        public double Aspect;            // отображаемое соотношение сторон
        public double Duration;          // секунды, 0 — неизвестно
        public string Fps = "";
        public bool HasAudio;
        public int Rotation;

        public SourceInfo Copy() { return (SourceInfo)MemberwiseClone(); }
    }

    static class Recipe
    {
        public const int OutFps = 24;
        public const int MaxArea = 512 * 384;
        public const int MaxWidth = 1024;
        public const int MaxHeight = 768;
        public const int AudioRate = 22050;       // по умолчанию; можно и 32000
        const string FfmpegResource = "FTViewConvert.ffmpeg.exe";
        public const string FfmpegVersion = "9.0.2";

        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // ffmpeg.exe из ресурса — в каталог пользователя (один раз на версию).
        public static string Ffmpeg()
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream src = asm.GetManifestResourceStream(FfmpegResource))
            {
                if (src == null) throw new InvalidOperationException("ffmpeg.exe is not embedded in the program");
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FTViewConvert");
                Directory.CreateDirectory(dir);
                string exe = Path.Combine(dir, "ffmpeg-" + FfmpegVersion + ".exe");
                FileInfo fi = new FileInfo(exe);
                if (fi.Exists && fi.Length == src.Length) return exe;
                string tmp = exe + ".tmp";
                using (FileStream dst = File.Create(tmp)) src.CopyTo(dst);
                if (File.Exists(exe)) File.Delete(exe);
                File.Move(tmp, exe);
                return exe;
            }
        }

        public static string Quote(string path)
        {
            return "\"" + path.Replace("\"", "\\\"") + "\"";
        }

        // Параметры первого видеопотока: размер, SAR/DAR, поворот, длительность.
        public static SourceInfo Probe(string ffmpeg, string input)
        {
            ProcessStartInfo psi = new ProcessStartInfo(ffmpeg, "-hide_banner -nostdin -i " + Quote(input));
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardError = true;
            psi.StandardErrorEncoding = Encoding.UTF8;
            string text;
            using (Process p = Process.Start(psi))
            {
                text = p.StandardError.ReadToEnd();
                p.WaitForExit();
            }
            SourceInfo info = new SourceInfo();
            Match video = Regex.Match(text, @"Stream #\d+:\d+.*?: Video: [^\n]*");
            if (!video.Success) throw new InvalidDataException("No video stream in the file");
            Match size = Regex.Match(video.Value, @"(?<![\dx])(\d{2,5})x(\d{2,5})(?![\dx])");
            if (!size.Success) throw new InvalidDataException("Cannot determine the frame size");
            info.Width = int.Parse(size.Groups[1].Value, Inv);
            info.Height = int.Parse(size.Groups[2].Value, Inv);
            double aspect = (double)info.Width / info.Height;
            Match dar = Regex.Match(video.Value, @"DAR (\d+):(\d+)");
            if (dar.Success && int.Parse(dar.Groups[2].Value, Inv) > 0)
                aspect = double.Parse(dar.Groups[1].Value, Inv) / double.Parse(dar.Groups[2].Value, Inv);
            Match rot = Regex.Match(text, @"rotation of (-?\d+(?:\.\d+)?) degrees");
            if (rot.Success)
            {
                info.Rotation = (int)Math.Round(double.Parse(rot.Groups[1].Value, Inv));
                if (Math.Abs(info.Rotation) % 180 == 90)
                {
                    aspect = 1.0 / aspect;
                    int t = info.Width; info.Width = info.Height; info.Height = t;
                }
            }
            info.Aspect = aspect;
            Match fps = Regex.Match(video.Value, @"([\d.]+) fps");
            if (fps.Success) info.Fps = fps.Groups[1].Value;
            Match dur = Regex.Match(text, @"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)");
            if (dur.Success)
                info.Duration = int.Parse(dur.Groups[1].Value, Inv) * 3600 + int.Parse(dur.Groups[2].Value, Inv) * 60 +
                                double.Parse(dur.Groups[3].Value, Inv);
            info.HasAudio = Regex.IsMatch(text, @"Stream #\d+:\d+.*?: Audio: ");
            return info;
        }

        // Кадр со сторонами, кратными 16 (блок JPEG 4:2:0: неполный блок на краю
        // декодер FT812 дописал бы в соседний кадр), площадью не больше MaxArea
        // и не больше самого исходника. Пропорции исходника важнее площади:
        // среди кадров не меньше 60% наибольшего возможного берём наибольший с
        // ошибкой пропорций не больше 0,5% (16:9 — 512×288, а не 576×320, шире
        // на 1,25%), а если такого нет — самый точный (2,39:1 — 608×256 с 0,5%
        // вместо 672×288 с 2,3%). При потоке 2 Мбит/с меньший кадр на экране не
        // хуже: на ролике 16:9 (1024×576, сглаживание) SSIM 0,6365 у 512×288
        // против 0,6350 у 576×320, а квадратиков на 29% меньше — на точку
        // приходится больше бит.
        const double AspectTolerance = 0.005, MinAreaShare = 0.6;

        public static Size OutputSize(SourceInfo s)
        {
            int capW = Math.Max(16, (int)Math.Ceiling(s.Height * s.Aspect / 16.0) * 16);
            int capH = Math.Max(16, (int)Math.Ceiling(s.Height / 16.0) * 16);
            // Кандидаты: ширина кратна 16, высота — ближайшая кратная 16 по пропорциям.
            Func<int, int> height = w => (int)Math.Round(w / s.Aspect / 16.0) * 16;
            Func<int, bool> valid = w =>
            {
                int h = height(w);
                return h >= 16 && h <= MaxHeight && w * h <= MaxArea && w <= capW && h <= capH;
            };
            int maxArea = 0;
            for (int w = 16; w <= MaxWidth; w += 16)
                if (valid(w)) maxArea = Math.Max(maxArea, w * height(w));
            if (maxArea == 0) return new Size(16, 16);
            Size tol = Size.Empty, near = Size.Empty;
            double tolErr = 0, nearErr = double.MaxValue;
            for (int w = 16; w <= MaxWidth; w += 16)
            {
                if (!valid(w)) continue;
                int h = height(w), area = w * h;
                if (area < MinAreaShare * maxArea) continue;
                double err = Math.Abs((double)w / h - s.Aspect) / s.Aspect;
                if (err <= AspectTolerance && (area > tol.Width * tol.Height || (area == tol.Width * tol.Height && err < tolErr)))
                { tol = new Size(w, h); tolErr = err; }
                if (err < nearErr || (err == nearErr && area > near.Width * near.Height))
                { near = new Size(w, h); nearErr = err; }
            }
            return tol.Width > 0 ? tol : near;
        }

        // «Crop 4:3»: у кадра шире 4:3 симметрично обрезаются боковые стороны,
        // высота остаётся. Кадр 4:3 и уже не меняется (верх и низ не режутся).
        // Порог чуть выше 4/3, чтобы 4:3 с округлением SAR не терял точки.
        // Разрешение считается по уже обрезанному кадру: у 16:9 — 512×384.
        const double CropFrom = 1.334;
        const string CropFilter = "crop=w='if(gt(dar,1.334),ih*4/3/sar,iw)',";

        public static bool Crops(SourceInfo s)
        {
            return s.Aspect > CropFrom;
        }

        public static SourceInfo Crop43(SourceInfo s)
        {
            if (!Crops(s)) return s;
            SourceInfo c = s.Copy();
            c.Width = (int)Math.Round(s.Width * (4.0 / 3) / s.Aspect);
            c.Aspect = 4.0 / 3;
            return c;
        }

        public static string OutputPath(string input, Size size, int rate)
        {
            string dir = Path.GetDirectoryName(Path.GetFullPath(input));
            string name = Path.GetFileNameWithoutExtension(input);
            return Path.Combine(dir, string.Format(Inv, "{0} - FTView {1}x{2} 24p {3} kHz.avi",
                                                   name, size.Width, size.Height, rate / 1000));
        }

        // Нормализация до 0 дБ: весь файл усиливается одним множителем так, что
        // самый громкий сэмпл выходит на полную шкалу 8 бит. Запись, которая и
        // после этого тише −12 LUFS, поднимается ещё не больше чем на 2 дБ:
        // вылезшие за шкалу пики мягко прижимает лимитер с длинной атакой, то
        // есть сжатие не глубже 2 дБ. Громкие записи только нормализуются —
        // лимитер их не трогает. Атака 50 мс и восстановление 1 с: при 5 и 50 мс
        // усиление менялось за пару периодов баса, и сжатие было слышно.
        // Замер — на том же звуке, что пойдёт в файл: моно, уже на частоте
        // результата (понижение частоты само даёт выбросы выше пиков исходника),
        // в плавающей точке без среза (сведение стерео в моно — до +3 дБ).
        const string Prepare = "aformat=sample_fmts=flt:channel_layouts=mono,aresample={0}";
        const double TargetLufs = -12, MaxLimitDb = 2;

        // Усиление в дБ по отчётам astats (пик) и ebur128 (громкость); null —
        // замер не удался или звук — тишина (-inf).
        public static double? LoudnessGain(string ffmpegOutput)
        {
            MatchCollection peak = Regex.Matches(ffmpegOutput, "Peak level dB:\\s*([-+]?[0-9.]+)");
            MatchCollection i = Regex.Matches(ffmpegOutput, "\\bI:\\s*([-+]?[0-9.]+) LUFS");
            if (peak.Count == 0) return null;
            double normalize = -double.Parse(peak[peak.Count - 1].Groups[1].Value, Inv);
            if (i.Count == 0) return normalize;
            double loud = TargetLufs - double.Parse(i[i.Count - 1].Groups[1].Value, Inv);
            return Math.Max(normalize, Math.Min(loud, normalize + MaxLimitDb));
        }

        // Второй проход: тот же звук, усиление и лимитер с потолком 0 дБ —
        // он срабатывает только на пиках выше полной шкалы.
        public static string LoudnessFilter(double gain, int rate)
        {
            return string.Format(Inv, Prepare + ",volume={1:0.0000}dB,alimiter=limit=1:attack=50:release=1000:level=0:latency=1",
                                 rate, gain);
        }

        // Первый проход: только звук, без записи файла. started получает
        // процесс, чтобы его можно было остановить.
        public static double? MeasureLoudness(string ffmpeg, string input, int rate, Action<Process> started)
        {
            ProcessStartInfo psi = new ProcessStartInfo(ffmpeg, "-hide_banner -nostdin -nostats -i " + Quote(input) +
                " -map 0:a:0 -vn -af \"" + string.Format(Inv, Prepare, rate) +
                ",astats=measure_perchannel=none:measure_overall=Peak_level,ebur128=framelog=quiet\" -f null -");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardError = true;
            psi.StandardErrorEncoding = Encoding.UTF8;
            using (Process p = Process.Start(psi))
            {
                if (started != null) started(p);
                string text = p.StandardError.ReadToEnd();
                p.WaitForExit();
                return p.ExitCode == 0 ? LoudnessGain(text) : null;
            }
        }

        // Матрица квантования MJPEG, построчно: стандартная MPEG-1 (её ffmpeg
        // берёт по умолчанию), но низкие частоты (сумма индексов до 2) ×0,6,
        // средние ×0,9, высокие ×1,6 и ×2,4. При том же потоке 2 Мбит/с внутри
        // блоков 8×8 остаются плавные переходы, и квадратики на градиентах и в
        // цвете (блок цвета при 4:2:0 — 16×16 точек) заметно слабее: blockdetect
        // на Muse 7,8 вместо 9,3 по яркости и 10,2 вместо 13,1 по цвету, у КИНО
        // цвет 10,2 вместо 15,7; SSIM почти прежний. Таблица по-прежнему одна
        // на яркость и цвет, как у обычного MJPEG.
        const string IntraMatrix =
            "8,10,11,20,23,24,46,54,10,10,20,22,24,46,54,59,11,20,23,24,46,54,54,61," +
            "20,20,23,43,46,54,59,96,20,23,43,46,51,56,96,115,23,43,46,51,56,96,115,139," +
            "42,43,46,54,91,110,134,166,43,46,56,91,110,134,166,199";

        public static string Arguments(string input, string output, Size size, bool audio, int rate, double? gain,
                                       bool crop)
        {
            StringBuilder a = new StringBuilder();
            a.Append("-hide_banner -nostdin -y -nostats -progress pipe:1 -i ").Append(Quote(input));
            a.Append(" -map 0:v:0");
            if (audio) a.Append(" -map 0:a:0");
            // Обрезка — до масштабирования, по отображаемым пропорциям (dar и
            // sar кадра уже после поворота, который ffmpeg ставит перед -vf).
            a.AppendFormat(Inv, " -vf \"fps={0},{1}scale={2}:{3}:flags=lanczos,setsar=1,format=yuvj420p\"",
                           OutFps, crop ? CropFilter : "", size.Width, size.Height);
            a.Append(" -c:v mjpeg -huffman default -intra_matrix ").Append(IntraMatrix);
            a.Append(" -b:v 2000k -maxrate 2600k -bufsize 2000k");
            if (audio && gain.HasValue) a.Append(" -af \"").Append(LoudnessFilter(gain.Value, rate)).Append('"');
            if (audio) a.AppendFormat(Inv, " -c:a pcm_u8 -ar {0} -ac 1", rate);
            a.Append(" -f avi ").Append(Quote(output));
            return a.ToString();
        }

        // Можно ли записать файл результата: null — можно, иначе объяснение.
        // ffmpeg работает в том же сеансе, поэтому проба своим процессом ловит
        // права папки, «Контролируемый доступ к папкам» и занятый файл.
        public static string CheckWritable(string output)
        {
            string dir = Path.GetDirectoryName(output);
            string name = Path.GetFileName(output);
            try
            {
                if (!Directory.Exists(dir)) return "Folder '" + dir + "' not found.";
                if (File.Exists(output))
                {
                    if ((File.GetAttributes(output) & FileAttributes.ReadOnly) != 0)
                        return "File '" + name + "' already exists and is read-only. " +
                               "Choose another name or clear the read-only attribute.";
                    // Открытие на запись без изменения: занят ли файл плеером.
                    using (new FileStream(output, FileMode.Open, FileAccess.Write, FileShare.None)) { }
                }
                string probe = Path.Combine(dir, ".ftview-" + Guid.NewGuid().ToString("N") + ".tmp");
                using (new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1,
                                      FileOptions.DeleteOnClose)) { }
                return null;
            }
            catch (UnauthorizedAccessException)
            {
                return AccessDenied(dir);
            }
            catch (IOException ex)
            {
                int code = Marshal.GetHRForException(ex) & 0xFFFF;
                if (code == 32 || code == 33)   // ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION
                    return "File '" + name + "' is open in another program (a player?). " +
                           "Close it or choose another name.";
                return ex.Message;
            }
        }

        static string AccessDenied(string dir)
        {
            StringBuilder s = new StringBuilder();
            s.Append("Windows does not allow writing to the folder '").Append(dir).Append("'. ");
            bool cfa = ControlledFolderAccess(), limited = LimitedAdmin();
            if (cfa)
                s.Append("Windows Defender Controlled folder access is on: if it protects the folder, " +
                         "allow FTViewConvert.exe and ffmpeg in it. ");
            if (limited)
                s.Append(cfa ? "It may also be that " : "It looks like ")
                 .Append("only administrators may write there (Explorer asks for permission in this case): " +
                         "run the program as administrator. ");
            if (!cfa && !limited) s.Append("This account may not write to the folder. ");
            return s.Append("The simplest fix is to save the result to another folder.").ToString();
        }

        // Защитник: 1 — «Контролируемый доступ к папкам» включён (2 — только аудит).
        static bool ControlledFolderAccess()
        {
            foreach (string key in new[] {
                @"SOFTWARE\Microsoft\Windows Defender\Windows Defender Exploit Guard\Controlled Folder Access",
                @"SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\Controlled Folder Access" })
            {
                try
                {
                    using (RegistryKey k = Registry.LocalMachine.OpenSubKey(key))
                        if (k != null && Convert.ToInt32(k.GetValue("EnableControlledFolderAccess", 0), Inv) == 1)
                            return true;
                }
                catch (Exception) { }
            }
            return false;
        }

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool GetTokenInformation(IntPtr token, int infoClass, out int info, int length, out int returned);

        // Администратор без повышения прав (UAC): TokenElevationType = 18,
        // TokenElevationTypeLimited = 3.
        static bool LimitedAdmin()
        {
            try
            {
                using (WindowsIdentity id = WindowsIdentity.GetCurrent())
                {
                    int type, length;
                    return GetTokenInformation(id.Token, 18, out type, 4, out length) && type == 3;
                }
            }
            catch (Exception) { return false; }
        }

        // ffmpeg не смог открыть результат, хотя проба этой программы прошла.
        public static string FfmpegDenied(string output, string ffmpeg)
        {
            return "ffmpeg could not write '" + Path.GetFileName(output) + "': access denied, although this " +
                   "program can write to the folder. Usually Windows Defender Controlled folder access " +
                   "or an antivirus blocks ffmpeg: allow " + ffmpeg +
                   " or choose another folder.";
        }

        public static string Describe(SourceInfo s, Size size, int rate, bool crop)
        {
            return string.Format(Inv,
                "Source: {0}×{1}, {2:0.###}:1{3}{4}, sound: {5}\r\n" +
                "Result: {6}×{7}{8}, {9} fps, MJPEG ~2 Mbit/s{10}",
                s.Width, s.Height, s.Aspect,
                s.Fps.Length > 0 ? ", " + s.Fps + " fps" : "",
                s.Rotation != 0 ? string.Format(Inv, ", rotated {0}°", s.Rotation) : "",
                s.HasAudio ? "yes" : "no",
                size.Width, size.Height,
                !crop ? "" : Crops(s) ? " (sides cropped to 4:3)" : " (not wider than 4:3: not cropped)",
                OutFps,
                !s.HasAudio ? ", no sound" :
                string.Format(Inv, ", PCM 8-bit mono {0} Hz", rate));
        }
    }

    // Готовая таблица перемотки FTView в самом AVI: чанк JUNK между LIST movi
    // и idx1 — другие плееры JUNK пропускают. Плеер при первой перемотке
    // находит его, сверяет поля с заголовком и одним чтением заливает записи в
    // RAM_G, не разбирая idx1. Таблица считается так же, как плеер строит её
    // по idx1 (index_build и index_scan в avi_index.c; эталон —
    // tests/avigen.py, seek_table): запись k — первый чанк idx1, с которого
    // есть и кадр k*шаг, и звук с сэмпла k*шаг*pcm_rate/fps; хранятся его
    // абсолютное смещение, число видеочанков и звуковых байтов до него.
    // Данные чанка: "FTVIEWI1", шаг и число записей (u16), поля AVI_SHARED
    // плеера от pcm_rate до pcm_total (30 байт), два байта выравнивания,
    // записи по 12 байт.
    static class SeekIndex
    {
        const uint MaxEntries = 5460;         // AVI_INDEX_MAX плеера
        const string Magic = "FTVIEWI1";

        static uint U32(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }
        static string Tag(byte[] b, int o) { return Encoding.ASCII.GetString(b, o, 4); }

        static void ReadAt(FileStream f, long pos, byte[] buf)
        {
            f.Position = pos;
            int got = 0;
            while (got < buf.Length)
            {
                int n = f.Read(buf, got, buf.Length - got);
                if (n <= 0) throw new EndOfStreamException();
                got += n;
            }
        }

        // Число записей встроенной таблицы; 0 — не встроена (не тот файл,
        // OpenDML больше 1 ГБ, таблица уже есть или плеер её не примет).
        public static int Embed(string path)
        {
            using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                long length = f.Length;
                byte[] head = new byte[(int)Math.Min(length, 1 << 20)];
                ReadAt(f, 0, head);
                if (head.Length < 12 || Tag(head, 0) != "RIFF" || Tag(head, 8) != "AVI " ||
                    U32(head, 4) + 8L != length) return 0;
                // Поля заголовка — так же, как их берёт avi_probe плеера.
                uint total = 0, rate = 0, scale = 0, pcmRate = 0, pcmTotal = 0, width = 0, height = 0;
                uint moviStart = 0, moviEnd = 0;
                long[] ends = new long[4];
                int depth = 0;
                ends[0] = length;
                long pos = 12;
                while (true)
                {
                    while (depth > 0 && pos == ends[depth]) --depth;
                    if (pos + 12 > head.Length) return 0;
                    string tag = Tag(head, (int)pos);
                    uint size = U32(head, (int)pos + 4);
                    pos += 8;
                    long end = pos + size;
                    if (tag == "LIST")
                    {
                        string sub = Tag(head, (int)pos);
                        if (sub == "movi") { moviStart = (uint)(pos + 4); moviEnd = (uint)end; break; }
                        if ((sub == "hdrl" || sub == "strl") && depth < 3) { ends[++depth] = end; pos += 4; continue; }
                    }
                    else if (tag == "avih" && size >= 40 && pos + 40 <= head.Length)
                    {
                        total = U32(head, (int)pos + 16);
                        width = U32(head, (int)pos + 32);
                        height = U32(head, (int)pos + 36);
                    }
                    else if (tag == "strh" && size >= 36 && pos + 36 <= head.Length)
                    {
                        string kind = Tag(head, (int)pos);
                        if (kind == "vids" && Tag(head, (int)pos + 4) == "MJPG")
                        { scale = U32(head, (int)pos + 20); rate = U32(head, (int)pos + 24); }
                        else if (kind == "auds")
                        { pcmRate = U32(head, (int)pos + 24); pcmTotal = U32(head, (int)pos + 32); }
                    }
                    pos = end + (size & 1);
                }
                uint bytes = (width * height * 2 + 3) & ~3u;
                if (bytes > 0xD0000 / 2 || moviStart > 0x10000 || (pcmRate != 0 && (scale != 1 || rate == 0))) return 0;
                // idx1 — среди первых восьми чанков за LIST movi.
                long at = moviEnd + (moviEnd & 1);
                byte[] chunk = new byte[16];
                uint idxSize = 0;
                int tries;
                for (tries = 0; tries < 8; ++tries)
                {
                    if (at + 16 > length) return 0;
                    ReadAt(f, at, chunk);
                    uint size = U32(chunk, 4);
                    if (Tag(chunk, 0) == "idx1") { idxSize = size; break; }
                    if (Tag(chunk, 0) == "JUNK" && Encoding.ASCII.GetString(chunk, 8, 8) == Magic) return 0;
                    at += 8 + size + (size & 1);
                }
                if (tries == 8 || idxSize > length - at - 8) return 0;
                byte[] idx = new byte[idxSize];
                ReadAt(f, at + 8, idx);
                // Записи — как index_build/index_scan плеера.
                uint step = total / MaxEntries + 1;
                uint count = (total + step - 1) / step;
                uint fps = rate;
                uint pcmOn = pcmRate != 0 ? pcmTotal : 0;
                uint sampleStep = 0, sampleRem = 0;
                if (pcmOn != 0)
                {
                    sampleStep = step * pcmRate;
                    sampleRem = sampleStep % fps;
                    sampleStep /= fps;
                }
                uint frame = 0, sample = 0, video = 0, audio = 0, bas = 0, rem = 0, k = 0;
                MemoryStream table = new MemoryStream();
                BinaryWriter tw = new BinaryWriter(table);
                for (int e = 0; e + 16 <= idx.Length && k < count; e += 16)
                {
                    uint off = U32(idx, e + 8), len = U32(idx, e + 12);
                    if (video == 0 && audio == 0 && k == 0) bas = off < moviStart ? moviStart - 4 : 0;
                    bool isVideo = idx[e] == '0' && idx[e + 1] == '0' && idx[e + 2] == 'd' &&
                                   (idx[e + 3] == 'c' || idx[e + 3] == 'b');
                    bool isAudio = pcmOn != 0 && Tag(idx, e) == "01wb";
                    while (k < count && ((isVideo && video >= frame) || (isAudio && audio + len > sample)))
                    {
                        tw.Write(bas + off);
                        tw.Write(video);
                        tw.Write(audio);
                        ++k;
                        frame += step;
                        sample += sampleStep;
                        rem += sampleRem;
                        if (rem >= fps) { rem -= fps; ++sample; }
                    }
                    if (isVideo) ++video;
                    if (isAudio) audio += len;
                }
                if (k == 0) return 0;
                MemoryStream payload = new MemoryStream();
                BinaryWriter pw = new BinaryWriter(payload);
                pw.Write(Encoding.ASCII.GetBytes(Magic));
                pw.Write((ushort)step);
                pw.Write((ushort)k);
                pw.Write((ushort)pcmRate);
                pw.Write(moviStart);
                pw.Write(moviEnd);
                pw.Write(total);
                pw.Write(rate);
                pw.Write(scale);
                pw.Write(bytes);
                pw.Write(pcmTotal);
                pw.Write((ushort)0);
                pw.Write(table.ToArray());
                byte[] body = payload.ToArray();
                // JUNK перед idx1: idx1 и всё за ним сдвигаются на размер чанка.
                byte[] tail = new byte[length - at];
                ReadAt(f, at, tail);
                f.Position = at;
                BinaryWriter fw = new BinaryWriter(f);
                fw.Write(Encoding.ASCII.GetBytes("JUNK"));
                fw.Write((uint)body.Length);
                fw.Write(body);
                fw.Write(tail);
                fw.Flush();
                f.Position = 4;
                fw.Write((uint)(f.Length - 8));
                fw.Flush();
                return (int)k;
            }
        }
    }

    class MainForm : Form
    {
        readonly TextBox fileBox = new TextBox();
        readonly Button browse = new Button();
        readonly TextBox outBox = new TextBox();
        readonly Button outChange = new Button();
        readonly Button openDir = new Button();
        readonly Label info = new Label();
        readonly CheckBox crop = new CheckBox();
        readonly RadioButton rate22 = new RadioButton();
        readonly RadioButton rate32 = new RadioButton();
        readonly CheckBox normalize = new CheckBox();
        readonly Button run = new Button();
        readonly ProgressBar bar = new ProgressBar();
        readonly Label status = new Label();
        string ffmpeg;
        SourceInfo source;
        Size outSize;
        string outDir;     // папка результата; null — рядом с исходником
        string outName;    // своё имя файла для текущего исходника; null — по шаблону
        Process worker;             // кодирование
        volatile Process measure;   // замер уровня звука (первый проход)
        bool busy, cancelled;

        public MainForm()
        {
            Text = "FTView Video Converter";
            using (Stream icon = Assembly.GetExecutingAssembly().GetManifestResourceStream("FTViewConvert.app.ico"))
                if (icon != null) Icon = new Icon(icon);
            Font = new Font("Segoe UI", 9f);
            AutoScaleDimensions = new SizeF(96f, 96f);
            AutoScaleMode = AutoScaleMode.Dpi;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(660, 320);

            Label fileLabel = new Label();
            fileLabel.Text = "Video file:";
            fileLabel.SetBounds(12, 15, 84, 20);
            fileBox.SetBounds(98, 12, 434, 23);
            fileBox.ReadOnly = true;
            browse.Text = "Browse…";
            browse.SetBounds(538, 11, 110, 25);
            browse.Click += delegate { Browse(); };

            Label outLabel = new Label();
            outLabel.Text = "Save to:";
            outLabel.SetBounds(12, 47, 84, 20);
            outBox.SetBounds(98, 44, 340, 23);
            outBox.ReadOnly = true;
            outChange.Text = "Change…";
            outChange.SetBounds(444, 43, 88, 25);
            outChange.Enabled = false;
            outChange.Click += delegate { ChooseOutput(); };
            openDir.Text = "Open folder";
            openDir.SetBounds(538, 43, 110, 25);
            openDir.Enabled = false;
            openDir.Click += delegate { OpenFolder(); };

            info.SetBounds(12, 78, 636, 56);
            info.Text = "Choose a video file: the output resolution is calculated automatically.";

            // Кадр шире 4:3 — симметрично без боковых сторон (Recipe.Crop43).
            Label pictureLabel = new Label();
            pictureLabel.Text = "Picture:";
            pictureLabel.SetBounds(12, 145, 110, 20);
            crop.Text = "Crop 4:3";
            crop.SetBounds(124, 142, 200, 24);
            crop.CheckedChanged += delegate { Retarget(); };

            // 22 050 Гц — проверенный поток; 32 000 Гц — звонче на 10 КБ/с
            // больше (GS играет до 37,5 кГц, FT812 — до 48 кГц).
            Label rateLabel = new Label();
            rateLabel.Text = "Sound, PCM 8-bit:";
            rateLabel.SetBounds(12, 175, 110, 20);
            rate22.Text = "22,050 Hz";
            rate22.SetBounds(124, 172, 100, 24);
            rate22.Checked = true;
            rate32.Text = "32,000 Hz";
            rate32.SetBounds(232, 172, 100, 24);
            rate22.CheckedChanged += delegate { ShowTarget(); };
            normalize.Text = "Normalize audio level to 0 dB";
            normalize.SetBounds(360, 172, 288, 24);
            normalize.Checked = true;

            run.Text = "Convert";
            run.SetBounds(12, 207, 120, 30);
            run.Enabled = false;
            run.Click += delegate { if (!busy) Start(); else Cancel(); };

            bar.SetBounds(142, 211, 506, 22);
            status.SetBounds(12, 247, 636, 66);

            Controls.AddRange(new Control[] { fileLabel, fileBox, browse, outLabel, outBox, outChange, openDir, info,
                                              pictureLabel, crop, rateLabel, rate22, rate32, normalize, run, bar,
                                              status });
            AllowDrop = true;
            DragEnter += delegate(object s, DragEventArgs e)
            {
                if (!busy && e.Data.GetDataPresent(DataFormats.FileDrop)) e.Effect = DragDropEffects.Copy;
            };
            DragDrop += delegate(object s, DragEventArgs e)
            {
                string[] files = (string[])e.Data.GetData(DataFormats.FileDrop);
                if (files != null && files.Length > 0) OpenSource(files[0]);
            };
            FormClosing += delegate { Cancel(); };
        }

        void Browse()
        {
            using (OpenFileDialog dlg = new OpenFileDialog())
            {
                dlg.Title = "Video for FTView";
                dlg.Filter = "Video|*.mp4;*.mkv;*.avi;*.mov;*.webm;*.m4v;*.mpg;*.mpeg;*.ts;*.wmv;*.flv|All files|*.*";
                if (dlg.ShowDialog(this) == DialogResult.OK) OpenSource(dlg.FileName);
            }
        }

        // Окно может закрыться, пока ffmpeg ещё работает: события процесса
        // тогда уже некуда показывать.
        void Ui(MethodInvoker action)
        {
            try { if (!IsDisposed) BeginInvoke(action); }
            catch (InvalidOperationException) { }
        }

        // Длинный путь в поле показывается с конца: видно имя файла.
        static void ShowEnd(TextBox box, string text)
        {
            box.Text = text;
            box.Select(text.Length, 0);
            box.ScrollToCaret();
        }

        public void OpenSource(string path)
        {
            ShowEnd(fileBox, path);
            outBox.Text = "";
            outName = null;
            run.Enabled = outChange.Enabled = openDir.Enabled = false;
            bar.Value = 0;
            status.Text = "Analyzing file…";
            info.Text = "";
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    if (ffmpeg == null) ffmpeg = Recipe.Ffmpeg();
                    SourceInfo s = Recipe.Probe(ffmpeg, path);
                    Ui(delegate
                    {
                        source = s;
                        Retarget();
                        run.Enabled = outChange.Enabled = openDir.Enabled = true;
                    });
                }
                catch (Exception ex)
                {
                    Ui(delegate { status.Text = "Error: " + ex.Message; });
                }
            });
        }

        int Rate { get { return rate32.Checked ? 32000 : Recipe.AudioRate; } }

        // Файл результата: имя по шаблону (или выбранное), папка — выбранная
        // или папка исходника.
        string OutputFile()
        {
            string auto = Recipe.OutputPath(fileBox.Text, outSize, Rate);
            return Path.Combine(outDir ?? Path.GetDirectoryName(auto), outName ?? Path.GetFileName(auto));
        }

        // Папка сохраняется и для следующих файлов, своё имя — только для этого.
        bool ChooseOutput()
        {
            using (SaveFileDialog dlg = new SaveFileDialog())
            {
                string current = OutputFile();
                dlg.Title = "Save result as";
                dlg.Filter = "FTView AVI|*.avi";
                dlg.InitialDirectory = Path.GetDirectoryName(current);
                dlg.FileName = Path.GetFileName(current);
                if (dlg.ShowDialog(this) != DialogResult.OK) return false;
                string auto = Path.GetFileName(Recipe.OutputPath(fileBox.Text, outSize, Rate));
                string chosen = Path.GetFileName(dlg.FileName);
                outDir = Path.GetDirectoryName(dlg.FileName);
                outName = string.Equals(chosen, auto, StringComparison.OrdinalIgnoreCase) ? null : chosen;
                ShowTarget();
                return true;
            }
        }

        // Разрешение — по кадру после обрезки «Crop 4:3», если она включена.
        void Retarget()
        {
            if (source == null || worker != null) return;
            outSize = Recipe.OutputSize(crop.Checked ? Recipe.Crop43(source) : source);
            ShowTarget();
        }

        void ShowTarget()
        {
            if (source == null || worker != null) return;
            info.Text = Recipe.Describe(source, outSize, Rate, crop.Checked);
            string output = OutputFile();
            ShowEnd(outBox, output);
            string problem = Recipe.CheckWritable(output);
            status.Text = problem ?? (File.Exists(output) ? "A file with this name exists and will be replaced." : "");
        }

        // Во время работы менять можно только папку просмотра.
        void Lock(bool on)
        {
            busy = on;
            run.Text = on ? "Stop" : "Convert";
            browse.Enabled = outChange.Enabled = crop.Enabled = rate22.Enabled = rate32.Enabled =
                normalize.Enabled = !on;
        }

        // Проводник с выделенным файлом результата (или его папка, если файла ещё нет).
        void OpenFolder()
        {
            string output = OutputFile();
            try
            {
                if (File.Exists(output)) Process.Start("explorer.exe", "/select,\"" + output + "\"");
                else Process.Start("explorer.exe", "\"" + Path.GetDirectoryName(output) + "\"");
            }
            catch (Exception ex) { status.Text = "Could not open the folder: " + ex.Message; }
        }

        void Start()
        {
            string input = fileBox.Text;
            string output = OutputFile();
            string problem = Recipe.CheckWritable(output);
            if (problem != null)
            {
                status.Text = problem;
                if (MessageBox.Show(this, problem + "\r\n\r\nChoose another place for the result?", Text,
                                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes &&
                    ChooseOutput())
                    Start();
                return;
            }
            cancelled = false;
            Lock(true);
            bar.Value = 0;
            if (!source.HasAudio || !normalize.Checked)
            {
                Encode(input, output, null, "");
                return;
            }
            // Первый проход — замер уровня, в фоне: окно не замирает. Частоту
            // берём здесь: переключатели заблокированы до конца работы.
            status.Text = "Measuring audio level…";
            int rate = Rate;
            ThreadPool.QueueUserWorkItem(delegate
            {
                double? gain = null;
                try { gain = Recipe.MeasureLoudness(ffmpeg, input, rate, delegate(Process p) { measure = p; }); }
                catch (Exception) { }
                measure = null;
                Ui(delegate
                {
                    if (cancelled) { Lock(false); status.Text = "Stopped."; return; }
                    Encode(input, output, gain,
                           gain == null ? "\r\nAudio level measurement failed: the sound is not normalized." : "");
                });
            });
        }

        void Encode(string input, string output, double? gain, string note)
        {
            // Прежний файл с тем же именем удаляется при ошибке, только если
            // ffmpeg успел его изменить.
            bool existed = File.Exists(output);
            DateTime stamp = existed ? File.GetLastWriteTimeUtc(output) : DateTime.MinValue;
            ProcessStartInfo psi = new ProcessStartInfo(ffmpeg,
                Recipe.Arguments(input, output, outSize, source.HasAudio, Rate, gain, crop.Checked));
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardErrorEncoding = Encoding.UTF8;
            StringBuilder errors = new StringBuilder();
            double duration = source.Duration;
            worker = new Process();
            worker.StartInfo = psi;
            worker.EnableRaisingEvents = true;
            worker.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                // -progress: out_time_us=… — позиция в микросекундах.
                if (e.Data == null || !e.Data.StartsWith("out_time_us=") || duration <= 0) return;
                long us;
                if (!long.TryParse(e.Data.Substring(12), out us)) return;
                int percent = (int)Math.Max(0, Math.Min(100, us / 1e4 / duration));
                Ui(delegate
                {
                    bar.Value = percent;
                    status.Text = string.Format("Converting… {0}%", percent);
                });
            };
            worker.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data != null) lock (errors) { errors.AppendLine(e.Data); }
            };
            worker.Exited += delegate
            {
                Process done = worker;
                int code = done.ExitCode;
                // Готовая таблица перемотки — в поток завершения, до показа.
                int entries = 0;
                if (code == 0 && !cancelled)
                    try { entries = SeekIndex.Embed(output); }
                    catch (Exception) { entries = -1; }
                Ui(delegate
                {
                    done.Dispose();
                    worker = null;
                    Lock(false);
                    if (code == 0)
                    {
                        bar.Value = 100;
                        status.Text = "Done: " + output + (entries > 0
                            ? string.Format("\r\nSeek table embedded: {0} entries.", entries)
                            : "\r\nSeek table not embedded: the player builds it on the first seek.") + note;
                        // Кодирование идёт минутами, окно к концу часто свёрнуто.
                        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
                        MessageBox.Show(this, "Video converted", Text, MessageBoxButtons.OK,
                                        MessageBoxIcon.Information);
                    }
                    else
                    {
                        bar.Value = 0;
                        string all;
                        lock (errors) { all = errors.ToString(); }
                        if (cancelled) status.Text = "Stopped.";
                        else if (all.IndexOf("Permission denied", StringComparison.OrdinalIgnoreCase) >= 0)
                            status.Text = Recipe.FfmpegDenied(output, ffmpeg);
                        else status.Text = "ffmpeg error (code " + code + "): " + LastLines(all, 2);
                        try
                        {
                            if (File.Exists(output) && (!existed || File.GetLastWriteTimeUtc(output) != stamp))
                                File.Delete(output);
                        }
                        catch (IOException) { }
                        catch (UnauthorizedAccessException) { }
                    }
                });
            };
            worker.Start();
            worker.BeginOutputReadLine();
            worker.BeginErrorReadLine();
            status.Text = "Converting…";
        }

        void Cancel()
        {
            cancelled = true;
            Process p = worker ?? measure;
            if (p == null) return;
            try { if (!p.HasExited) p.Kill(); } catch (InvalidOperationException) { }
        }

        static string LastLines(string text, int count)
        {
            string[] lines = text.Trim().Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            int from = Math.Max(0, lines.Length - count);
            return string.Join(" ", lines, from, lines.Length - from);
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            if (args.Length >= 3 && args.Length <= 6 && (args[0] == "--batch" || args[0] == "--probe"))
            {
                int rate = Recipe.AudioRate;
                bool norm = true, crop = false;
                for (int i = 3; i < args.Length; ++i)
                {
                    if (args[i].StartsWith("32")) rate = 32000;
                    else if (args[i] == "nonorm") norm = false;
                    else if (args[i] == "crop43") crop = true;
                }
                return Batch(args[0], args[1], args[2], rate, norm, crop);
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            MainForm form = new MainForm();
            // Файл, перетащенный на значок программы.
            if (args.Length == 1 && File.Exists(args[0])) form.Shown += delegate { form.OpenSource(args[0]); };
            Application.Run(form);
            return 0;
        }

        // Пакетный режим для проверок и сценариев: журнал в UTF-8.
        static int Batch(string mode, string input, string log, int rate, bool norm, bool crop)
        {
            using (StreamWriter w = new StreamWriter(log, false, new UTF8Encoding(false)))
            {
                try
                {
                    string ffmpeg = Recipe.Ffmpeg();
                    SourceInfo s = Recipe.Probe(ffmpeg, input);
                    Size size = Recipe.OutputSize(crop ? Recipe.Crop43(s) : s);
                    string output = Recipe.OutputPath(input, size, rate);
                    w.WriteLine("size={0}x{1}", size.Width, size.Height);
                    w.WriteLine("output={0}", output);
                    w.WriteLine(Recipe.Describe(s, size, rate, crop));
                    string problem = Recipe.CheckWritable(output);
                    w.WriteLine("write={0}", problem ?? "ok");
                    if (mode == "--probe") return 0;
                    if (problem != null) return 2;
                    double? gain = s.HasAudio && norm ? Recipe.MeasureLoudness(ffmpeg, input, rate, null) : null;
                    w.WriteLine("gain={0}", gain.HasValue ? gain.Value.ToString("0.00", CultureInfo.InvariantCulture) + " dB"
                                                          : s.HasAudio && norm ? "failed" : "off");
                    ProcessStartInfo psi = new ProcessStartInfo(ffmpeg,
                        Recipe.Arguments(input, output, size, s.HasAudio, rate, gain, crop));
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    psi.RedirectStandardOutput = true;
                    psi.RedirectStandardError = true;
                    psi.StandardErrorEncoding = Encoding.UTF8;
                    using (Process p = Process.Start(psi))
                    {
                        p.OutputDataReceived += delegate { };
                        p.BeginOutputReadLine();
                        string err = p.StandardError.ReadToEnd();
                        p.WaitForExit();
                        w.WriteLine("exit={0}", p.ExitCode);
                        if (p.ExitCode != 0) { w.WriteLine(err); return 1; }
                        w.WriteLine("index={0}", SeekIndex.Embed(output));
                        return 0;
                    }
                }
                catch (Exception ex)
                {
                    w.WriteLine("error={0}", ex.Message);
                    return 2;
                }
            }
        }
    }
}
