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

// Current conditions and today's high/low for one place, from Open-Meteo.
public class WeatherReport : GLib.Object {
    public double temperature;
    public double high;
    public double low;
    // WMO weather interpretation code.
    public int code;
    public bool is_day;
    public bool fahrenheit;
    public int64 fetched_at_us;

    public string icon_name() {
        string suffix = is_day ? "" : "-night";
        if (code <= 1) return "weather-clear" + suffix + "-symbolic";
        if (code == 2) return "weather-few-clouds" + suffix + "-symbolic";
        if (code == 3) return "weather-overcast-symbolic";
        if (code == 45 || code == 48) return "weather-fog-symbolic";
        if (code >= 51 && code <= 57) return "weather-showers-scattered-symbolic";
        if ((code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return "weather-showers-symbolic";
        if ((code >= 71 && code <= 77) || code == 85 || code == 86) return "weather-snow-symbolic";
        if (code >= 95) return "weather-storm-symbolic";
        return "weather-overcast-symbolic";
    }

    public string description() {
        if (code == 0) return "Clear";
        if (code == 1) return "Mostly clear";
        if (code == 2) return "Partly cloudy";
        if (code == 3) return "Overcast";
        if (code == 45 || code == 48) return "Fog";
        if (code >= 51 && code <= 55) return "Drizzle";
        if (code == 56 || code == 57) return "Freezing drizzle";
        if (code >= 61 && code <= 65) return "Rain";
        if (code == 66 || code == 67) return "Freezing rain";
        if ((code >= 71 && code <= 75) || code == 77) return "Snow";
        if (code >= 80 && code <= 82) return "Rain showers";
        if (code == 85 || code == 86) return "Snow showers";
        if (code == 95) return "Thunderstorm";
        if (code >= 96) return "Thunderstorm with hail";
        return "";
    }

    public static string format_degrees(double value) {
        return "%d°".printf((int) Math.round(value));
    }
}
