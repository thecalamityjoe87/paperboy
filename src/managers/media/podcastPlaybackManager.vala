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

/**
 * Owns podcast audio playback via GStreamer's Gst.Player, one instance for
 * the whole app (see NewsWindow.podcast_playback) so playback state is
 * independent of whichever page (news or podcasts) is currently visible -
 * the mini-player bar and this manager both outlive PodcastsView.
 *
 * Unlike HeroCard/ArticleCard/CategorySection's widget classes, this class
 * does NOT need the static-function/set_data() closure discipline those use:
 * that convention exists to avoid a widget's root -> ... -> closure -> self
 * -> root reference cycle. This manager isn't a GTK widget and holds no
 * reference back into a widget tree it also owns - it only connects to
 * signals on its own internal Gst.Player, so plain closures capturing
 * `this` are safe, same as ArticleManager/SidebarManager already do.
 */
namespace Managers {
    public class PodcastPlaybackManager : GLib.Object {
        private Gst.Player player;
        private Paperboy.PodcastEpisode? current_episode = null;
        private double current_rate = 1.0;
        private bool playing = false;
        // Throttles podcast_episode_progress/podcast_last_session writes to
        // roughly once per MIN_PROGRESS_SAVE_INTERVAL_US of playback rather
        // than on every position_updated tick - see maybe_save_progress().
        private const int64 MIN_PROGRESS_SAVE_INTERVAL_US = 5000000;
        private int64 last_progress_save_us = 0;
        private uint64 last_position_ns = 0;
        private uint64 last_duration_ns = 0;
        // Episode list the mini-player's back/forward buttons step
        // through - kept here (not in PodcastPane) so it works even after
        // navigating away from the Podcasts page.
        private Gee.ArrayList<Paperboy.PodcastEpisode>? episode_queue = null;

        public signal void playback_state_changed(bool is_playing);
        public signal void position_updated(uint64 position_ns, uint64 duration_ns);
        public signal void episode_changed(Paperboy.PodcastEpisode episode);
        public signal void episode_queue_changed();
        public signal void playback_error(string message);
        // Explicit position jumps (not normal playback progress), for MPRIS's Seeked signal.
        public signal void seeked(uint64 position_ns);

        public PodcastPlaybackManager() {
            GLib.Object();

            // Without a GMainContext dispatcher, Gst.Player's signals fire
            // from GStreamer's own worker thread, which is unsafe to touch
            // GTK widgets from directly - every manager/widget in this
            // codebase assumes it's always on the GLib main loop.
            var dispatcher = new Gst.PlayerGMainContextSignalDispatcher(null);
            player = new Gst.Player(null, dispatcher);

            player.position_updated.connect((pos) => {
                uint64 duration = player.get_duration();
                last_position_ns = pos;
                last_duration_ns = duration;
                position_updated(pos, duration);
                maybe_save_progress(pos, duration);
            });
            player.state_changed.connect((state) => {
                playing = state == Gst.PlayerState.PLAYING;
                playback_state_changed(playing);
            });
            player.end_of_stream.connect(() => {
                playing = false;
                playback_state_changed(false);
            });
            player.error.connect((err) => {
                playing = false;
                playback_error(err.message);
            });
        }

        // `queue` is the playing show's episode list for Next/Previous; null keeps the current one.
        public void load_and_play(Paperboy.PodcastEpisode episode, double rate = 1.0, Gee.ArrayList<Paperboy.PodcastEpisode>? queue = null) {
            if (queue != null) set_episode_queue(queue);
            current_episode = episode;
            current_rate = rate;
            last_progress_save_us = 0;
            last_position_ns = 0;
            last_duration_ns = 0;
            player.set_uri(episode.audio_url);
            player.play();
            player.set_rate(rate);
            episode_changed(episode);
            // Marked played as soon as playback starts (not on completion) -
            // same "opened it, counts as read" convention ArticleStateStore
            // uses for articles.
            var state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
            state_store.mark_episode_played(episode.episode_id);
            state_store.save_last_session(episode, 0, rate);

            // Resume from where the user left off, unless the episode is
            // already essentially finished (within 10s of its end).
            var progress = state_store.get_episode_progress(episode.episode_id);
            if (progress != null && progress.position_ns > 5000000000
                    && (progress.duration_ns == 0 || progress.position_ns < progress.duration_ns - 10000000000)) {
                player.seek(progress.position_ns);
                seeked(progress.position_ns);
            }
        }

        // Loads an episode paused at a specific position, without marking it
        // played again or applying the normal load_and_play() auto-resume
        // lookup (the position here is already explicit) - used to restore
        // the last session on app startup. See PodcastPlaybackStateStore.
        public void load_paused(Paperboy.PodcastEpisode episode, uint64 position_ns, double rate) {
            current_episode = episode;
            current_rate = rate;
            last_progress_save_us = 0;
            last_position_ns = position_ns;
            last_duration_ns = (uint64) (episode.duration_seconds * 1000000000);
            player.set_uri(episode.audio_url);
            player.pause();
            player.set_rate(rate);
            if (position_ns > 0) player.seek(position_ns);
            episode_changed(episode);
        }

        public void play() { player.play(); }

        public void pause() {
            player.pause();
            flush_progress();
        }

        // Fully stops playback (not just pausing) and clears the current
        // episode - used when the user explicitly closes the mini-player,
        // as opposed to pause() which keeps the episode loaded so play()
        // can resume it. Nothing left to resume, so the saved session is
        // cleared too (per-episode progress is kept, so re-playing it still
        // resumes from here).
        public void stop() {
            flush_progress();
            player.stop();
            current_episode = null;
            playing = false;
            playback_state_changed(false);
            Paperboy.PodcastPlaybackStateStore.get_instance().clear_last_session();
        }

        // Throttled save called from every position_updated tick - persists
        // at most once per MIN_PROGRESS_SAVE_INTERVAL_US of wall-clock time.
        private void maybe_save_progress(uint64 position_ns, uint64 duration_ns) {
            if (current_episode == null) return;
            int64 now = GLib.get_monotonic_time();
            if (last_progress_save_us != 0 && now - last_progress_save_us < MIN_PROGRESS_SAVE_INTERVAL_US) return;
            last_progress_save_us = now;

            var state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
            state_store.save_episode_progress(current_episode.episode_id, position_ns, duration_ns);
            state_store.save_last_session(current_episode, position_ns, current_rate);
        }

        // Saves the current position immediately rather than waiting for the
        // next throttled tick - called on pause() and from the window's
        // close_request handler so the saved position is exact at quit time.
        public void flush_progress() {
            if (current_episode == null) return;
            var state_store = Paperboy.PodcastPlaybackStateStore.get_instance();
            state_store.save_episode_progress(current_episode.episode_id, last_position_ns, last_duration_ns);
            state_store.save_last_session(current_episode, last_position_ns, current_rate);
        }

        public void toggle_play_pause() {
            if (playing) {
                pause();
            } else {
                play();
            }
        }

        public void seek_to(uint64 position_ns) {
            player.seek(position_ns);
            last_position_ns = position_ns;
            seeked(position_ns);
        }

        public void skip(int64 delta_seconds) {
            uint64 pos = player.get_position();
            int64 new_pos = (int64) pos + delta_seconds * 1000000000;
            if (new_pos < 0) new_pos = 0;

            uint64 dur = player.get_duration();
            if (dur > 0 && (uint64) new_pos > dur) new_pos = (int64) dur;

            player.seek((uint64) new_pos);
            last_position_ns = (uint64) new_pos;
            seeked((uint64) new_pos);
        }

        public void set_rate(double rate) {
            current_rate = rate;
            player.set_rate(rate);
        }

        public double get_rate() {
            return current_rate;
        }

        public Paperboy.PodcastEpisode? get_current_episode() {
            return current_episode;
        }

        public bool is_playing() {
            return playing;
        }

        public uint64 get_position_ns() {
            return current_episode != null ? last_position_ns : 0;
        }

        // Falls back to the feed's listed duration until GStreamer knows the real one.
        public uint64 get_duration_ns() {
            if (last_duration_ns > 0 && last_duration_ns != Gst.CLOCK_TIME_NONE) return last_duration_ns;
            return current_episode != null ? (uint64) current_episode.duration_seconds * 1000000000 : 0;
        }

        // Merges a freshly fetched episode list into the queue if it's the playing show's.
        // Older queued episodes the fetch didn't include are kept at the end.
        public void refresh_episode_queue(Gee.ArrayList<Paperboy.PodcastEpisode> fresh) {
            if (current_episode == null || fresh.size == 0) return;
            bool queue_has_current = episode_queue != null && index_in(episode_queue, current_episode.episode_id) >= 0;
            bool same_show = index_in(fresh, current_episode.episode_id) >= 0;
            if (!same_show && queue_has_current) {
                foreach (var e in fresh) {
                    if (index_in(episode_queue, e.episode_id) >= 0) { same_show = true; break; }
                }
            }
            if (!same_show) return;

            var merged = new Gee.ArrayList<Paperboy.PodcastEpisode>();
            merged.add_all(fresh);
            if (queue_has_current) {
                foreach (var e in episode_queue) {
                    if (index_in(fresh, e.episode_id) < 0) merged.add(e);
                }
            }
            set_episode_queue(merged);
        }

        private static int index_in(Gee.ArrayList<Paperboy.PodcastEpisode> episodes, int64 episode_id) {
            for (int i = 0; i < episodes.size; i++) {
                if (episodes[i].episode_id == episode_id) return i;
            }
            return -1;
        }

        private void set_episode_queue(Gee.ArrayList<Paperboy.PodcastEpisode> episodes) {
            episode_queue = episodes;
            Paperboy.PodcastPlaybackStateStore.get_instance().save_last_queue(episodes);
            episode_queue_changed();
        }

        private int current_episode_queue_index() {
            if (episode_queue == null || current_episode == null) return -1;
            return index_in(episode_queue, current_episode.episode_id);
        }

        // Queue is newest-first, so "next" (the following release) is index-1.
        public bool has_next_episode() {
            int idx = current_episode_queue_index();
            return idx > 0;
        }

        public bool has_previous_episode() {
            int idx = current_episode_queue_index();
            return idx >= 0 && idx + 1 < episode_queue.size;
        }

        public void play_next_episode() {
            int idx = current_episode_queue_index();
            if (idx <= 0) return;
            load_and_play(episode_queue[idx - 1], current_rate);
        }

        public void play_previous_episode() {
            int idx = current_episode_queue_index();
            if (idx < 0 || idx + 1 >= episode_queue.size) return;
            load_and_play(episode_queue[idx + 1], current_rate);
        }
    }
}
