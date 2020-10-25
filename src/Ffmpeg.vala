/* Copyright 2020 Yikun Liu <cos.lyk@gmail.com>
 *
 * This program is free software: you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be
 * useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
 * Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program. If not, see http://www.gnu.org/licenses/.
 */

namespace VideoSplitter.Ffmpeg {

    errordomain FfmpegError {
        VIDEO_PARSE_FAILED,
        CONVERT_FAILED
    }


    [Compact]
    public class VideoInfo {
        public string format;
        public double duration;
        public string vcodec;
        public string pix_fmt;
        public int64 width;
        public int64 height;
        public int64 bits_per_raw_sample;
        public string acodec;
        public string audio_channel_layout;
        public int64 audio_channels;
        public int64 audio_sample_rate;
        public int64 int_prop_hash;
    }

    // Parse videos
    public VideoInfo parse_video (string filepath) throws Error {

        // Run ffprobe
        (unowned string)[] args = {
            "ffprobe",
            "-hide_banner",
            "-loglevel", "warning",
            "-of", "json",
            "-show_format",
            "-show_streams",
            "-i", filepath
        };
        string output;
        string err;
        int exit_status;
        Process.spawn_sync (null, args, null, SpawnFlags.SEARCH_PATH, null, out output, out err, out exit_status);
        if (err.length != 0) {
            throw new FfmpegError.VIDEO_PARSE_FAILED (err);
        }

        // Parse output
        var parser = new Json.Parser ();
        parser.load_from_data (output);
        unowned Json.Object? root = parser.get_root ().get_object ();
        if (root == null) {
            throw new FfmpegError.VIDEO_PARSE_FAILED ("Cannot parse the output of ffprobe.");
        }

        VideoInfo info = new VideoInfo ();

        // Format
        unowned Json.Object? root_format = root.get_object_member ("format");
        if (root_format == null) {
            throw new FfmpegError.VIDEO_PARSE_FAILED ("Cannot parse the output of ffprobe.");
        }

        unowned string format_str = root_format.get_string_member ("format_name");
        string[] formats = format_str.split(",");
        int idx = filepath.last_index_of_char ('.');
        if (idx != -1) {
            string ext = filepath.substring (idx + 1);
            if (ext in formats) {
                info.format = (owned) ext;
            } else {
                info.format = (owned) formats[0];
            }
        } else {
            info.format = (owned) formats[0];
        }

        // Duration
        info.duration = double.parse (root_format.get_string_member ("duration"));

        // Streams
        info.vcodec = info.acodec = null;

        unowned Json.Array root_streams = root.get_array_member ("streams");
        for (int i = 0; i < root_streams.get_length (); i++) {
            unowned Json.Object stream = root_streams.get_object_element (i);
            if (stream.get_string_member ("codec_type") == "video") {
                info.vcodec = stream.get_string_member ("codec_name");
                info.pix_fmt = stream.get_string_member ("pix_fmt");
                info.width = stream.get_int_member ("width");
                info.height = stream.get_int_member ("height");
                info.bits_per_raw_sample = int64.parse (stream.get_string_member ("bits_per_raw_sample"));
            } else if (stream.get_string_member ("codec_type") == "audio") {
                info.acodec = stream.get_string_member ("codec_name");
                info.audio_channel_layout = stream.get_string_member ("channel_layout");
                info.audio_channels = stream.get_int_member ("channels");
                info.audio_sample_rate = int64.parse (stream.get_string_member ("sample_rate"));
            }
        }

        // Check if video and audio streams are parsed
        if (info.vcodec == null || info.acodec == null) {
            throw new FfmpegError.VIDEO_PARSE_FAILED ("Cannot extract information of streams.");
        }

        // Calculate hash
        info.int_prop_hash = info.width + (info.height << 16) + (info.bits_per_raw_sample << 32) +
                             (info.audio_channels << 40) + ((info.audio_sample_rate / 100) << 48);
        
        return info;
    }


    // Cut videos
    public async void cut (string infile, string outfile, string format, double start_pos, double end_pos,
                           bool keyframe_cut, bool remove_audio) throws Error {

        string start_pos_str = Utils.time2str (start_pos);
        string duration_str = Utils.time2str (end_pos - start_pos);

        var args = new GenericArray<unowned string?> ();
        args.add ("ffmpeg");
        args.add ("-hide_banner");
        args.add ("-loglevel");
        args.add ("warning");

        // Cut position parameters
        if (keyframe_cut) {
            args.add ("-ss");
            args.add (start_pos_str);
            args.add ("-i");
            args.add (infile);
            args.add ("-t");
            args.add (duration_str);
            args.add ("-avoid_negative_ts");
            args.add ("make_zero");
        } else {
            args.add ("-i");
            args.add (infile);
            args.add ("-ss");
            args.add (start_pos_str);
            args.add ("-t");
            args.add (duration_str);
        }

        // No re-encoding
        args.add ("-c");
        args.add ("copy");

        // Remove audio
        if (remove_audio) {
            args.add ("-an");
        }
        
        args.add ("-ignore_unknown");

        // Enable experimental operation
        args.add ("-strict");
        args.add ("experimental");

        // Output format
        args.add ("-f");
        args.add (format);

        // Output file
        args.add ("-y");
        args.add (outfile);
        args.add (null);

        // Run ffmpeg
        yield Utils.run_process (args.data);
    }


    // Merge videos
    public async void merge (string[] infiles, string outfile, string format) throws Error {

        // FFMpeg args
        (unowned string)[] args = {
            "ffmpeg", "-hide_banner",
            "-loglevel", "warning",    // less output
            "-f", "concat",            // merge files
            "-safe", "0",              // Disable safe check
            "-protocol_whitelist","file,pipe",
            "-i", "-",                 // Read file list from pipe
            "-c", "copy",              // No re-encoding
            "-ignore_unknown",
            "-strict", "experimental", // Enable experimental operation
            "-f", format,              // Output file format
            "-y", outfile              // Output file
        };

        // Generate list of files for concat
        var entries = new GenericArray<string> ();
        foreach (unowned string infile in infiles) {
            entries.add ("file '%s'".printf (infile.replace ("'", "'\\''")));
        }
        var concat_text = string.joinv ("\n", entries.data);

        // Run ffmpeg
        yield Utils.run_process (args, concat_text);
    }
}