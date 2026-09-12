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

/**
 * Centralized HTTP client utility with performance optimizations:
 * - Connection pooling and keep-alive
 * - Request deduplication
 * - Concurrency throttling with thread pool
 * - Unified error handling
 * - Standardized user-agent and headers
 */

namespace Paperboy {

public class HttpClientUtils : Object {
    // Eagerly constructed to avoid lazy-init races across threads.
    private static HttpClientUtils _instance = new HttpClientUtils();

    // HTTP session (reused for connection pooling)
    private Soup.Session session;

    // Concurrency control
    private static GLib.Mutex _request_mutex = new GLib.Mutex();
    private static int _active_requests = 0;
    // Balances My Feed's fan-out against glibc malloc arena contention
    // from concurrent XML/image decoding (see mallopt in main.vala).
    private const int MAX_CONCURRENT_REQUESTS = 16;

    // Thread pool for request processing (reduces thread spawning overhead)
    private ThreadPool<HttpTask>? thread_pool;

    // Request deduplication cache (prevents fetching same URL multiple times)
    private Gee.HashMap<string, RequestState> in_flight_requests;
    private GLib.Mutex cache_mutex = new GLib.Mutex();

    // User-Agent strings (centralized configuration)
    public const string USER_AGENT_DEFAULT = "paperboy/1.0";
    public const string USER_AGENT_BROWSER = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
    public const string USER_AGENT_FIREFOX = "Mozilla/5.0 (Linux; rv:91.0) Gecko/20100101 Firefox/91.0";

    // Timeout configurations (seconds)
    public const uint TIMEOUT_DEFAULT = 15;
    public const uint TIMEOUT_FAST = 8;
    public const uint TIMEOUT_SLOW = 30;


    // Request state for deduplication
    private class RequestState {
        public bool completed;
        public GLib.Bytes? response;
        public uint status_code;
        public GLib.Error? error;

        public RequestState() {
            completed = false;
        }
    }


    // HTTP task for thread pool
    private class HttpTask {
        public string url;
        public RequestOptions options;
        public owned HttpResponseCallback? callback;

        public HttpTask(string url, RequestOptions options, owned HttpResponseCallback? callback) {
            this.url = url;
            this.options = options;
            this.callback = (owned) callback;
        }
    }

    // Request configuration options
    public class RequestOptions {
        public string method = "GET";
        public string user_agent = USER_AGENT_DEFAULT;
        public Gee.HashMap<string, string>? headers = null;
        public uint timeout = TIMEOUT_DEFAULT;
        public bool enable_cache = true;
        public bool enable_deduplication = true;

        public RequestOptions() {}

        public RequestOptions with_browser_headers() {
            user_agent = USER_AGENT_BROWSER;
            if (headers == null) headers = new Gee.HashMap<string, string>();
            headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8";
            headers["Accept-Language"] = "en-US,en;q=0.5";
            headers["Accept-Encoding"] = "gzip, deflate, br";
            return this;
        }

        public RequestOptions with_image_headers() {
            user_agent = USER_AGENT_BROWSER;
            if (headers == null) headers = new Gee.HashMap<string, string>();
            headers["Accept"] = "image/webp,image/png,image/jpeg,image/*;q=0.8";
            headers["Accept-Encoding"] = "gzip, deflate, br";
            return this;
        }

        public RequestOptions with_json_headers() {
            if (headers == null) headers = new Gee.HashMap<string, string>();
            headers["Accept"] = "application/json";
            headers["Content-Type"] = "application/json";
            return this;
        }

        public RequestOptions with_timeout(uint seconds) {
            timeout = seconds;
            return this;
        }

        public RequestOptions without_deduplication() {
            enable_deduplication = false;
            return this;
        }
    }


    // HTTP response wrapper
    public class HttpResponse {
        public uint status_code;
        public GLib.Bytes? body;
        public string? error_message;
        public Gee.HashMap<string, string>? headers;

        public bool is_success() {
            return status_code == Soup.Status.OK;
        }

        public string? get_body_string() {
            if (body == null) return null;
            return (string) body.get_data();
        }

        public uint8[]? get_body_data() {
            if (body == null) return null;
            unowned uint8[] data = body.get_data();
            uint8[] copy = new uint8[data.length];
            Memory.copy(copy, data, data.length);
            return copy;
        }

        public string? get_header(string name) {
            if (headers == null) return null;
            return headers.get(name.down());
        }
    }


    // Callback for async requests
    public delegate void HttpResponseCallback(HttpResponse response);


    public static HttpClientUtils get_default() {
        // Forces GType registration so class_init has run and _instance is set,
        // even if a worker thread gets here first.
        var _type = typeof (HttpClientUtils);
        return _instance;
    }

    // Call from the main thread at startup so the singleton exists before
    // any worker thread races to get_default().
    public static void ensure_initialized() {
        var _type = typeof (HttpClientUtils);

        if (_instance == null) {
            _instance = new HttpClientUtils();
        }
    }


    private HttpClientUtils() {
        // Plain constructor only: setting max-conns/max-conns-per-host via
        // GLib.Object.new() property varargs crashes libsoup under
        // concurrent use, so we're stuck with its default per-host limits.
        session = new Soup.Session() {
            timeout = TIMEOUT_DEFAULT
        };

        in_flight_requests = new Gee.HashMap<string, RequestState>();

        // Created lazily on first async fetch to avoid spawning threads
        // during singleton construction.
        thread_pool = null;
    }


    private void process_http_task(owned HttpTask task) {
        HttpResponse response = fetch_sync_internal(task.url, task.options);

        if (task.callback != null) {
            Idle.add(() => {
                task.callback(response);
                return false;
            });
        }
    }

    // Block until a request slot is free, then claim it.
    private static void acquire_request_slot() {
        _request_mutex.lock();
        while (_active_requests >= MAX_CONCURRENT_REQUESTS) {
            _request_mutex.unlock();
            Thread.usleep(50000); // 50ms
            _request_mutex.lock();
        }
        _active_requests++;
        _request_mutex.unlock();
    }

    private static void release_request_slot() {
        _request_mutex.lock();
        _active_requests--;
        _request_mutex.unlock();
    }


    // Synchronous fetch (internal implementation)
    private HttpResponse fetch_sync_internal(string url, RequestOptions options) {
        var response = new HttpResponse();

        // Check deduplication cache
        if (options.enable_deduplication) {
            cache_mutex.lock();
            RequestState? state = in_flight_requests.get(url);

            if (state != null) {
                if (state.completed) {
                    // Return cached response
                    response.status_code = state.status_code;
                    response.body = state.response;
                    response.error_message = state.error != null ? state.error.message : null;
                    cache_mutex.unlock();
                    return response;
                } else {
                    // Request in flight, wait for completion with retry limit
                    cache_mutex.unlock();

                    // Check retry count to prevent unbounded recursion
                    const int MAX_DEDUP_RETRIES = 50; // 50 * 100ms = 5 seconds max wait
                    int retry_count = 0;
                    while (retry_count < MAX_DEDUP_RETRIES) {
                        Thread.usleep(100000); // 100ms
                        retry_count++;

                        cache_mutex.lock();
                        RequestState? retry_state = in_flight_requests.get(url);
                        if (retry_state != null && retry_state.completed) {
                            // Request completed, return cached response
                            var cached_response = new HttpResponse();
                            cached_response.status_code = retry_state.status_code;
                            cached_response.body = retry_state.response;
                            cached_response.error_message = retry_state.error != null ? retry_state.error.message : null;
                            cache_mutex.unlock();
                            return cached_response;
                        }
                        cache_mutex.unlock();
                    }

                    // Timeout waiting for in-flight request - make our own request
                    // First remove stale entry
                    cache_mutex.lock();
                    in_flight_requests.unset(url);
                    cache_mutex.unlock();
                    return fetch_sync_internal(url, options);
                }
            }

            // Mark request as in-flight
            state = new RequestState();
            in_flight_requests.set(url, state);
            
            // Cap cache growth: clear the oldest completed half once we exceed this.
            const int MAX_CACHE_SIZE = 100;
            if (in_flight_requests.size > MAX_CACHE_SIZE) {
                // Clear oldest half of entries to avoid frequent clears
                var keys_to_remove = new Gee.ArrayList<string>();
                int to_remove = in_flight_requests.size / 2;
                int removed = 0;
                foreach (var entry in in_flight_requests.entries) {
                    if (removed >= to_remove) break;
                    if (entry.value.completed) {
                        keys_to_remove.add(entry.key);
                        removed++;
                    }
                }
                foreach (var key in keys_to_remove) {
                    in_flight_requests.unset(key);
                }
            }
            
            cache_mutex.unlock();
        }

        // Only the actual network attempt counts against the concurrency
        // cap; dedup hits above already returned. finally covers all early
        // returns so every caller is bounded the same way.
        acquire_request_slot();
        try {
        try {
            // Create request
            var msg = new Soup.Message(options.method, url);
            if (msg == null) {
                response.status_code = 0;
                response.error_message = "Failed to create HTTP request";
                return response;
            }

            // Set headers
            var headers = msg.get_request_headers();
            headers.append("User-Agent", options.user_agent);
            headers.append("Connection", "keep-alive"); // Enable keep-alive for connection reuse

            if (options.headers != null) {
                foreach (var entry in options.headers.entries) {
                    headers.append(entry.key, entry.value);
                }
            }

            // Temporarily set timeout for this request
            uint old_timeout = session.timeout;
            session.timeout = options.timeout;

            // Perform request
            GLib.Bytes? body = session.send_and_read(msg, null);
            session.timeout = old_timeout;

            // Extract response
            response.status_code = msg.get_status();
            response.body = body;

            // Extract response headers
            response.headers = new Gee.HashMap<string, string>();
            var response_headers = msg.get_response_headers();
            response_headers.foreach((name, value) => {
                response.headers.set(name.down(), value);
            });

            // Update cache
            if (options.enable_deduplication) {
                cache_mutex.lock();
                RequestState? state = in_flight_requests.get(url);
                if (state != null) {
                    state.completed = true;
                    state.response = body;
                    state.status_code = response.status_code;
                }
                cache_mutex.unlock();

                // Clean up cache after 5 seconds
                GLib.Timeout.add_seconds(5, () => {
                    cache_mutex.lock();
                    in_flight_requests.unset(url);
                    cache_mutex.unlock();
                    return false;
                });
            }

        } catch (GLib.Error e) {
            // Check if this is an HTTP/2 error (or an INTERNAL_ERROR) - retry
            // with HTTP/1.1 and also attempt a retry without Brotli (br)
            // in Accept-Encoding which some servers mishandle over HTTP/2.
            // "TLS connection was non-properly terminated" is a known
            // symptom of the same underlying failure class under a
            // different name - some CDNs (e.g. Cloudflare) can drop an
            // HTTP/2 connection mid-stream in a way libsoup/GnuTLS surfaces
            // as a TLS-layer error rather than an explicit HTTP/2 one
            // (observed fetching 9to5google.com's homepage). Worth the same
            // forced-HTTP/1.1 retry as the HTTP/2 case above.
            bool is_http2_style_error = e.message != null && (
                (e.message.contains("HTTP/2") && !e.message.contains("INTERNAL_ERROR")) ||
                e.message.contains("non-properly terminated")
            );
            if (is_http2_style_error) {
                try {
                    // Create a new session for the retry
                    var http1_session = new Soup.Session() {
                        timeout = options.timeout
                    };

                    var retry_msg = new Soup.Message(options.method, url);
                    if (retry_msg != null) {
                        // Force HTTP/1.1 to avoid HTTP/2 issues with this server
                        retry_msg.set_force_http1(true);

                        var retry_headers = retry_msg.get_request_headers();
                        retry_headers.append("User-Agent", options.user_agent);

                        if (options.headers != null) {
                            foreach (var entry in options.headers.entries) {
                                retry_headers.append(entry.key, entry.value);
                            }
                        }

                        GLib.Bytes? retry_body = http1_session.send_and_read(retry_msg, null);
                        response.status_code = retry_msg.get_status();
                        response.body = retry_body;

                        // Extract response headers
                        response.headers = new Gee.HashMap<string, string>();
                        var retry_response_headers = retry_msg.get_response_headers();
                        retry_response_headers.foreach((name, value) => {
                            response.headers.set(name.down(), value);
                        });

                        // Update cache on successful retry
                        if (options.enable_deduplication) {
                            cache_mutex.lock();
                            RequestState? retry_state = in_flight_requests.get(url);
                            if (retry_state != null) {
                                retry_state.completed = true;
                                retry_state.response = retry_body;
                                retry_state.status_code = response.status_code;
                            }
                            cache_mutex.unlock();
                        }

                        return response;
                    }
                } catch (GLib.Error retry_e) {
                    // Retry also failed, fall through to normal error handling
                    response.error_message = retry_e.message;
                }
            }

            response.status_code = 0;
            if (response.error_message == null) {
                response.error_message = e.message;
            }

            // Update cache with error
            if (options.enable_deduplication) {
                cache_mutex.lock();
                RequestState? state = in_flight_requests.get(url);
                if (state != null) {
                    state.completed = true;
                    state.error = e;
                }
                cache_mutex.unlock();
            }
        }
        } finally {
            release_request_slot();
        }

        return response;
    }

    //Asynchronous fetch with callback (uses thread pool)
    public void fetch_async(string url, RequestOptions? options, owned HttpResponseCallback callback) {
        var opts = options ?? new RequestOptions();
        var task = new HttpTask(url, opts, (owned) callback);

        // Create thread pool lazily (thread-safe): if it's not created yet,
        // attempt to create it. If creation fails, fall back to spawning a
        // dedicated thread for this task.
        if (thread_pool == null) {
            try {
                thread_pool = new ThreadPool<HttpTask>.with_owned_data(
                    (t) => { process_http_task(t); },
                    (int) MAX_CONCURRENT_REQUESTS,
                    false
                );
            } catch (ThreadError e) {
                warning("Failed to create HTTP thread pool: %s", e.message);
                thread_pool = null;
            }
        }

        if (thread_pool != null) {
            try {
                thread_pool.add((owned) task);
                return;
            } catch (ThreadError e) {
                warning("Failed to add task to thread pool: %s", e.message);
            }
        }

        // Fallback to spawning new thread
        new Thread<void*>("http-fetch", () => {
            process_http_task(task);
            return null;
        });
    }


    // Synchronous fetch (blocks until complete)
    public HttpResponse fetch_sync(string url, RequestOptions? options = null) {
        var opts = options ?? new RequestOptions();
        return fetch_sync_internal(url, opts);
    }


    // Convenience method: Fetch string content
    public void fetch_string(string url, RequestOptions? options, owned HttpResponseCallback callback) {
        fetch_async(url, options, (response) => {
            callback(response);
        });
    }


    // Convenience method: Fetch binary data (images, etc.)
    public void fetch_bytes(string url, RequestOptions? options, owned HttpResponseCallback callback) {
        fetch_async(url, options, (response) => {
            callback(response);
        });
    }


    // Convenience method: Fetch and parse JSON
    public void fetch_json(string url, owned JsonResponseCallback callback) {
        var options = new RequestOptions().with_json_headers();
        fetch_async(url, options, (response) => {
            Json.Parser? parser = null;
            Json.Node? root = null;

            if (response.is_success() && response.body != null) {
                try {
                    parser = new Json.Parser();
                    string body = response.get_body_string();
                    parser.load_from_data(body);
                    root = parser.get_root();
                } catch (GLib.Error e) {
                    warning("JSON parse error for %s: %s", url, e.message);
                }
            }

            callback(response, parser, root);
        });
    }

    public delegate void JsonResponseCallback(HttpResponse response, Json.Parser? parser, Json.Node? root);


    // Clear request cache (for testing or manual cache invalidation)
    public void clear_cache() {
        cache_mutex.lock();
        in_flight_requests.clear();
        cache_mutex.unlock();
    }


    // Get current active request count (for monitoring)
    public int get_active_request_count() {
        _request_mutex.lock();
        int count = _active_requests;
        _request_mutex.unlock();
        return count;
    }
}

} // namespace Paperboy
