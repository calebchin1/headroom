// Headroom for Windows: floating widget showing Claude Code and Codex plan usage as rings.
// Written in C# 5 so it compiles with the csc.exe that ships with .NET Framework 4.x on every
// Windows 10/11 machine; windows/build.ps1 compiles it with the C# compiler built into Windows. No XAML, no NuGet, no SDK.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;

[assembly: System.Reflection.AssemblyTitle("Headroom")]
[assembly: System.Reflection.AssemblyVersion("1.8.0.0")]

namespace Headroom
{
    // MARK: - Model

    class Limit
    {
        public string Id, Label;
        public double Percent;
        public DateTime? ResetsAt;   // UTC
        public Limit(string id, string label, double percent, DateTime? resetsAt)
        {
            Id = id; Label = label;
            Percent = (double.IsNaN(percent) || double.IsInfinity(percent)) ? 0 : Math.Min(Math.Max(percent, 0), 999);
            ResetsAt = resetsAt;
        }
    }

    enum Provider { Claude, Codex }

    static class P
    {
        public static Provider Other(Provider p) { return p == Provider.Claude ? Provider.Codex : Provider.Claude; }
        public static string Name(Provider p) { return p == Provider.Claude ? "Claude" : "Codex"; }
        public static Color Brand(Provider p)
        {
            return p == Provider.Claude ? Color.FromRgb(0xD9, 0x77, 0x57) : Color.FromRgb(0x10, 0xA3, 0x7F);
        }
        public static string UsageUrl(Provider p)
        {
            return p == Provider.Claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage";
        }
    }

    class FetchError : Exception
    {
        public double? RetryAfter;
        public FetchError(string m, double? retryAfter = null) : base(m) { RetryAfter = retryAfter; }
    }

    // MARK: - Fetching

    static class Api
    {
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

        static string Home { get { return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile); } }

        static Dictionary<string, object> ReadJson(string path)
        {
            try { return File.Exists(path) ? Json.DeserializeObject(File.ReadAllText(path)) as Dictionary<string, object> : null; }
            catch { return null; }
        }

        static object Get(object o, string key)
        {
            var d = o as Dictionary<string, object>;
            object v;
            return d != null && d.TryGetValue(key, out v) ? v : null;
        }

        static double? Num(object o)
        {
            if (o == null || o is string || o is bool) return null;
            try { return Convert.ToDouble(o, CultureInfo.InvariantCulture); } catch { return null; }
        }

        // Claude Code on Windows keeps its login in a plain file instead of a keychain.
        static string ClaudeToken()
        {
            var dir = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            if (string.IsNullOrEmpty(dir)) dir = System.IO.Path.Combine(Home, ".claude");
            return Get(Get(ReadJson(System.IO.Path.Combine(dir, ".credentials.json")), "claudeAiOauth"), "accessToken") as string;
        }

        static string CodexAuthPath()
        {
            var dir = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (string.IsNullOrEmpty(dir)) dir = System.IO.Path.Combine(Home, ".codex");
            return System.IO.Path.Combine(dir, "auth.json");
        }

        public static List<Limit> Fetch(Provider p)
        {
            var app = p == Provider.Claude ? "Claude Code" : "Codex";
            // HEADROOM_DEMO=<dir with claude.json / codex.json>: render canned responses (CI screenshots).
            var demo = Environment.GetEnvironmentVariable("HEADROOM_DEMO");
            if (!string.IsNullOrEmpty(demo))
            {
                var d = ReadJson(System.IO.Path.Combine(demo, p == Provider.Claude ? "claude.json" : "codex.json"));
                if (d == null) throw new FetchError("Demo file missing");
                return p == Provider.Claude ? Parse(d) : ParseCodex(d);
            }
            HttpWebRequest req;
            if (p == Provider.Claude)
            {
                var tok = ClaudeToken();
                if (tok == null) throw new FetchError("Log in to Claude Code with a Claude.ai plan");
                req = (HttpWebRequest)WebRequest.Create("https://api.anthropic.com/api/oauth/usage");
                req.Headers["Authorization"] = "Bearer " + tok;
                req.Headers["anthropic-beta"] = "oauth-2025-04-20";
            }
            else
            {
                var auth = ReadJson(CodexAuthPath());
                var tokens = Get(auth, "tokens");
                var tok = Get(tokens, "access_token") as string;
                if (tok == null)
                {
                    var key = Get(auth, "OPENAI_API_KEY") as string;
                    throw new FetchError(!string.IsNullOrEmpty(key) ? "Codex uses an API key · no plan limits" : "Log in to Codex with ChatGPT");
                }
                req = (HttpWebRequest)WebRequest.Create("https://chatgpt.com/backend-api/wham/usage");
                req.Headers["Authorization"] = "Bearer " + tok;
                var account = Get(tokens, "account_id") as string;
                if (account != null) req.Headers["ChatGPT-Account-Id"] = account;
                req.UserAgent = "codex_cli_rs";
            }
            req.Timeout = 15000;
            req.ReadWriteTimeout = 15000;
            req.Accept = "application/json";

            int status; string body;
            HttpWebResponse resp = null;
            try { resp = (HttpWebResponse)req.GetResponse(); }
            catch (WebException e)
            {
                resp = e.Response as HttpWebResponse;
                if (resp == null) throw new FetchError("Offline");
            }
            using (resp)
            {
                status = (int)resp.StatusCode;
                if (status == 429)
                {
                    double ra;
                    var h = resp.Headers["Retry-After"];
                    double wait = h != null && double.TryParse(h, NumberStyles.Float, CultureInfo.InvariantCulture, out ra) && !double.IsInfinity(ra)
                        ? Math.Min(Math.Max(ra, 0), 3600) : 300;
                    throw new FetchError("Rate limited", wait);
                }
                if (status == 401 || status == 403) throw new FetchError("Login expired — open " + app);
                using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) body = r.ReadToEnd();
            }
            Dictionary<string, object> json = null;
            try { json = Json.DeserializeObject(body) as Dictionary<string, object>; } catch { }
            if (status != 200 || json == null) throw new FetchError("Error " + status);
            return p == Provider.Claude ? Parse(json) : ParseCodex(json);
        }

        static DateTime? ParseDate(object s)
        {
            var str = s as string;
            DateTime d;
            if (str != null && DateTime.TryParse(str, CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out d)) return d;
            return null;
        }

        static Limit Window(object w, string id, string fallback)
        {
            if (!(w is Dictionary<string, object>)) return null;
            var pct = Num(Get(w, "used_percent")) ?? 0;
            var secs = Num(Get(w, "limit_window_seconds"));
            string label = fallback;
            if (secs.HasValue && secs.Value >= 6 * 86400) label = "Week";
            else if (secs.HasValue && secs.Value <= 6 * 3600) label = "Session";
            var reset = Num(Get(w, "reset_at"));
            DateTime? at = null;
            if (reset.HasValue) at = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(reset.Value);
            return new Limit(id, label, pct, at);
        }

        static List<Limit> ParseCodex(Dictionary<string, object> json)
        {
            var o = new List<Limit>();
            var rl = Get(json, "rate_limit");
            if (rl != null)
            {
                var a = Window(Get(rl, "primary_window"), "primary", "Session"); if (a != null) o.Add(a);
                var b = Window(Get(rl, "secondary_window"), "secondary", "Week"); if (b != null) o.Add(b);
            }
            var extra = Get(json, "additional_rate_limits") as object[];
            if (extra != null)
            {
                for (int i = 0; i < extra.Length; i++)
                {
                    var e = extra[i];
                    var name = (Get(e, "limit_name") as string) ?? (Get(e, "metered_feature") as string) ?? "Extra";
                    var r = Get(e, "rate_limit") ?? e;
                    var l = Window(Get(r, "primary_window"), "extra-" + i, Cap(name));
                    if (l != null) o.Add(l);
                }
            }
            return o;
        }

        static string Cap(string s)
        {
            return CultureInfo.InvariantCulture.TextInfo.ToTitleCase(s.Replace('_', ' ').ToLowerInvariant());
        }

        static List<Limit> Parse(Dictionary<string, object> json)
        {
            var o = new List<Limit>();
            var fh = Get(json, "five_hour");
            var fu = Num(Get(fh, "utilization"));
            if (fu.HasValue) o.Add(new Limit("five_hour", "Session", fu.Value, ParseDate(Get(fh, "resets_at"))));
            var limits = Get(json, "limits") as object[];
            if (limits != null)
            {
                for (int i = 0; i < limits.Length; i++)
                {
                    var l = limits[i];
                    var pct = Num(Get(l, "percent"));
                    if (!pct.HasValue) continue;
                    var kind = (Get(l, "kind") as string) ?? "limit";
                    var group = (Get(l, "group") as string) ?? "";
                    var model = Get(Get(Get(l, "scope"), "model"), "display_name") as string;
                    string label;
                    if (model != null) label = model;
                    else if (kind == "weekly_all") label = "Week";
                    else if (group.Contains("session") || kind.Contains("five") || kind.Contains("session"))
                    {
                        if (o.Any(x => x.Id == "five_hour")) continue;
                        label = "Session";
                    }
                    else label = group.Length == 0 ? kind : Cap(group);
                    o.Add(new Limit(kind + "-" + (model ?? "") + "-" + i, label, pct.Value, ParseDate(Get(l, "resets_at"))));
                }
            }
            else
            {
                var keys = new[] { "seven_day", "seven_day_opus", "seven_day_sonnet" };
                var labels = new[] { "Week", "Opus", "Sonnet" };
                for (int i = 0; i < keys.Length; i++)
                {
                    var w = Get(json, keys[i]);
                    var u = Num(Get(w, "utilization"));
                    if (u.HasValue) o.Add(new Limit(keys[i], labels[i], u.Value, ParseDate(Get(w, "resets_at"))));
                }
            }
            return o;
        }
    }

    class UsageStore
    {
        public readonly Provider Provider;
        public List<Limit> Limits = new List<Limit>();
        public string Error;
        public DateTime? Updated;
        public event Action Changed;
        DateTime nextAllowed = DateTime.MinValue;
        double backoff = 300;
        bool inFlight;
        readonly Dispatcher ui;

        public UsageStore(Provider p, Dispatcher ui) { Provider = p; this.ui = ui; }

        public void Refresh()
        {
            if (inFlight || DateTime.UtcNow < nextAllowed) return;
            inFlight = true;
            Task.Run(() =>
            {
                List<Limit> result = null; FetchError err = null;
                try { result = Api.Fetch(Provider); }
                catch (FetchError e) { err = e; }
                catch (Exception e) { err = new FetchError("Error: " + e.GetType().Name); }
                ui.BeginInvoke(new Action(() =>
                {
                    inFlight = false;
                    if (result != null)
                    {
                        Limits = result; Error = null; Updated = DateTime.UtcNow; backoff = 300;
                        nextAllowed = DateTime.UtcNow.AddSeconds(60);
                    }
                    else if (err.RetryAfter.HasValue)
                    {
                        var delay = Math.Min(Math.Max(err.RetryAfter.Value, backoff), 3600);
                        backoff = Math.Min(backoff * 2, 3600);
                        nextAllowed = DateTime.UtcNow.AddSeconds(delay);
                        Error = "Rate limited · retrying in " + (int)Math.Ceiling(delay / 60) + "m";
                    }
                    else Error = err.Message;
                    if (Changed != null) Changed();
                }));
            });
        }
    }

    // MARK: - Settings (HKCU\Software\Headroom)

    static class Settings
    {
        const string KeyPath = @"Software\Headroom";
        public static string Get(string name)
        {
            using (var k = Registry.CurrentUser.OpenSubKey(KeyPath)) return k == null ? null : k.GetValue(name) as string;
        }
        public static void Set(string name, string value)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(KeyPath)) k.SetValue(name, value);
        }
        const string RunPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

        /// "Start at Login" (on by default, toggled from the menu): a per-user Run entry pointing at wherever this exe lives.
        public static bool StartAtLogin
        {
            get { return Get("startAtLogin") != "0"; }
            set
            {
                Set("startAtLogin", value ? "1" : "0");
                try
                {
                    using (var k = Registry.CurrentUser.CreateSubKey(RunPath))
                    {
                        if (value) k.SetValue("Headroom", "\"" + Process.GetCurrentProcess().MainModule.FileName + "\"");
                        else k.DeleteValue("Headroom", false);
                    }
                }
                catch { }
            }
        }

        public static void DeleteAll()
        {
            try { Registry.CurrentUser.DeleteSubKeyTree(KeyPath, false); } catch { }
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(RunPath, true))
                    if (k != null) k.DeleteValue("Headroom", false);
            }
            catch { }
        }
    }

    // MARK: - Views

    static class Fmt
    {
        public static string Ago(DateTime d, DateTime now)
        {
            var s = Math.Max(0, (int)(now - d).TotalSeconds);
            if (s < 60) return "just now";
            if (s < 3600) return s / 60 + "m ago";
            if (s < 86400) return s / 3600 + "h ago";
            return s / 86400 + "d ago";
        }
        public static string Reset(DateTime? d, DateTime now)
        {
            if (!d.HasValue) return " ";
            var s = (long)Math.Min(Math.Max(0, (d.Value - now).TotalSeconds), 1e9);
            long days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60;
            if (days > 0) return days + "d " + h + "h";
            if (h > 0) return h + "h " + m + "m";
            return m + "m";
        }
    }

    class Widget : Window
    {
        static readonly Color Red = Color.FromRgb(0xFF, 0x45, 0x3A);
        static readonly Color Orange = Color.FromRgb(0xFF, 0x9F, 0x0A);
        static readonly Brush Primary = new SolidColorBrush(Color.FromArgb(0xF2, 0xFF, 0xFF, 0xFF));
        static readonly Brush Secondary = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF));
        static readonly Brush Tertiary = new SolidColorBrush(Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF));
        static readonly FontFamily Font = new FontFamily("Segoe UI Variable Text, Segoe UI");
        static readonly FontFamily Icons = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets");

        readonly Dictionary<Provider, UsageStore> stores = new Dictionary<Provider, UsageStore>();
        Provider selected;
        readonly Border root;
        bool positioned;

        public Widget()
        {
            Title = "Headroom";
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            Topmost = true;
            SizeToContent = SizeToContent.WidthAndHeight;
            UseLayoutRounding = true;
            FontFamily = Font;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

            selected = Settings.Get("provider") == "codex" ? Provider.Codex : Provider.Claude;
            foreach (Provider p in Enum.GetValues(typeof(Provider)))
            {
                var s = new UsageStore(p, Dispatcher);
                s.Changed += () => { if (s.Provider == selected) Render(); };
                stores[p] = s;
            }

            root = new Border
            {
                CornerRadius = new CornerRadius(16),
                Background = new LinearGradientBrush(Color.FromArgb(0xEE, 0x2B, 0x2B, 0x2E), Color.FromArgb(0xEE, 0x1E, 0x1E, 0x20), 90),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(16, 14, 16, 14),
                Margin = new Thickness(12),   // room for the shadow
                Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Opacity = 0.45, Direction = 270 },
                Cursor = Cursors.Hand,
            };
            Content = root;

            root.MouseLeftButtonDown += OnMouseDown;
            root.MouseRightButtonUp += (s, e) => { ShowMenu(); e.Handled = true; };
            SizeChanged += OnSizeChanged;
            SourceInitialized += (s, e) => HideFromAltTab();
            Loaded += (s, e) => PlaceInitially();

            Render();
            foreach (var st in stores.Values) st.Refresh();
            var refresh = new DispatcherTimer { Interval = TimeSpan.FromMinutes(5) };
            refresh.Tick += (s, e) => { foreach (var st in stores.Values) st.Refresh(); };
            refresh.Start();
            var tick = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
            tick.Tick += (s, e) => Render();
            tick.Start();
            SystemEvents.PowerModeChanged += (s, e) =>
            {
                if (e.Mode == PowerModes.Resume)
                    Dispatcher.BeginInvoke(new Action(() => { foreach (var st in stores.Values) st.Refresh(); }));
            };
        }

        // MARK: Layout

        void Render()
        {
            var store = stores[selected];
            var now = DateTime.UtcNow;
            var brand = P.Brand(selected);
            var panel = new StackPanel();

            var header = new DockPanel { LastChildFill = false, Margin = new Thickness(2, 0, 0, 8) };
            var name = Text(P.Name(selected), 11, new SolidColorBrush(brand), FontWeights.SemiBold);
            DockPanel.SetDock(name, Dock.Left);
            header.Children.Add(name);
            if (store.Updated.HasValue && store.Limits.Count > 0)
            {
                var ago = Text(Fmt.Ago(store.Updated.Value, now), 10, Tertiary, FontWeights.Medium);
                ago.Margin = new Thickness(16, 0, 0, 0);
                ago.ToolTip = "Checked " + store.Updated.Value.ToLocalTime().ToShortTimeString();
                DockPanel.SetDock(ago, Dock.Right);
                header.Children.Add(ago);
            }
            panel.Children.Add(header);

            if (store.Limits.Count == 0)
            {
                var msg = Text(store.Error ?? "Loading usage…", 12, Secondary, FontWeights.Normal);
                msg.MinWidth = 140; msg.Margin = new Thickness(2, 4, 0, 6);
                panel.Children.Add(msg);
            }
            else
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                foreach (var l in store.Limits) row.Children.Add(Ring(l, now));
                panel.Children.Add(row);
                if (store.Error != null)
                {
                    var e = Text(store.Error, 10, Secondary, FontWeights.Normal);
                    e.Margin = new Thickness(2, 6, 0, 0);
                    panel.Children.Add(e);
                }
            }
            root.Child = panel;
            root.ToolTip = "Click to show " + P.Name(P.Other(selected));
        }

        static TextBlock Text(string s, double size, Brush fg, FontWeight w)
        {
            return new TextBlock { Text = s, FontSize = size, Foreground = fg, FontWeight = w };
        }

        UIElement Ring(Limit l, DateTime now)
        {
            const double size = 58, line = 6;
            var brand = P.Brand(selected);
            var critical = l.Percent >= 90;
            var warning = l.Percent >= 75;
            var color = critical ? Red : brand;
            var frac = Math.Min(Math.Max(l.Percent / 100, 0), 1);
            var pct = (int)Math.Round(l.Percent, MidpointRounding.AwayFromZero);

            var g = new Grid { Width = size, Height = size };
            g.Children.Add(new Ellipse
            {
                Stroke = new SolidColorBrush(Color.FromArgb(0x24, brand.R, brand.G, brand.B)),
                StrokeThickness = line,
            });
            if (frac > 0.002)
            {
                var arc = new System.Windows.Shapes.Path
                {
                    Data = Arc(size, line, frac),
                    Stroke = new SolidColorBrush(color),
                    StrokeThickness = line,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round,
                    Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = color, BlurRadius = 6, ShadowDepth = 0, Opacity = 0.5 },
                };
                g.Children.Add(arc);
            }
            var num = new TextBlock { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Foreground = Primary };
            num.Inlines.Add(new System.Windows.Documents.Run(pct.ToString()) { FontSize = 17, FontWeight = FontWeights.SemiBold });
            num.Inlines.Add(new System.Windows.Documents.Run("%") { FontSize = 10, FontWeight = FontWeights.SemiBold, Foreground = Secondary });
            g.Children.Add(num);

            var labelRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 5, 0, 0) };
            if (warning)
            {
                labelRow.Children.Add(new TextBlock
                {
                    Text = "", FontFamily = Icons, FontSize = 9, VerticalAlignment = VerticalAlignment.Center,
                    Foreground = new SolidColorBrush(critical ? Red : Orange), Margin = new Thickness(0, 0, 3, 0),
                });
            }
            labelRow.Children.Add(new TextBlock { Text = l.Label, FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = Primary, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 64 });

            var reset = Text(Fmt.Reset(l.ResetsAt, now), 10, Secondary, FontWeights.Normal);
            reset.HorizontalAlignment = HorizontalAlignment.Center;
            reset.Margin = new Thickness(0, 1, 0, 0);

            var col = new StackPanel { Width = 70, Margin = new Thickness(0, 0, 0, 0) };
            col.Children.Add(g); col.Children.Add(labelRow); col.Children.Add(reset);
            col.ToolTip = l.Label + ": " + pct + "% used" +
                (l.ResetsAt.HasValue ? " · resets " + l.ResetsAt.Value.ToLocalTime().ToString("ddd MMM d, h:mm tt", CultureInfo.CurrentCulture) : "");
            return col;
        }

        // Clockwise arc from 12 o'clock covering `frac` of the circle.
        static Geometry Arc(double size, double line, double frac)
        {
            var r = (size - line) / 2;
            var c = size / 2;
            if (frac >= 0.9999) return new EllipseGeometry(new Point(c, c), r, r);
            var a = frac * 2 * Math.PI;
            var start = new Point(c, c - r);
            var end = new Point(c + r * Math.Sin(a), c - r * Math.Cos(a));
            var geo = new StreamGeometry();
            using (var ctx = geo.Open())
            {
                ctx.BeginFigure(start, false, false);
                ctx.ArcTo(end, new Size(r, r), 0, frac > 0.5, SweepDirection.Clockwise, true, false);
            }
            geo.Freeze();
            return geo;
        }

        // MARK: Interaction

        void OnMouseDown(object sender, MouseButtonEventArgs e)
        {
            double l = Left, t = Top;
            try { DragMove(); } catch (InvalidOperationException) { }
            if (Math.Abs(Left - l) < 3 && Math.Abs(Top - t) < 3) Toggle();
            else SavePosition();
        }

        void Toggle()
        {
            selected = P.Other(selected);
            Settings.Set("provider", selected == Provider.Codex ? "codex" : "claude");
            Render();
        }

        // Keep the edge nearest the screen side pinned while the content changes size.
        void OnSizeChanged(object sender, SizeChangedEventArgs e)
        {
            if (!positioned || !e.WidthChanged || e.PreviousSize.Width == 0) return;
            var mid = SystemParameters.WorkArea.Left + SystemParameters.WorkArea.Width / 2;
            if (Left + e.PreviousSize.Width / 2 > mid) Left -= e.NewSize.Width - e.PreviousSize.Width;
        }

        void PlaceInitially()
        {
            double x, y;
            var vs = new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop,
                              SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight);
            var saved = Settings.Get("position");
            var parts = saved == null ? null : saved.Split(',');
            if (parts != null && parts.Length == 2
                && double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out x)
                && double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out y)
                && vs.Contains(new Point(x + 40, y + 40)))
            {
                Left = x; Top = y;
            }
            else
            {
                var wa = SystemParameters.WorkArea;
                Left = wa.Right - ActualWidth - 8;
                Top = wa.Top + 8;
            }
            positioned = true;
        }

        void SavePosition()
        {
            Settings.Set("position", Left.ToString(CultureInfo.InvariantCulture) + "," + Top.ToString(CultureInfo.InvariantCulture));
        }

        void ShowMenu()
        {
            var store = stores[selected];
            var m = new ContextMenu();
            if (store.Updated.HasValue)
            {
                m.Items.Add(new MenuItem { Header = P.Name(selected) + " · updated " + store.Updated.Value.ToLocalTime().ToShortTimeString(), IsEnabled = false });
                m.Items.Add(new Separator());
            }
            Add(m, "Show " + P.Name(P.Other(selected)), Toggle);
            Add(m, "Refresh Now", () => store.Refresh());
            Add(m, "Open " + P.Name(selected) + " Usage Page", () =>
            {
                try { Process.Start(new ProcessStartInfo(P.UsageUrl(selected)) { UseShellExecute = true }); } catch { }
            });
            m.Items.Add(new Separator());
            var login = new MenuItem { Header = "Start at Login", IsCheckable = true, IsChecked = Settings.StartAtLogin };
            login.Click += (s, e) => Settings.StartAtLogin = login.IsChecked;
            m.Items.Add(login);
            Add(m, "Uninstall Headroom…", Uninstall);
            Add(m, "Quit", () => Application.Current.Shutdown());
            m.PlacementTarget = root;
            m.IsOpen = true;
        }

        static void Add(ContextMenu m, string header, Action a)
        {
            var i = new MenuItem { Header = header };
            i.Click += (s, e) => a();
            m.Items.Add(i);
        }

        void Uninstall()
        {
            var exe = Process.GetCurrentProcess().MainModule.FileName;
            var r = MessageBox.Show(this, "Removes Headroom's startup entry and settings, then quits.\n\nAfterwards, delete this file to finish:\n" + exe,
                                    "Uninstall Headroom?", MessageBoxButton.OKCancel, MessageBoxImage.Question);
            if (r != MessageBoxResult.OK) return;
            Settings.DeleteAll();
            // Show the exe in Explorer so it can be deleted; we can't delete ourselves while running.
            try { Process.Start("explorer.exe", "/select,\"" + exe + "\""); } catch { }
            Application.Current.Shutdown();
        }

        // WS_EX_TOOLWINDOW keeps the widget out of Alt+Tab.
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
        void HideFromAltTab()
        {
            var h = new WindowInteropHelper(this).Handle;
            SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x80);
        }
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            // .NET Framework defaults to TLS 1.0 for exes without a target-framework attribute.
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072 | (SecurityProtocolType)768;
            bool fresh;
            using (var mutex = new Mutex(true, @"Local\Headroom", out fresh))
            {
                if (!fresh) return;
                // Re-point the startup entry at this exe (covers first run and the file being moved).
                if (Settings.StartAtLogin) Settings.StartAtLogin = true;
                var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
                app.DispatcherUnhandledException += (s, e) => { e.Handled = true; };
                app.Run(new Widget());
            }
        }
    }
}
