namespace G4 {

    // ── SPI: Lyrics Provider ─────────────────────────────────────────────────
    //
    // Extend lyrics sources by subclassing LyricsProvider and registering
    // the instance via LyricsProviderRegistry.register() before the first
    // play-back starts.  Each built-in provider is enabled / disabled through
    // a GSettings boolean key named  "lyrics-<id>-enabled".
    // Externally registered providers whose key is absent from the schema are
    // treated as always-enabled.

    public abstract class LyricsProvider : Object {
        // Stable identifier used as part of the GSettings key name.
        public abstract string id { get; }
        // Label shown in the Preferences → Lyrics group.
        public abstract string display_name { get; }
        // Optional one-line description shown as a subtitle.
        public virtual string description { get { return ""; } }

        // Fetch lyrics for @music.  Return null when unavailable or on error.
        public abstract async GenericArray<LyricLine>? fetch (
            Music music, int duration_secs, Cancellable? cancellable = null
        );
    }

    // ── Built-in provider: local .lrc sidecar ────────────────────────────────

    public class LocalLrcProvider : LyricsProvider {
        public override string id           { get { return "local-lrc"; } }
        public override string display_name { get { return _("Local LRC File"); } }
        public override string description  { get { return _("Load a .lrc file next to the audio file"); } }

        public override async GenericArray<LyricLine>? fetch (
            Music music, int duration_secs, Cancellable? cancellable = null
        ) {
            return yield load_local_lrc (music, cancellable);
        }
    }

    // ── Built-in provider: lrclib.net ────────────────────────────────────────

    public class LrclibProvider : LyricsProvider {
        public override string id           { get { return "lrclib"; } }
        public override string display_name { get { return "LRCLib"; } }
        public override string description  { get { return _("Fetch synced lyrics from lrclib.net"); } }

        public override async GenericArray<LyricLine>? fetch (
            Music music, int duration_secs, Cancellable? cancellable = null
        ) {
            return yield fetch_lyrics_online (music, duration_secs, cancellable);
        }
    }

    // ── Built-in provider: NetEase Cloud Music (music.163.com) ──────────────

    public class NeteaseProvider : LyricsProvider {
        public override string id           { get { return "netease"; } }
        public override string display_name { get { return _("NetEase Cloud Music"); } }
        public override string description  { get { return _("Fetch lyrics from music.163.com"); } }

        public override async GenericArray<LyricLine>? fetch (
            Music music, int duration_secs, Cancellable? cancellable = null
        ) {
            if (music.title.length == 0) return null;

            var session = new Soup.Session ();
            session.user_agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
                                 "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

            var song_id = yield netease_search (session, music, cancellable);
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
            if (song_id <= 0) return null;

            return yield netease_lyric (session, song_id, cancellable);
        }

        // Step 1: search for the best-matching song and return its numeric ID.
        private async int64 netease_search (Soup.Session session, Music music, Cancellable? cancellable) {
            var query = music.title + " " + music.artist_name;
            if (music.album.length > 0)
                query += " " + music.album;
            var q = Uri.escape_string (query, null, false);
            var url = @"https://music.163.com/api/search/get?s=$(q)&type=1&limit=5&sub=false";
            try {
                var msg = new Soup.Message ("GET", url);
                msg.request_headers.append ("Referer", "https://music.163.com/");
                var bytes = yield session.send_and_read_async (msg, GLib.Priority.DEFAULT, cancellable);
                if (msg.status_code != 200) return -1;
                var body = (string) bytes.get_data ();
                return netease_parse_song_id (body);
            } catch (Error e) {
                if (!(e is IOError.CANCELLED))
                    warning ("NetEase search failed: %s", e.message);
                return -1;
            }
        }

        // Step 2: download the LRC lyric for @song_id.
        private async GenericArray<LyricLine>? netease_lyric (Soup.Session session, int64 song_id, Cancellable? cancellable) {
            var url = @"https://music.163.com/api/song/lyric?id=$(song_id)&lv=1&kv=1&tv=-1";
            try {
                var msg = new Soup.Message ("GET", url);
                msg.request_headers.append ("Referer", "https://music.163.com/");
                var bytes = yield session.send_and_read_async (msg, GLib.Priority.DEFAULT, cancellable);
                if (msg.status_code != 200) return null;
                var body = (string) bytes.get_data ();
                return netease_parse_lyric (body);
            } catch (Error e) {
                if (!(e is IOError.CANCELLED))
                    warning ("NetEase lyric fetch failed: %s", e.message);
                return null;
            }
        }

        // Parse the first song id from the search response.
        // The song object has many nested objects (album, artists…) each with
        // their own "id" fields.  We only want "id" at depth 1 of the song
        // object (i.e. the song's own top-level id).
        private int64 netease_parse_song_id (string json) {
            int songs_pos = json.index_of ("\"songs\":[");
            if (songs_pos < 0) return -1;
            int pos = songs_pos + 9;
            while (pos < json.length && json[pos] == ' ') pos++;
            if (pos >= json.length || json[pos] == ']') return -1;
            if (json[pos] != '{') return -1;

            // Walk the first song object, counting brace/bracket depth.
            // "id" at depth == 1 is the song's own id.
            int depth = 0;
            while (pos < json.length) {
                char c = json[pos];
                if (c == '{' || c == '[') {
                    depth++;
                    pos++;
                } else if (c == '}' || c == ']') {
                    depth--;
                    pos++;
                    if (depth == 0) break;
                } else if (c == '"') {
                    if (depth == 1 && pos + 5 <= json.length && json.substring (pos, 5) == "\"id\":") {
                        int vp = pos + 5;
                        while (vp < json.length && json[vp] == ' ') vp++;
                        if (vp < json.length && json[vp].isdigit ()) {
                            var sb = new StringBuilder ();
                            while (vp < json.length && json[vp].isdigit ())
                                sb.append_c (json[vp++]);
                            var id = sb.len > 0 ? int64.parse (sb.str) : 0L;
                            if (id > 0) return id;
                        }
                    }
                    // Skip string content
                    pos++;
                    while (pos < json.length) {
                        if (json[pos] == '\\') pos++;
                        else if (json[pos] == '"') { pos++; break; }
                        pos++;
                    }
                } else {
                    pos++;
                }
            }
            return -1;
        }

        // Extract the synced LRC string from the lyric response.
        // {"lrc":{"version":N,"lyric":"...LRC..."}, "tlyric":{...}, "code":200}
        private GenericArray<LyricLine>? netease_parse_lyric (string json) {
            int lrc_pos = json.index_of ("\"lrc\":");
            if (lrc_pos < 0) return null;
            int lyric_pos = json.index_of ("\"lyric\":", lrc_pos);
            if (lyric_pos < 0) return null;
            lyric_pos += 8;
            while (lyric_pos < json.length && json[lyric_pos] == ' ') lyric_pos++;
            if (lyric_pos >= json.length || json[lyric_pos] != '"') return null;
            var content = read_json_string (json, ref lyric_pos);
            if (content == null || ((!)content).length == 0) return null;
            var lines = parse_lrc ((!)content);
            if (lines.length == 0) return null;
            return lines;
        }
    }

    // ── Provider registry ────────────────────────────────────────────────────

    public class LyricsProviderRegistry : Object {
        // Nullable so we can detect first access (static construct in Vala is
        // class_init and only runs on instantiation, not on static method calls).
        private static GenericArray<LyricsProvider>? _providers = null;

        private static unowned GenericArray<LyricsProvider> providers () {
            if (_providers == null) {
                _providers = new GenericArray<LyricsProvider> ();
                ((!)_providers).add (new LocalLrcProvider ());
                ((!)_providers).add (new LrclibProvider ());
                ((!)_providers).add (new NeteaseProvider ());
            }
            return (!)_providers;
        }

        // All registered providers in registration order.
        public static unowned GenericArray<LyricsProvider> all_providers () {
            return providers ();
        }

        // Append a provider (call before first playback; not thread-safe).
        public static void register (LyricsProvider provider) {
            providers ().add (provider);
        }

        // Returns enabled providers in the order stored in settings["lyrics-providers"].
        // Providers absent from the list are considered disabled and are omitted.
        public static GenericArray<LyricsProvider> get_enabled_ordered (Settings settings) {
            var ids = settings.get_strv ("lyrics-providers");
            var all = providers ();
            var result = new GenericArray<LyricsProvider> ();
            foreach (unowned var id in ids) {
                for (var i = 0; i < all.length; i++) {
                    if (all[i].id == id) {
                        result.add (all[i]);
                        break;
                    }
                }
            }
            return result;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────

    public class LyricLine : Object {
        public int64 time_ms;
        public string text;

        public LyricLine (int64 time_ms, string text) {
            this.time_ms = time_ms;
            this.text = text;
        }
    }

    public GenericArray<LyricLine> parse_lrc (string content) {
        var lines = new GenericArray<LyricLine> ();
        foreach (unowned var raw_line in content.split ("\n")) {
            var line = raw_line.strip ();
            if (line.length == 0) continue;
            var i = 0;
            // A single line may carry multiple time tags: [00:01.00][00:02.00]text
            while (i < line.length && line[i] == '[') {
                var close = line.index_of_char (']', i + 1);
                if (close < 0) break;
                var tag = line.substring (i + 1, close - i - 1);
                var time_ms = parse_lrc_time_tag (tag);
                if (time_ms >= 0) {
                    var text = line.substring (close + 1).strip ();
                    lines.add (new LyricLine (time_ms, text));
                    i = close + 1;
                } else {
                    break;
                }
            }
        }
        lines.sort ((a, b) => {
            var diff = a.time_ms - b.time_ms;
            return diff < 0 ? -1 : (diff > 0 ? 1 : 0);
        });
        return lines;
    }

    private int64 parse_lrc_time_tag (string tag) {
        // Must start with a digit (filters metadata tags like [ar:Artist])
        if (tag.length == 0 || !tag[0].isdigit ()) return -1;
        int colon = tag.index_of_char (':');
        if (colon <= 0) return -1;
        int mm = int.parse (tag.substring (0, colon));
        var rest = tag.substring (colon + 1);
        int dot = rest.index_of_char ('.');
        int colon2 = rest.index_of_char (':');
        string sec_str, frac_str = "";
        if (dot >= 0) {
            sec_str = rest.substring (0, dot);
            frac_str = rest.substring (dot + 1);
        } else if (colon2 >= 0) {
            // Alternative format: mm:ss:xx
            sec_str = rest.substring (0, colon2);
            frac_str = rest.substring (colon2 + 1);
        } else {
            sec_str = rest;
        }
        int ss = int.parse (sec_str);
        int64 ms = (int64) (mm * 60 + ss) * 1000;
        if (frac_str.length > 0) {
            int frac = int.parse (frac_str);
            // Normalise to milliseconds: 1 digit=100ms, 2 digits=10ms, 3+digits=ms
            for (var i = (int) frac_str.length; i < 3; i++) frac *= 10;
            ms += (int64) frac;
        }
        return ms;
    }

    // Try loading a .lrc sidecar next to the audio file.
    public async GenericArray<LyricLine>? load_local_lrc (Music music, Cancellable? cancellable = null) {
        var uri = music.uri;
        int dot = uri.last_index_of_char ('.');
        if (dot < 0) return null;
        var lrc_uri = uri.substring (0, dot) + ".lrc";
        var file = File.new_for_uri (lrc_uri);
        try {
            uint8[] contents;
            string? etag;
            yield file.load_contents_async (cancellable, out contents, out etag);
            var lines = parse_lrc ((string) contents);
            if (lines.length > 0) return lines;
            return null;
        } catch {
            return null;
        }
    }

    // Query lrclib.net for synced lyrics.
    // Strategy: /api/get (exact match, requires duration) → /api/search (fuzzy, no duration needed).
    public async GenericArray<LyricLine>? fetch_lyrics_online (Music music, int duration_secs, Cancellable? cancellable = null) {
        if (music.title.length == 0) return null;

        var session = new Soup.Session ();
        session.user_agent = Config.APP_ID + "/" + Config.VERSION;

        // 1. /api/get — requires all four fields including duration
        if (duration_secs > 0) {
            var lines = yield lrclib_get (session, music, duration_secs, cancellable);
            if (cancellable != null && ((!)cancellable).is_cancelled ()) return null;
            if (lines != null) return lines;
        }

        // 2. /api/search — keyword search, pick first result with syncedLyrics
        return yield lrclib_search (session, music, cancellable);
    }

    private async GenericArray<LyricLine>? lrclib_get (Soup.Session session, Music music, int duration_secs, Cancellable? cancellable) {
        var title  = Uri.escape_string (music.title,       null, false);
        var artist = Uri.escape_string (music.artist_name, null, false);
        var album  = Uri.escape_string (music.album,       null, false);
        var url = @"https://lrclib.net/api/get?track_name=$(title)&artist_name=$(artist)&album_name=$(album)&duration=$(duration_secs)";
        try {
            var msg   = new Soup.Message ("GET", url);
            var bytes = yield session.send_and_read_async (msg, GLib.Priority.DEFAULT, cancellable);
            if (msg.status_code != 200) return null;
            var synced = extract_json_string ((string) bytes.get_data (), "syncedLyrics");
            if (synced != null && ((!)synced).length > 0) {
                var lines = parse_lrc ((!)synced);
                if (lines.length > 0) return lines;
            }
        } catch (Error e) {
            if (!(e is IOError.CANCELLED))
                warning ("Lyrics /api/get failed: %s", e.message);
        }
        return null;
    }

    private async GenericArray<LyricLine>? lrclib_search (Soup.Session session, Music music, Cancellable? cancellable) {
        var title  = Uri.escape_string (music.title,       null, false);
        var artist = Uri.escape_string (music.artist_name, null, false);
        var url = @"https://lrclib.net/api/search?track_name=$(title)&artist_name=$(artist)";
        try {
            var msg   = new Soup.Message ("GET", url);
            var bytes = yield session.send_and_read_async (msg, GLib.Priority.DEFAULT, cancellable);
            if (msg.status_code != 200) return null;
            var synced = extract_first_synced_from_array ((string) bytes.get_data ());
            if (synced != null) {
                var lines = parse_lrc ((!)synced);
                if (lines.length > 0) return lines;
            }
        } catch (Error e) {
            if (!(e is IOError.CANCELLED))
                warning ("Lyrics /api/search failed: %s", e.message);
        }
        return null;
    }

    // Extract the value of a JSON string field from a single object.
    private string? extract_json_string (string json, string key) {
        var search = "\"" + key + "\":";
        int pos = json.index_of (search);
        if (pos < 0) return null;
        pos += search.length;
        while (pos < json.length && json[pos] == ' ') pos++;
        if (pos >= json.length || json[pos] != '"') return null;
        return read_json_string (json, ref pos);
    }

    // Scan a JSON array and return the syncedLyrics value of the first element
    // that has a non-null, non-empty syncedLyrics field.
    private string? extract_first_synced_from_array (string json) {
        // Search for every occurrence of "syncedLyrics":" (the quote means non-null)
        var needle = "\"syncedLyrics\":\"";
        int pos = 0;
        while (pos < json.length) {
            int found = json.index_of (needle, pos);
            if (found < 0) break;
            pos = found + needle.length; // pos now points to first char inside the string
            var value = read_json_string (json, ref pos);
            if (value != null && ((!)value).length > 0)
                return value;
        }
        return null;
    }

    // Read a JSON string starting just after the opening quote (pos points at first content char).
    // Advances pos past the closing quote on return.
    private string? read_json_string (string json, ref int pos) {
        // If called from extract_json_string, pos is on the opening '"'; skip it.
        if (pos < json.length && json[pos] == '"') pos++;
        var sb = new StringBuilder ();
        while (pos < json.length && json[pos] != '"') {
            if (json[pos] == '\\' && pos + 1 < json.length) {
                pos++;
                switch (json[pos]) {
                    case 'n':  sb.append_c ('\n'); break;
                    case 'r':  break;
                    case 't':  sb.append_c ('\t'); break;
                    case '"':  sb.append_c ('"');  break;
                    case '\\': sb.append_c ('\\'); break;
                    default:   sb.append_c (json[pos]); break;
                }
            } else {
                sb.append_c (json[pos]);
            }
            pos++;
        }
        pos++; // skip closing '"'
        return sb.str;
    }
}
