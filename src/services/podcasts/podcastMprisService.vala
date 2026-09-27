/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * Exposes podcast playback over MPRIS so the desktop's media controls,
 * lock screen and media keys can see and control it. The bus name is only
 * owned while an episode is loaded, so no empty player shows up otherwise.
 */
namespace Paperboy {

    [DBus (name = "org.mpris.MediaPlayer2")]
    public class MprisRoot : GLib.Object {
        private unowned Gtk.Application app;

        public MprisRoot(Gtk.Application app) {
            this.app = app;
        }

        public bool can_quit { get { return true; } }
        public bool can_raise { get { return true; } }
        public bool has_track_list { get { return false; } }
        public string identity { owned get { return "Paperboy"; } }
        public string desktop_entry { owned get { return "io.github.thecalamityjoe87.Paperboy"; } }
        public string[] supported_uri_schemes { owned get { return {}; } }
        public string[] supported_mime_types { owned get { return {}; } }

        public void raise() throws GLib.DBusError, GLib.IOError {
            var window = app.get_active_window();
            if (window != null) window.present();
        }

        // Closing the window (rather than app.quit()) runs its close_request cleanup.
        public void quit() throws GLib.DBusError, GLib.IOError {
            var window = app.get_active_window();
            if (window != null) window.close(); else app.quit();
        }
    }

    [DBus (name = "org.mpris.MediaPlayer2.Player")]
    public class MprisPlayer : GLib.Object {
        private const string TRACK_PATH_PREFIX = "/io/github/thecalamityjoe87/Paperboy/Episode/";
        private const string INTERFACE = "org.mpris.MediaPlayer2.Player";
        private unowned Managers.PodcastPlaybackManager playback;
        private GLib.DBusConnection connection;
        private int64 metadata_length_us = 0;
        private Variant? last_metadata = null;
        // Vala doesn't emit PropertiesChanged for exported objects, so changes are batched here.
        private HashTable<string, Variant> pending_changes = new HashTable<string, Variant>(str_hash, str_equal);
        private uint pending_idle_id = 0;

        public string playback_status { owned get; private set; default = "Stopped"; }
        public HashTable<string, Variant> metadata { owned get; private set; }
        public bool can_go_next { get; private set; }
        public bool can_go_previous { get; private set; }
        public bool can_play { get; private set; }
        public bool can_pause { get; private set; }
        public bool can_seek { get; private set; }
        public bool can_control { get { return true; } }
        public double rate { get { return playback.get_rate(); } }
        public double minimum_rate { get { return 1.0; } }
        public double maximum_rate { get { return 2.0; } }
        public double volume { get { return 1.0; } }
        // Polled by clients; deliberately never notified.
        public int64 position { get { return (int64) (playback.get_position_ns() / 1000); } }

        public signal void seeked(int64 position);

        public MprisPlayer(Managers.PodcastPlaybackManager playback, GLib.DBusConnection connection) {
            this.playback = playback;
            this.connection = connection;
            metadata = new HashTable<string, Variant>(str_hash, str_equal);

            playback.episode_changed.connect(() => { refresh(); });
            playback.playback_state_changed.connect(() => { refresh(); });
            playback.seeked.connect((pos) => { seeked((int64) (pos / 1000)); });
            playback.position_updated.connect((pos, duration) => {
                if (duration > 0 && duration != Gst.CLOCK_TIME_NONE && (int64) (duration / 1000) != metadata_length_us) update_metadata();
            });
            refresh();
        }

        private void refresh() {
            var episode = playback.get_current_episode();
            bool loaded = episode != null;
            string status = !loaded ? "Stopped" : (playback.is_playing() ? "Playing" : "Paused");
            if (status != playback_status) {
                playback_status = status;
                queue_change("PlaybackStatus", new Variant.string(status));
            }
            if (can_play != loaded) {
                can_play = can_pause = can_seek = loaded;
                queue_change("CanPlay", new Variant.boolean(loaded));
                queue_change("CanPause", new Variant.boolean(loaded));
                queue_change("CanSeek", new Variant.boolean(loaded));
            }
            bool next = playback.has_next_episode();
            bool previous = playback.has_previous_episode();
            if (can_go_next != next) {
                can_go_next = next;
                queue_change("CanGoNext", new Variant.boolean(next));
            }
            if (can_go_previous != previous) {
                can_go_previous = previous;
                queue_change("CanGoPrevious", new Variant.boolean(previous));
            }
            update_metadata();
        }

        private void queue_change(string name, Variant value) {
            pending_changes.insert(name, value);
            if (pending_idle_id != 0) return;
            pending_idle_id = GLib.Idle.add(() => {
                pending_idle_id = 0;
                emit_pending_changes();
                return GLib.Source.REMOVE;
            });
        }

        private void emit_pending_changes() {
            var changed = new VariantBuilder(new VariantType("a{sv}"));
            pending_changes.foreach((name, value) => { changed.add("{sv}", name, value); });
            pending_changes.remove_all();
            var invalidated = new VariantBuilder(new VariantType("as"));
            try {
                connection.emit_signal(null, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties",
                    "PropertiesChanged", new Variant("(sa{sv}as)", INTERFACE, changed, invalidated));
            } catch (GLib.Error e) {
                GLib.warning("MPRIS: couldn't emit PropertiesChanged: %s", e.message);
            }
        }

        private static Variant metadata_variant(HashTable<string, Variant> m) {
            var builder = new VariantBuilder(new VariantType("a{sv}"));
            m.foreach((key, value) => { builder.add("{sv}", key, value); });
            return builder.end();
        }

        private void update_metadata() {
            var episode = playback.get_current_episode();
            var m = new HashTable<string, Variant>(str_hash, str_equal);
            metadata_length_us = 0;
            if (episode != null) {
                m.insert("mpris:trackid", new Variant.object_path(track_path(episode)));
                m.insert("xesam:title", new Variant.string(episode.title));
                if (episode.show_title != "") {
                    m.insert("xesam:artist", new Variant.strv({ episode.show_title }));
                    m.insert("xesam:album", new Variant.string(episode.show_title));
                }
                metadata_length_us = (int64) (playback.get_duration_ns() / 1000);
                if (metadata_length_us > 0) m.insert("mpris:length", new Variant.int64(metadata_length_us));
                string? art = art_url(episode);
                if (art != null) m.insert("mpris:artUrl", new Variant.string(art));
            }
            var packed = metadata_variant(m);
            if (last_metadata != null && packed.equal(last_metadata)) return;
            last_metadata = packed;
            metadata = m;
            queue_change("Metadata", packed);
        }

        private static string track_path(Paperboy.PodcastEpisode episode) {
            // Direct-feed episode ids can be negative; '-' isn't valid in an object path.
            return TRACK_PATH_PREFIX + episode.episode_id.to_string().replace("-", "n");
        }

        private static string? art_url(Paperboy.PodcastEpisode episode) {
            if (episode.cover_local_path != null) {
                try {
                    return GLib.Filename.to_uri(episode.cover_local_path);
                } catch (GLib.ConvertError e) { }
            }
            return episode.image_url;
        }

        public void next() throws GLib.DBusError, GLib.IOError { playback.play_next_episode(); }
        public void previous() throws GLib.DBusError, GLib.IOError { playback.play_previous_episode(); }
        public void play_pause() throws GLib.DBusError, GLib.IOError {
            if (playback.get_current_episode() != null) playback.toggle_play_pause();
        }
        public void play() throws GLib.DBusError, GLib.IOError {
            if (playback.get_current_episode() != null) playback.play();
        }
        public void pause() throws GLib.DBusError, GLib.IOError { playback.pause(); }
        // Pauses rather than stops: a real stop would leave the mini-player showing with nothing loaded.
        public void stop() throws GLib.DBusError, GLib.IOError { playback.pause(); }

        public void seek(int64 offset) throws GLib.DBusError, GLib.IOError {
            if (playback.get_current_episode() == null) return;
            playback.skip(offset / 1000000);
        }

        public void set_position(GLib.ObjectPath track_id, int64 position) throws GLib.DBusError, GLib.IOError {
            var episode = playback.get_current_episode();
            if (episode == null || (string) track_id != track_path(episode) || position < 0) return;
            uint64 duration = playback.get_duration_ns();
            if (duration > 0 && (uint64) position * 1000 > duration) return;
            playback.seek_to((uint64) position * 1000);
        }

        public void open_uri(string uri) throws GLib.DBusError, GLib.IOError { }
    }

    public class PodcastMprisService : GLib.Object {
        private const string BUS_NAME = "org.mpris.MediaPlayer2.Paperboy";
        private const string OBJECT_PATH = "/org/mpris/MediaPlayer2";

        private GLib.DBusConnection? connection = null;
        private MprisRoot? root = null;
        private MprisPlayer? player = null;
        private uint root_id = 0;
        private uint player_id = 0;
        private uint name_id = 0;

        public PodcastMprisService(Gtk.Application app, Managers.PodcastPlaybackManager playback) {
            connection = app.get_dbus_connection();
            if (connection == null) return;

            root = new MprisRoot(app);
            player = new MprisPlayer(playback, connection);
            try {
                root_id = connection.register_object(OBJECT_PATH, root);
                player_id = connection.register_object(OBJECT_PATH, player);
            } catch (GLib.IOError e) {
                GLib.warning("MPRIS: couldn't register objects: %s", e.message);
                unregister();
                return;
            }

            playback.episode_changed.connect(() => { own_name(); });
            playback.playback_state_changed.connect(() => {
                if (playback.get_current_episode() == null) release_name();
            });
            if (playback.get_current_episode() != null) own_name();
        }

        private void own_name() {
            if (name_id != 0 || connection == null) return;
            name_id = GLib.Bus.own_name_on_connection(connection, BUS_NAME, GLib.BusNameOwnerFlags.NONE);
        }

        private void release_name() {
            if (name_id == 0) return;
            GLib.Bus.unown_name(name_id);
            name_id = 0;
        }

        public void unregister() {
            release_name();
            if (connection == null) return;
            if (root_id != 0) connection.unregister_object(root_id);
            if (player_id != 0) connection.unregister_object(player_id);
            root_id = 0;
            player_id = 0;
        }
    }
}
