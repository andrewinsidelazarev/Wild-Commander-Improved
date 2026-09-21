// FTView Convert — перекодирование видео в MJPEG AVI для плагина FTView
// (VDAC2/FT812, звук на General Sound или FT812).
//
// Выход: MJPEG baseline 4:2:0 со стандартными таблицами Хаффмана, 24 кадра/с,
// ~2 Мбит/с (как у проверенного образца Muse, около 250 КБ/с с SD),
// звук 8 бит моно 22 050 Гц, индекс idx1 для быстрой перемотки. Звук — под
// устройство вывода: для GS беззнаковый PCM (его ЦАП), для FT812 — µ-law,
// родной формат звукового блока FT812 с большим динамическим диапазоном.
// Разрешение — наибольшее при исходном соотношении сторон: стороны кратны
// 16 (блок JPEG 4:2:0), площадь не больше 512×384 = 196 608 точек — предел
// плеера, при котором работают и звук FT812, и таблица перемотки в RAM_G;
// ширина до 1024, высота до 688 (область кадра 1024×700), не больше исходника.
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
// Пакетный режим без окна: FTViewConvert.exe --batch <вход> <журнал> [gs|ft812]
// (код выхода 0 — успех); --probe <вход> <журнал> — только расчёт размера.
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
    }

    static class Recipe
    {
        public const int OutFps = 24;
        public const int MaxArea = 512 * 384;
        public const int MaxWidth = 1024;
        public const int MaxHeight = 688;
        public const int AudioRate = 22050;
        const string FfmpegResource = "FTViewConvert.ffmpeg.exe";
        public const string FfmpegVersion = "9.0.2";

        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // ffmpeg.exe из ресурса — в каталог пользователя (один раз на версию).
        public static string Ffmpeg()
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream src = asm.GetManifestResourceStream(FfmpegResource))
            {
                if (src == null) throw new InvalidOperationException("В программе нет встроенного ffmpeg.exe");
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
            if (!video.Success) throw new InvalidDataException("В файле не найден видеопоток");
            Match size = Regex.Match(video.Value, @"(?<![\dx])(\d{2,5})x(\d{2,5})(?![\dx])");
            if (!size.Success) throw new InvalidDataException("Не удалось определить размер кадра");
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

        // Наибольший кадр со сторонами, кратными 16, при соотношении сторон
        // исходника: площадь не больше MaxArea, не больше самого исходника.
        public static Size OutputSize(SourceInfo s)
        {
            int capW = Math.Max(16, (int)Math.Ceiling(s.Height * s.Aspect / 16.0) * 16);
            int capH = Math.Max(16, (int)Math.Ceiling(s.Height / 16.0) * 16);
            Size best = new Size(0, 0);
            double bestErr = 0;
            for (int w = 16; w <= MaxWidth; w += 16)
            {
                int h = (int)Math.Round(w / s.Aspect / 16.0) * 16;
                if (h < 16 || h > MaxHeight || w * h > MaxArea || w > capW || h > capH) continue;
                double err = Math.Abs((double)w / h - s.Aspect) / s.Aspect;
                if (w * h > best.Width * best.Height || (w * h == best.Width * best.Height && err < bestErr))
                {
                    best = new Size(w, h);
                    bestErr = err;
                }
            }
            if (best.Width == 0) best = new Size(16, 16);
            return best;
        }

        public static string OutputPath(string input, Size size, bool ft812)
        {
            string dir = Path.GetDirectoryName(Path.GetFullPath(input));
            string name = Path.GetFileNameWithoutExtension(input);
            return Path.Combine(dir, string.Format(Inv, "{0} - FTView {1}x{2} 24p {3}.avi",
                                                   name, size.Width, size.Height, ft812 ? "FT812" : "GS"));
        }

        public static string Arguments(string input, string output, Size size, bool audio, bool ft812)
        {
            StringBuilder a = new StringBuilder();
            a.Append("-hide_banner -nostdin -y -nostats -progress pipe:1 -i ").Append(Quote(input));
            a.Append(" -map 0:v:0");
            if (audio) a.Append(" -map 0:a:0");
            a.AppendFormat(Inv, " -vf \"fps={0},scale={1}:{2}:flags=lanczos,setsar=1,format=yuvj420p\"",
                           OutFps, size.Width, size.Height);
            a.Append(" -c:v mjpeg -huffman default -b:v 2000k -maxrate 2600k -bufsize 2000k");
            if (audio) a.AppendFormat(Inv, " -c:a {0} -ar {1} -ac 1", ft812 ? "pcm_mulaw" : "pcm_u8", AudioRate);
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
                if (!Directory.Exists(dir)) return "Папка «" + dir + "» не найдена.";
                if (File.Exists(output))
                {
                    if ((File.GetAttributes(output) & FileAttributes.ReadOnly) != 0)
                        return "Файл «" + name + "» уже есть и помечен «только для чтения». " +
                               "Выберите другое имя или снимите этот атрибут.";
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
                    return "Файл «" + name + "» открыт в другой программе (например, в плеере). " +
                           "Закройте её или выберите другое имя.";
                return ex.Message;
            }
        }

        static string AccessDenied(string dir)
        {
            StringBuilder s = new StringBuilder();
            s.Append("Windows не разрешает записать файл в папку «").Append(dir).Append("». ");
            bool cfa = ControlledFolderAccess(), limited = LimitedAdmin();
            if (cfa)
                s.Append("Включён «Контролируемый доступ к папкам» Защитника Windows: если папка под его " +
                         "защитой, разрешите в нём FTViewConvert.exe и ffmpeg. ");
            if (limited)
                s.Append(cfa ? "Ещё возможно, что " : "Похоже, ")
                 .Append("писать туда можно только с правами администратора (проводник в этом случае " +
                         "спрашивает разрешение): запустите программу от имени администратора. ");
            if (!cfa && !limited) s.Append("У этой учётной записи нет права записи в папку. ");
            return s.Append("Проще всего — сохранить результат в другую папку.").ToString();
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
            return "ffmpeg не смог записать «" + Path.GetFileName(output) + "»: доступ запрещён, хотя сама " +
                   "программа писать в эту папку может. Обычно так ffmpeg блокирует «Контролируемый доступ " +
                   "к папкам» Защитника Windows или антивирус: разрешите " + ffmpeg +
                   " или выберите другую папку.";
        }

        public static string Describe(SourceInfo s, Size size, bool ft812)
        {
            return string.Format(Inv,
                "Исходник: {0}×{1}, {2:0.###}:1{3}{4}, звук: {5}\r\n" +
                "Результат: {6}×{7}, {8} кадр/с, MJPEG ~2 Мбит/с{9}",
                s.Width, s.Height, s.Aspect,
                s.Fps.Length > 0 ? ", " + s.Fps + " кадр/с" : "",
                s.Rotation != 0 ? string.Format(Inv, ", поворот {0}°", s.Rotation) : "",
                s.HasAudio ? "есть" : "нет",
                size.Width, size.Height, OutFps,
                !s.HasAudio ? ", без звука" :
                string.Format(Inv, ft812 ? ", µ-law 8 бит моно {0} Гц (FT812)" : ", PCM 8 бит моно {0} Гц (GS)", AudioRate));
        }
    }

    class MainForm : Form
    {
        readonly TextBox fileBox = new TextBox();
        readonly Button browse = new Button();
        readonly TextBox outBox = new TextBox();
        readonly Button outChange = new Button();
        readonly Label info = new Label();
        readonly RadioButton forGs = new RadioButton();
        readonly RadioButton forFt812 = new RadioButton();
        readonly Button run = new Button();
        readonly ProgressBar bar = new ProgressBar();
        readonly Label status = new Label();
        string ffmpeg;
        SourceInfo source;
        Size outSize;
        string outDir;     // папка результата; null — рядом с исходником
        string outName;    // своё имя файла для текущего исходника; null — по шаблону
        Process worker;
        bool cancelled;

        public MainForm()
        {
            Text = "FTView — перекодирование видео";
            using (Stream icon = Assembly.GetExecutingAssembly().GetManifestResourceStream("FTViewConvert.app.ico"))
                if (icon != null) Icon = new Icon(icon);
            Font = new Font("Segoe UI", 9f);
            AutoScaleDimensions = new SizeF(96f, 96f);
            AutoScaleMode = AutoScaleMode.Dpi;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(560, 276);

            Label fileLabel = new Label();
            fileLabel.Text = "Видеофайл:";
            fileLabel.SetBounds(12, 15, 84, 20);
            fileBox.SetBounds(98, 12, 354, 23);
            fileBox.ReadOnly = true;
            browse.Text = "Выбрать…";
            browse.SetBounds(460, 11, 88, 25);
            browse.Click += delegate { Browse(); };

            Label outLabel = new Label();
            outLabel.Text = "Сохранить в:";
            outLabel.SetBounds(12, 47, 84, 20);
            outBox.SetBounds(98, 44, 354, 23);
            outBox.ReadOnly = true;
            outChange.Text = "Изменить…";
            outChange.SetBounds(460, 43, 88, 25);
            outChange.Enabled = false;
            outChange.Click += delegate { ChooseOutput(); };

            info.SetBounds(12, 78, 536, 40);
            info.Text = "Выберите видеофайл: разрешение будет рассчитано автоматически.";

            // Звук под устройство вывода плеера: GS — PCM, FT812 — µ-law.
            Label soundLabel = new Label();
            soundLabel.Text = "Звук для:";
            soundLabel.SetBounds(12, 130, 80, 20);
            forGs.Text = "General Sound (PCM 8 бит)";
            forGs.SetBounds(92, 127, 200, 24);
            forGs.Checked = true;
            forFt812.Text = "FT812 (µ-law)";
            forFt812.SetBounds(300, 127, 200, 24);
            forGs.CheckedChanged += delegate { ShowTarget(); };

            run.Text = "Выполнить";
            run.SetBounds(12, 162, 120, 30);
            run.Enabled = false;
            run.Click += delegate { if (worker == null) Start(); else Cancel(); };

            bar.SetBounds(142, 166, 406, 22);
            status.SetBounds(12, 202, 536, 66);

            Controls.AddRange(new Control[] { fileLabel, fileBox, browse, outLabel, outBox, outChange, info,
                                              soundLabel, forGs, forFt812, run, bar, status });
            AllowDrop = true;
            DragEnter += delegate(object s, DragEventArgs e)
            {
                if (worker == null && e.Data.GetDataPresent(DataFormats.FileDrop)) e.Effect = DragDropEffects.Copy;
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
                dlg.Title = "Видео для FTView";
                dlg.Filter = "Видео|*.mp4;*.mkv;*.avi;*.mov;*.webm;*.m4v;*.mpg;*.mpeg;*.ts;*.wmv;*.flv|Все файлы|*.*";
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
            run.Enabled = outChange.Enabled = false;
            bar.Value = 0;
            status.Text = "Анализ файла…";
            info.Text = "";
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    if (ffmpeg == null) ffmpeg = Recipe.Ffmpeg();
                    SourceInfo s = Recipe.Probe(ffmpeg, path);
                    Size size = Recipe.OutputSize(s);
                    Ui(delegate
                    {
                        source = s;
                        outSize = size;
                        ShowTarget();
                        run.Enabled = outChange.Enabled = true;
                    });
                }
                catch (Exception ex)
                {
                    Ui(delegate { status.Text = "Ошибка: " + ex.Message; });
                }
            });
        }

        // Файл результата: имя по шаблону (или выбранное), папка — выбранная
        // или папка исходника.
        string OutputFile()
        {
            string auto = Recipe.OutputPath(fileBox.Text, outSize, forFt812.Checked);
            return Path.Combine(outDir ?? Path.GetDirectoryName(auto), outName ?? Path.GetFileName(auto));
        }

        // Папка сохраняется и для следующих файлов, своё имя — только для этого.
        bool ChooseOutput()
        {
            using (SaveFileDialog dlg = new SaveFileDialog())
            {
                string current = OutputFile();
                dlg.Title = "Куда сохранить результат";
                dlg.Filter = "AVI для FTView|*.avi";
                dlg.InitialDirectory = Path.GetDirectoryName(current);
                dlg.FileName = Path.GetFileName(current);
                if (dlg.ShowDialog(this) != DialogResult.OK) return false;
                string auto = Path.GetFileName(Recipe.OutputPath(fileBox.Text, outSize, forFt812.Checked));
                string chosen = Path.GetFileName(dlg.FileName);
                outDir = Path.GetDirectoryName(dlg.FileName);
                outName = string.Equals(chosen, auto, StringComparison.OrdinalIgnoreCase) ? null : chosen;
                ShowTarget();
                return true;
            }
        }

        void ShowTarget()
        {
            if (source == null || worker != null) return;
            info.Text = Recipe.Describe(source, outSize, forFt812.Checked);
            string output = OutputFile();
            ShowEnd(outBox, output);
            string problem = Recipe.CheckWritable(output);
            status.Text = problem ?? (File.Exists(output) ? "Файл с таким именем уже есть — он будет заменён." : "");
        }

        void Start()
        {
            string input = fileBox.Text;
            bool ft812 = forFt812.Checked;
            string output = OutputFile();
            string problem = Recipe.CheckWritable(output);
            if (problem != null)
            {
                status.Text = problem;
                if (MessageBox.Show(this, problem + "\r\n\r\nВыбрать другое место для результата?", Text,
                                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes &&
                    ChooseOutput())
                    Start();
                return;
            }
            // Прежний файл с тем же именем удаляется при ошибке, только если
            // ffmpeg успел его изменить.
            bool existed = File.Exists(output);
            DateTime stamp = existed ? File.GetLastWriteTimeUtc(output) : DateTime.MinValue;
            ProcessStartInfo psi = new ProcessStartInfo(ffmpeg, Recipe.Arguments(input, output, outSize, source.HasAudio, ft812));
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardErrorEncoding = Encoding.UTF8;
            StringBuilder errors = new StringBuilder();
            double duration = source.Duration;
            cancelled = false;
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
                    status.Text = string.Format("Перекодирование… {0}%", percent);
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
                Ui(delegate
                {
                    done.Dispose();
                    worker = null;
                    run.Text = "Выполнить";
                    browse.Enabled = outChange.Enabled = forGs.Enabled = forFt812.Enabled = true;
                    if (code == 0)
                    {
                        bar.Value = 100;
                        status.Text = "Готово: " + output;
                    }
                    else
                    {
                        bar.Value = 0;
                        string all;
                        lock (errors) { all = errors.ToString(); }
                        if (cancelled) status.Text = "Остановлено.";
                        else if (all.IndexOf("Permission denied", StringComparison.OrdinalIgnoreCase) >= 0)
                            status.Text = Recipe.FfmpegDenied(output, ffmpeg);
                        else status.Text = "Ошибка ffmpeg (код " + code + "): " + LastLines(all, 2);
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
            run.Text = "Остановить";
            browse.Enabled = outChange.Enabled = forGs.Enabled = forFt812.Enabled = false;
            bar.Value = 0;
            status.Text = "Перекодирование…";
        }

        void Cancel()
        {
            Process p = worker;
            if (p == null) return;
            cancelled = true;
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
            if ((args.Length == 3 || args.Length == 4) && (args[0] == "--batch" || args[0] == "--probe"))
                return Batch(args[0], args[1], args[2], args.Length == 4 && args[3].ToLowerInvariant() == "ft812");
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            MainForm form = new MainForm();
            // Файл, перетащенный на значок программы.
            if (args.Length == 1 && File.Exists(args[0])) form.Shown += delegate { form.OpenSource(args[0]); };
            Application.Run(form);
            return 0;
        }

        // Пакетный режим для проверок и сценариев: журнал в UTF-8.
        static int Batch(string mode, string input, string log, bool ft812)
        {
            using (StreamWriter w = new StreamWriter(log, false, new UTF8Encoding(false)))
            {
                try
                {
                    string ffmpeg = Recipe.Ffmpeg();
                    SourceInfo s = Recipe.Probe(ffmpeg, input);
                    Size size = Recipe.OutputSize(s);
                    string output = Recipe.OutputPath(input, size, ft812);
                    w.WriteLine("size={0}x{1}", size.Width, size.Height);
                    w.WriteLine("output={0}", output);
                    w.WriteLine(Recipe.Describe(s, size, ft812));
                    string problem = Recipe.CheckWritable(output);
                    w.WriteLine("write={0}", problem ?? "ok");
                    if (mode == "--probe") return 0;
                    if (problem != null) return 2;
                    ProcessStartInfo psi = new ProcessStartInfo(ffmpeg, Recipe.Arguments(input, output, size, s.HasAudio, ft812));
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
                        if (p.ExitCode != 0) w.WriteLine(err);
                        return p.ExitCode == 0 ? 0 : 1;
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
