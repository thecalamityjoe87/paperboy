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

using GLib;

// A publisher's official embed player page, as played by VideoPlayerDialog.
public class VideoEmbed : GLib.Object {
    public string url;
    // Run in the embed page once it loads, for players that need a nudge to autoplay.
    public string? page_script;
    // Run before the embed page's own scripts.
    public string? start_script;

    public VideoEmbed(string url, string? page_script = null, string? start_script = null) {
        this.url = url;
        this.page_script = page_script;
        this.start_script = start_script;
    }
}

// Maps a detected video to the page VideoPlayerDialog loads. Any player page or media file works
// generically (for_block); the per-site rules below only add autoplay or reach players a site doesn't advertise.
public class VideoEmbedResolver : GLib.Object {
    private const string ESPN_EMBED_URL = "https://www.espn.com/core/video/iframe?id=%s";
    // Keeps pressing play until a video is playing (the button renders before its click handler is
    // attached). ESPN mutes a scripted start, and the ad and clip share one <video>, so unmute once
    // per source, 1s in.
    private const string ESPN_PRESS_PLAY_JS = "(function(){var n=0;var t=setInterval(function(){var playing=false;document.querySelectorAll('video').forEach(function(v){if(v.paused)return;playing=true;if(v.dataset.pbUnmutedSrc!==v.currentSrc&&v.currentTime>1){v.dataset.pbUnmutedSrc=v.currentSrc;v.muted=false;}});if(++n>240){clearInterval(t);return;}if(!playing){var b=document.querySelector('[aria-label=\"Play video\"]');if(b)b.click();}},500);})();";

    // Fox's embed autoplays with sound on its own. Adding a d= parameter makes Fox Business 404.
    private const string FOX_EMBED_URL = "https://video.%s.com/v/video-embed.html?video_id=%s&autoplay=true";

    private const string ABC_EMBED_URL = "https://abcnews.com/video/embed?id=%s&autoplay=true";
    // Dismisses the "Introducing Verts" promo ABC's embed shows over the video (it lives in its own frame).
    // "Headlines from ABC News Live", which ABC attaches to stories that have no video of their own.
    private const string ABC_FILLER_VIDEO_ID = "71045364";
    private const string ABC_DISMISS_PROMO_JS = "(function(){var n=0;var t=setInterval(function(){var b=document.querySelector('button.v-close');if(b){b.click();clearInterval(t);}else if(++n>60){clearInterval(t);}},500);})();";

    // Hides WebKit's native audio/video track lists so Video.js manages tracks itself. Otherwise WebKit's
    // own MSE track disables the player's separate audio track, and playback stalls after the first segment.
    private const string BRIGHTCOVE_EMULATE_TRACKS_JS = "['audioTracks','videoTracks'].forEach(function(p){Object.defineProperty(HTMLMediaElement.prototype,p,{get:function(){return undefined;},configurable:true});});";

    private const string PBS_EMBED_URL = "https://player.pbs.org/viralplayer/%s/?autoplay=true";

    public static VideoEmbed espn_clip(string clip_id) {
        return new VideoEmbed(ESPN_EMBED_URL.printf(GLib.Uri.escape_string(clip_id, null, false)), ESPN_PRESS_PLAY_JS);
    }

    // A publisher watch page or player URL, or null if no rule matches.
    public static VideoEmbed? for_url(string url) {
        try {
            GLib.MatchInfo mi;
            if (new GLib.Regex("^https?://(?:www\\.)?(foxnews|foxbusiness)\\.com/video/(\\d+)").match(url, 0, out mi)) {
                return new VideoEmbed(FOX_EMBED_URL.printf(mi.fetch(1), mi.fetch(2)));
            }
            if (new GLib.Regex("^https?://(?:www\\.)?abcnews\\.(?:go\\.)?com/(?:[^?#]*/)?video/(?:[a-z0-9-]*-)?(\\d{6,})").match(url, 0, out mi)) {
                return new VideoEmbed(ABC_EMBED_URL.printf(mi.fetch(1)), ABC_DISMISS_PROMO_JS);
            }
            if (new GLib.Regex("^https?://player\\.pbs\\.org/viralplayer/(\\d+)").match(url, 0, out mi)) {
                return new VideoEmbed(PBS_EMBED_URL.printf(mi.fetch(1)));
            }
            if (new GLib.Regex("^https://players\\.brightcove\\.net/").match(url)) {
                return new VideoEmbed(url, null, BRIGHTCOVE_EMULATE_TRACKS_JS);
            }
        } catch (GLib.RegexError e) {
        }
        return null;
    }

    // Any detected video (see ArticleExtractorService): a site rule if one matches, else the player page
    // itself, or a local page wrapping it (media files, and players that must be iframed).
    public static VideoEmbed? for_block(ArticleBlockKind kind, string url) {
        var site = for_url(url);
        if (site != null) return site;

        string? page = null;
        if (kind == ArticleBlockKind.VIDEO_FILE || is_media_file(url)) {
            page = VideoPageServer.media_page_url(url);
        } else if (kind == ArticleBlockKind.VIDEO_EMBED) {
            page = needs_iframe(url) ? VideoPageServer.iframe_page_url(url) : url;
        }
        return page != null ? new VideoEmbed(page) : null;
    }

    public static bool is_media_file(string url) {
        return GLib.Regex.match_simple("\\.(mp4|m4v|webm|mov|m3u8)(\\?|#|$)", url, GLib.RegexCompileFlags.CASELESS);
    }

    private static bool needs_iframe(string url) {
        string lower = url.down();
        return lower.contains("youtube.com/embed") || lower.contains("youtube-nocookie.com/embed")
            || lower.contains("player.vimeo.com") || lower.contains("dailymotion.com/embed");
    }

    // A lead video a site only names in its page data, as a URL for_url() accepts.
    public static string? lead_video_url_from_page(string page_url, string html) {
        try {
            // ABC renders its lead video from page state: "videoId":"136794747".
            if (new GLib.Regex("^https?://(?:www\\.)?abcnews\\.(?:go\\.)?com/").match(page_url)) {
                GLib.MatchInfo mi;
                if (new GLib.Regex("\"videoId\":\"?(\\d{6,})").match(html, 0, out mi)) {
                    do {
                        string id = mi.fetch(1);
                        if (id != ABC_FILLER_VIDEO_ID) return "https://abcnews.com/video/%s/".printf(id);
                    } while (mi.next());
                }
            }
        } catch (GLib.RegexError e) {
        }
        return null;
    }
}
