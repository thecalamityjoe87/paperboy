using GLib;

// Small centralized app debugger helper so logging can be reused across
// modules without duplicating file IO logic.
public class AppDebugger : GLib.Object {
    // Append a debug line to the provided path. Best-effort; swallow errors.
    public static void append_debug_log(string path, string line) {
        try {
            string p = path;
            string old = "";
            try { GLib.FileUtils.get_contents(p, out old); } catch (GLib.Error e) { old = ""; }
            string outc = old + line + "\n";
            GLib.FileUtils.set_contents(p, outc);
        } catch (GLib.Error e) {
            // best-effort logging only
        }
    }

    // Small helper to join a Gee.ArrayList<string> for debug output
    public static string array_join(Gee.ArrayList<string>? list) {
        if (list == null) return "(null)";
        string out = "";
        try {
            foreach (var s in list) {
                if (out.length > 0) out += ",";
                out += s;
            }
        } catch (GLib.Error e) { return "(error)"; }
        return out;
    }
}
