namespace G4 {

    public class LyricsView : Gtk.Box {
        private Gtk.ScrolledWindow _scroll;
        private Gtk.Box _box;
        private Gtk.Label _status_label;
        private GenericArray<LyricLine> _lines = new GenericArray<LyricLine> ();
        private Gtk.Label[] _labels = {};
        private int _current_index = -1;
        private Adw.Animation? _scroll_animation = null;

        public LyricsView () {
            orientation = Gtk.Orientation.VERTICAL;
            add_css_class ("lyrics-view");

            _box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            _box.halign = Gtk.Align.FILL;
            _box.margin_top = 48;
            _box.margin_bottom = 48;
            _box.margin_start = 24;
            _box.margin_end = 24;

            _status_label = new Gtk.Label ("");
            _status_label.halign = Gtk.Align.CENTER;
            _status_label.valign = Gtk.Align.CENTER;
            _status_label.vexpand = true;
            _status_label.wrap = true;
            _status_label.justify = Gtk.Justification.CENTER;
            _status_label.add_css_class ("dim-label");

            var viewport = new Gtk.Viewport (null, null);
            viewport.scroll_to_focus = false;
            viewport.child = _box;

            _scroll = new Gtk.ScrolledWindow ();
            _scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            _scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            _scroll.vexpand = true;
            _scroll.child = viewport;
            append (_scroll);
        }

        public void set_loading () {
            clear_labels ();
            _status_label.label = _("Loading lyrics…");
            _box.append (_status_label);
        }

        public void set_no_lyrics () {
            clear_labels ();
            _status_label.label = _("No lyrics found");
            _box.append (_status_label);
        }

        public void set_lyrics (GenericArray<LyricLine> lines) {
            clear_labels ();
            _lines = lines;
            _current_index = -1;

            if (lines.length == 0) {
                set_no_lyrics ();
                return;
            }

            _labels = new Gtk.Label[lines.length];
            for (var i = 0; i < lines.length; i++) {
                var text = lines[i].text;
                var label = new Gtk.Label (text.length > 0 ? text : "  ·  ");
                label.halign = Gtk.Align.CENTER;
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                label.justify = Gtk.Justification.CENTER;
                label.selectable = false;
                label.add_css_class ("lyrics-line");
                _box.append (label);
                _labels[i] = label;
            }

            // Reset scroll to top
            _scroll.vadjustment.value = 0;
        }

        // Call with position in milliseconds; returns true when the active line changed.
        public bool update_position (int64 position_ms) {
            if (_lines.length == 0 || _labels.length == 0) return false;

            // Binary search for the last line whose time <= position
            int lo = 0, hi = _lines.length - 1, new_index = -1;
            while (lo <= hi) {
                int mid = (lo + hi) / 2;
                if (_lines[mid].time_ms <= position_ms) {
                    new_index = mid;
                    lo = mid + 1;
                } else {
                    hi = mid - 1;
                }
            }

            if (new_index == _current_index) return false;

            if (_current_index >= 0 && _current_index < _labels.length)
                _labels[_current_index].remove_css_class ("lyrics-current");

            _current_index = new_index;

            if (_current_index >= 0 && _current_index < _labels.length) {
                _labels[_current_index].add_css_class ("lyrics-current");
                scroll_to_label (_labels[_current_index]);
            }
            return true;
        }

        private void clear_labels () {
            _labels = {};
            _lines = new GenericArray<LyricLine> ();
            _current_index = -1;
            _scroll_animation?.pause ();
            _scroll_animation = null;
            var w = _box.get_first_child ();
            while (w != null) {
                var next = ((!)w).get_next_sibling ();
                _box.remove ((!)w);
                w = next;
            }
        }

        private void scroll_to_label (Gtk.Label label) {
            Graphene.Rect bounds;
            if (!label.compute_bounds (_box, out bounds)) return;
            var adj = _scroll.vadjustment;
            var view_height = (double) _scroll.get_height ();
            var target = (double) bounds.origin.y
                         + (double) bounds.size.height / 2.0
                         - view_height / 2.0;
            target = target.clamp (adj.lower, double.max (adj.lower, adj.upper - adj.page_size));

            _scroll_animation?.pause ();
            var anim_target = new Adw.CallbackAnimationTarget ((v) => adj.value = v);
            var anim = new Adw.TimedAnimation (_scroll, adj.value, target, 380, anim_target);
            anim.easing = Adw.Easing.EASE_OUT_CUBIC;
            _scroll_animation = anim;
            anim.play ();
        }
    }
}
