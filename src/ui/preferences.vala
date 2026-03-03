namespace G4 {
    namespace BlurMode {
        public const uint NEVER = 0;
        public const uint ALWAYS = 1;
        public const uint ART_ONLY = 2;
    }

    [GtkTemplate (ui = "/com/github/neithern/g4music/gtk/preferences.ui")]
    public class PreferencesWindow : Adw.PreferencesWindow {
        [GtkChild]
        unowned Adw.PreferencesPage main_page;
        [GtkChild]
        unowned Adw.ComboRow blur_row;
        [GtkChild]
        unowned Gtk.Switch compact_btn;
        [GtkChild]
        unowned Gtk.Switch grid_btn;
        [GtkChild]
        unowned Gtk.Switch single_btn;
        [GtkChild]
        unowned Gtk.Button music_dir_btn;
        [GtkChild]
        unowned Gtk.Switch monitor_btn;
        [GtkChild]
        unowned Gtk.Switch thumbnail_btn;
        [GtkChild]
        unowned Gtk.Switch playbkgnd_btn;
        [GtkChild]
        unowned Gtk.Switch rotate_btn;
        [GtkChild]
        unowned Gtk.Switch gapless_btn;
        [GtkChild]
        unowned Adw.ComboRow replaygain_row;
        [GtkChild]
        unowned Adw.ComboRow audiosink_row;
        [GtkChild]
        unowned Adw.ExpanderRow peak_row;
        [GtkChild]
        unowned Gtk.Entry peak_entry;
        [GtkChild]
        unowned Gtk.Entry artist_split_entry;

        private GenericArray<Gst.ElementFactory> _audio_sinks = new GenericArray<Gst.ElementFactory> (8);
        private Settings _settings;
        private Adw.PreferencesGroup _lyrics_group;
        private GenericArray<Gtk.Widget> _lyrics_rows = new GenericArray<Gtk.Widget> ();

        public PreferencesWindow (Application app) {
            var settings = app.settings;

            blur_row.model = new Gtk.StringList ({_("Never"), _("Always"), _("Art Only")});
            settings.bind ("blur-mode", blur_row, "selected", SettingsBindFlags.DEFAULT);

            settings.bind ("compact-playlist", compact_btn, "active", SettingsBindFlags.DEFAULT);
            settings.bind ("grid-mode", grid_btn, "active", SettingsBindFlags.DEFAULT);
            settings.bind ("single-click-activate", single_btn, "active", SettingsBindFlags.DEFAULT);

            music_dir_btn.label = get_display_name (app.music_folder);
            music_dir_btn.clicked.connect (() => {
                pick_music_folder (app, this, (dir) => {
                    music_dir_btn.label = get_display_name (app.music_folder);
                });
            });

            settings.bind ("monitor-changes", monitor_btn, "active", SettingsBindFlags.DEFAULT);

            settings.bind ("remote-thumbnail", thumbnail_btn, "active", SettingsBindFlags.DEFAULT);

            settings.bind ("play-background", playbkgnd_btn, "active", SettingsBindFlags.DEFAULT);

            settings.bind ("rotate-cover", rotate_btn, "active", SettingsBindFlags.DEFAULT);

            replaygain_row.model = new Gtk.StringList ({_("Never"), _("Track"), _("Album")});
            settings.bind ("replay-gain", replaygain_row, "selected", SettingsBindFlags.DEFAULT);

            settings.bind ("gapless-playback", gapless_btn, "active", SettingsBindFlags.DEFAULT);

            settings.bind ("show-peak", peak_row, "enable_expansion", SettingsBindFlags.DEFAULT);
            settings.bind ("peak-characters", peak_entry, "text", SettingsBindFlags.DEFAULT);
            settings.bind ("artist-split-chars", artist_split_entry, "text", SettingsBindFlags.DEFAULT);

            GstPlayer.get_audio_sinks (_audio_sinks);
            var sink_names = new string[_audio_sinks.length];
            for (var i = 0; i < _audio_sinks.length; i++)
                sink_names[i] = get_audio_sink_name (_audio_sinks[i]);
            audiosink_row.model = new Gtk.StringList (sink_names);
            this.bind_property ("audio_sink", audiosink_row, "selected", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);

            _settings = settings;
            _lyrics_group = new Adw.PreferencesGroup ();
            _lyrics_group.title = _("Lyrics Sources");
            _lyrics_group.description = _("Sources higher in the list are tried first");
            main_page.add (_lyrics_group);
            rebuild_lyrics_rows ();
        }

        // ── Lyrics source management ─────────────────────────────────────────

        private void rebuild_lyrics_rows () {
            for (var i = 0; i < _lyrics_rows.length; i++)
                _lyrics_group.remove (_lyrics_rows[i]);
            _lyrics_rows = new GenericArray<Gtk.Widget> ();

            var enabled_ids = _settings.get_strv ("lyrics-providers");
            var all = LyricsProviderRegistry.all_providers ();

            // 1. Enabled providers in priority order
            foreach (unowned var id in enabled_ids) {
                for (var i = 0; i < all.length; i++) {
                    if (all[i].id == id) {
                        var row = make_lyrics_row (all[i], enabled_ids);
                        _lyrics_group.add (row);
                        _lyrics_rows.add (row);
                        break;
                    }
                }
            }

            // 2. Disabled providers (not in enabled list)
            for (var i = 0; i < all.length; i++) {
                var found = false;
                foreach (unowned var id in enabled_ids)
                    if (all[i].id == id) { found = true; break; }
                if (!found) {
                    var row = make_lyrics_row (all[i], enabled_ids);
                    _lyrics_group.add (row);
                    _lyrics_rows.add (row);
                }
            }
        }

        private Adw.ActionRow make_lyrics_row (LyricsProvider provider, string[] enabled_ids) {
            var row = new Adw.ActionRow ();
            row.title = provider.display_name;
            if (provider.description.length > 0)
                row.subtitle = provider.description;

            var is_enabled = false;
            foreach (unowned var id in enabled_ids)
                if (id == provider.id) { is_enabled = true; break; }

            if (is_enabled) {
                // Drag handle — lets the user reorder enabled sources
                var handle = new Gtk.Image.from_icon_name ("list-drag-handle-symbolic");
                handle.valign = Gtk.Align.CENTER;
                handle.opacity = 0.5;
                handle.tooltip_text = _("Drag to reorder");
                row.add_prefix (handle);

                var drag_source = new Gtk.DragSource ();
                drag_source.set_actions (Gdk.DragAction.MOVE);
                drag_source.prepare.connect ((x, y) => {
                    var v = GLib.Value (typeof (string));
                    v.set_string (provider.id);
                    return new Gdk.ContentProvider.for_value (v);
                });
                drag_source.drag_begin.connect ((drag) => {
                    drag_source.set_icon (new Gtk.WidgetPaintable (row), 0, 0);
                });
                handle.add_controller (drag_source);

                // Drop target — accepts a provider id string
                var drop_target = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
                drop_target.drop.connect ((value, x, y) => {
                    if (!value.holds (typeof (string))) return false;
                    unowned var src_id = value.get_string ();
                    if (src_id != provider.id)
                        reorder_provider (src_id, provider.id);
                    return true;
                });
                row.add_controller (drop_target);
            }

            var sw = new Gtk.Switch ();
            sw.valign = Gtk.Align.CENTER;
            sw.active = is_enabled;
            row.activatable_widget = sw;
            row.add_suffix (sw);
            sw.notify["active"].connect (() => toggle_provider (provider.id, sw.active));
            return row;
        }

        private void toggle_provider (string id, bool enable) {
            var ids = _settings.get_strv ("lyrics-providers");
            string[] new_ids = {};
            if (enable) {
                foreach (unowned var eid in ids) new_ids += eid;
                new_ids += id;
            } else {
                foreach (unowned var eid in ids)
                    if (eid != id) new_ids += eid;
            }
            _settings.set_strv ("lyrics-providers", new_ids);
            rebuild_lyrics_rows ();
        }

        private void reorder_provider (string src_id, string target_id) {
            var ids = _settings.get_strv ("lyrics-providers");
            int src_pos = -1, target_pos = -1;
            for (var i = 0; i < ids.length; i++) {
                if (ids[i] == src_id)    src_pos    = i;
                if (ids[i] == target_id) target_pos = i;
            }
            if (src_pos < 0 || target_pos < 0) return;

            string[] without_src = {};
            foreach (unowned var id in ids)
                if (id != src_id) without_src += id;

            string[] new_ids = {};
            if (src_pos < target_pos) {
                // Dragging down: insert after target
                foreach (unowned var id in without_src) {
                    new_ids += id;
                    if (id == target_id) new_ids += src_id;
                }
            } else {
                // Dragging up: insert before target
                foreach (unowned var id in without_src) {
                    if (id == target_id) new_ids += src_id;
                    new_ids += id;
                }
            }
            _settings.set_strv ("lyrics-providers", new_ids);
            rebuild_lyrics_rows ();
        }

        public uint audio_sink {
            get {
                var app = (Application) GLib.Application.get_default ();
                var sink_name = app.player.audio_sink;
                for (int i = 0; i < _audio_sinks.length; i++) {
                    if (sink_name == _audio_sinks[i].name)
                        return i;
                }
                return _audio_sinks.length > 0 ? 0 : -1;
            }
            set {
                if (value < _audio_sinks.length) {
                    var app = (Application) GLib.Application.get_default ();
                    app.player.audio_sink = _audio_sinks[value].name;
                }
            }
        }


    }

    public string get_audio_sink_name (Gst.ElementFactory factory) {
        var name = factory.get_metadata ("long-name") ?? factory.name;
        name = name.replace ("Audio sink", "")
                    .replace ("Audio Sink", "")
                    .replace ("sink", "")
                    .replace ("(", "").replace (")", "");
        return name.strip ();
    }

    public delegate void FolderPicked (File dir);

    public void pick_music_folder (Application app, Gtk.Window? parent, FolderPicked picked) {
        var music_dir = File.new_for_uri (app.music_folder);
        show_select_folder_dialog.begin (parent, music_dir, (obj, res) => {
            var dir = show_select_folder_dialog.end (res);
            if (dir != null) {
                var uri = ((!)dir).get_uri ();
                if (app.music_folder != uri)
                    app.music_folder = uri;
                picked ((!)dir);
            }
        });
    }
}
