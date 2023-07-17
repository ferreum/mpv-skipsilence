-- Increase playback speed during silence - a revolution in attention-deficit
-- induction technology.
--
-- Main repository: https://codeberg.org/ferreum/mpv-skipsilence/
--
-- Based on the script https://gist.github.com/bitingsock/e8a56446ad9c1ed92d872aeb38edf124
--
-- This is similar to the NewPipe app's built-in "Fast-forward during silence"
-- feature. The main caveat is that audio-video is desynchronized very easily.
-- For audio-only or audio-focused playback, it works very well.
--
-- Features:
-- - Parameterized speedup ramp, allowing profiles for different kinds of
--   media (ramp_*, speed_*, startdelay options).
-- - Noise reduction of the detected signal. This allows to speed up
--   pauses in speech despite background noise. The output audio is
--   unaffected by default (arnndn_* options).
-- - Workaround for audio-video desynchronization
--   (resync_threshold_droppedframes option).
-- - Workaround for clicks during speed changes (alt_normal_speed option).
-- - Saved time estimation.
-- - osd-msg integration (with user-data, mpv 0.35 dev build and above only).
--
-- Default bindings:
--
-- F2 - toggle
-- F3 - threshold-down
-- F4 - threshold-up
--
-- All supported bindings (bind with 'script-binding skipsilence/<name>'):
--
-- enable - enable the script, if it wasn't enabled.
-- disable - disable the script, if it was enabled.
-- toggle - toggle the script
-- threshold-down - decrease threshold_db by 1 (reduce amount skipped)
-- threshold-up - increase threshold_db by 1 (increase amount skipped)
-- info - show state info in osd
-- cycle-info-style - cycle the infostyle option
-- toggle-arnndn - toggle the arnndn_enable option
-- toggle-arnndn-output - toggle the arnndn_output option
--
-- Script messages (use with 'script-message-to skipsilence <msg> ...':
--
-- adjust-threshold-db <n>
--      Adjust threshold_db by n.
-- enable [no-osd]
--      Enable the script. Passing 'no-osd' suppresses the osd message.
-- disable [<speed>]
--      Disable the script. If speed is specified, set the playback speed to
--      the given value instead of the normal playback speed.
-- info [<style>]
--      Show state as osd message. If style is specified, use it instead of
--      the infostyle option. Defaults to "verbose" if "off".
--
-- User-data (mpv 0.35 dev version and above):
--
-- user-data/skipsilence/enabled - true/false according to enabled state
-- user-data/skipsilence/info - the current info according to the infostyle option
--
-- These allow showing the state in osd like this:
--
--      osd-msg3=...${?user-data/skipsilence/enabled==true:S}...${user-data/skipsilence/info}
--
-- This shows "S" when skipsilence is enabled and shows the selected infostyle
-- in the next lines (infostyle=compact recommended).
--
-- Configuration:
--
-- For how to use these options, search the mpv man page for 'script-opts',
-- 'change-list', 'Key/value list options', and 'Configuration' for the
-- 'script-opts/osc.conf' documentation.
-- Use the prefix 'skipsilence' (unless the script was renamed).
local opts = {
    -- The silence threshold in decibel. Anything quieter than this is
    -- detected as silence. Can be adjusted with the threshold-up,
    -- threshold-down bindings, and adjust-threshold-db script message.
    threshold_db = -24,
    -- Minimum duration of silence to be detected, in seconds. This is
    -- measured in stream time, as if playback speed was 1.
    threshold_duration = 0.1,
    -- How long to wait before speedup. This is measured in real time, thus
    -- higher playback speeds would reduce the length of content skipped.
    startdelay = 0.05,

    -- How often to update the speed during silence, in seconds of real time.
    speed_updateinterval = 0.2,
    -- The maximum playback speed during silence.
    speed_max = 4,

    -- Speedup ramp parameters. The formula for playback speedup is:
    --
    --     ramp_constant + (time * ramp_factor) ^ ramp_exponent
    --
    -- Where time is the real time passed since start of speedup.
    -- The result is multiplied with the original playback speed.
    --
    -- - ramp_constant should always be greater or equal to one, otherwise it
    --   will slow down at the start of silence.
    -- - Setting ramp_factor to 0 disables the ramp, resulting in a constant
    --   speed during silence.
    -- - ramp_exponent is the "acceleration" of the curve. A value of 1
    --   results in a linear curve, values above 1 increase the speed faster
    --   the more time has passed, while values below 1 speed up at
    --   decreasing intervals.
    -- - The more aggressive this curve is configured, the faster
    --   audio and video is desynchronized. If video stutters and drops frames
    --   when silence starts, reduce ramp_constant to improve this problem.
    ramp_constant = 1.5,
    ramp_factor = 1.15,
    ramp_exponent = 1.2,

    -- Noise reduction filter configuration.
    --
    -- This allows removing noise from the audio stream before the
    -- silencedetect filter, allowing to speed up pauses in speed despite
    -- background noise. The output audio is unaffected by default.
    --
    -- Whether the detected audio signal should be preprocessed with arnndn.
    -- If arnndn_modelpath is empty, this has no effect
    arnndn_enable = true,
    -- Path to the rnnn file containing the model parameters. If empty,
    -- noise reduction is disabled.
    -- The mpv config path can be referenced with the prefix '~~/'.
    -- Avoid special characters in this option, they must be escaped to
    -- work with "af add lavfi=[arnndn='...']".
    arnndn_modelpath = "",
    -- Whether the denoised signal should be used as the output. Disabled by
    -- default, so the output is unaffected.
    arnndn_output = false,

    -- If >= 0, use this value instead of a playback speed of 1.
    -- This is a work around to stop audio clicks when switching between
    -- normal playback and speeding up. Playing back at a slightly different
    -- speed (e.g. 1.01x), keeps the scaletempo2 filter active, so audio is
    -- played back without interruptions.
    alt_normal_speed = -1,

    -- When disabling skipsilence, fix audio sync if this many frames have
    -- been dropped since the last playback restart (seek, etc.).
    -- Disabled if value is less than 0.
    --
    -- When disabling skipsilence while frame-drop-count is greater or equal
    -- to configured value, audio-video sync is fixed by running
    -- 'seek 0 exact'. May produce a short pause and/or audio repeat.
    --
    -- Note that frame-drop-count does not exactly correspond to the
    -- audio-video desynchronization. It is used as a proxy to avoid
    -- resyncing every time the script is disabled. Recommended value: 100.
    resync_threshold_droppedframes = -1,

    -- Info style used for the 'user-data/skipsilence/info' property and
    -- the default of the 'info' script-message/binding.
    -- May be one of
    -- - 'off' (no information),
    -- - 'total' (show total saved time),
    -- - 'compact' (show total and latest saved time),
    -- - 'verbose' (show most information).
    infostyle = "off",

    -- How to apply external speed change during silence.
    -- This to makes speed change bindings work during fast forward. Set the
    -- value according to what you use to change speed:
    -- - 'add' - add the difference to the normal speed
    -- - 'multiply' - multiply the normal speed with factor of change
    -- If 'off', the script will immediately override the speed during silence.
    apply_speed_change = "off",

    debug = false,
}

local orig_speed = 1
local is_silent = false
local expected_speed = 1
local last_speed_change_time = -1
local is_paused = false
local did_clear_after_seek = false

local events_ifirst = 1
local events_ilast = 0
local events = {}

local check_time_timer

local detect_filter_label = mp.get_script_name() .. "_silencedetect"

local function dprint(...)
    if opts.debug then
        print(("%.3f"):format(mp.get_time()), ...)
    end
end

local function get_silence_filter()
    local filter = "silencedetect=n="..opts.threshold_db.."dB:d="..opts.threshold_duration
    if opts.arnndn_enable and opts.arnndn_modelpath ~= "" then
        local path = mp.command_native{"expand-path", opts.arnndn_modelpath}
        local rnn = "arnndn='"..path.."'"
        filter = rnn..","..filter
        if not opts.arnndn_output then
            -- need amix with to keep the detection filter branch advancing
            -- and not lagging behind. Weights only keep the original audio.
            filter = "asplit[ao],"..filter..",[ao]amix='weights=1 0'"
        end
    end
    return "@"..detect_filter_label..":lavfi=["..filter.."]"
end

local function events_count()
    return events_ilast - events_ifirst + 1
end

local function clear_events()
    events_ifirst = 1
    events_ilast = 0
    events = {}
end

local function drop_event()
    local i = events_ifirst
    assert(i <= events_ilast, "event list is empty")
    events[i] = nil
    events_ifirst = i + 1
end

local speed_stats
local function stats_clear()
    speed_stats = {
        saved_total = 0,
        saved_current = 0,
        period_current = 0,
        silence_start_time = 0,
        time = nil,
        speed = 1,
        pause_start_time = nil,
    }
end
stats_clear()

local function get_saved_time(now)
    local s = speed_stats
    if not s.time then
        return s.saved_current, s.period_current
    end
    local period = (s.pause_start_time or now) - s.time
    local period_orig = period * s.speed / orig_speed
    local saved = period_orig - period
    -- avoid negative value caused by float precision
    if saved > -0.001 and saved <= 0 then saved = 0 end
    return s.saved_current + saved, s.period_current + period_orig
end

local function stats_accumulate(now, speed)
    local s = speed_stats
    s.saved_current, s.period_current = get_saved_time(now)
    s.time = s.pause_start_time or now
    s.speed = speed
end

local function stats_start_current(now, speed)
    local s = speed_stats
    s.saved_current = 0
    s.period_current = 0
    s.silence_start_time = s.pause_start_time or now
    s.time = s.pause_start_time or now
    s.speed = speed
end

local function stats_end_current(now)
    local s = speed_stats
    stats_accumulate(now, s.speed)
    s.saved_total = s.saved_total + s.saved_current
    s.silence_start_time = nil
    s.time = nil
end

local function stats_handle_pause(now, pause)
    local s = speed_stats
    if pause then
        if not s.pause_start_time then
            s.pause_start_time = now
        end
    else
        if s.pause_start_time and is_silent then
            local pause_delta = now - s.pause_start_time
            s.silence_start_time = s.silence_start_time + pause_delta
            s.time = s.time + pause_delta
        end
        s.pause_start_time = nil
    end
end

local function stats_silence_length(now)
    local s = speed_stats
    return (s.pause_start_time or now) - s.silence_start_time
end

local function get_current_stats(now)
    local s = speed_stats
    local saved, period_current = get_saved_time(now)
    local saved_total = s.saved_total + (s.time and saved or 0)
    return saved_total, period_current, saved
end

local function format_info(style, now)
    local saved_total, period_current, saved =
        get_current_stats(now or mp.get_time())
    if style == "total" then
        return ("Saved total: %.3fs"):format(saved_total)
    end

    local silence_stats = ("Saved total: %.3fs\nLatest: %.3fs, %.3fs saved")
        :format(saved_total, period_current, saved)
    if style == "compact" then
        return silence_stats
    end
    local enabled = mp.get_property("af"):find("@"..detect_filter_label..":")
    return "Status: "..(enabled and "enabled" or "disabled").."\n"
        ..("Threshold: %+gdB, %gs (+%gs)\n"):format(opts.threshold_db, opts.threshold_duration, opts.startdelay)
        .."Arnndn: "..(opts.arnndn_enable and opts.arnndn_modelpath ~= ""
                        and "enabled"..(opts.arnndn_output and " with output" or "") or "disabled").."\n"
        ..("Speed ramp: %g + (time * %g) ^ %g\n"):format(opts.ramp_constant, opts.ramp_factor, opts.ramp_exponent)
        ..("Max speed: %gx, Update interval: %gs\n"):format(opts.speed_max, opts.speed_updateinterval)
        ..silence_stats
end

local function update_info(now)
    if opts.infostyle == "total" or opts.infostyle == "compact" or opts.infostyle == "verbose" then
        local s = speed_stats
        if opts.infostyle == "compact" and s.saved_total + s.saved_current == 0 and s.time == nil then
            return false
        end
        mp.set_property_native("user-data/skipsilence/info",
            "\n"..format_info(opts.infostyle, now))
        return true
    end
    return false
end

local function update_info_now()
    if not update_info(mp.get_time()) then
        mp.set_property_native("user-data/skipsilence/info", "")
    end
end

local function clear_silence_state()
    if is_silent then
        stats_end_current(mp.get_time())
        mp.set_property("speed", orig_speed)
        mp.commandv("af", "remove", "@"..detect_filter_label)
        mp.commandv("af", "pre", get_silence_filter())
    end
    clear_events()
    is_silent = false
    if check_time_timer ~= nil then
        check_time_timer:kill()
    end
end

local function get_next_event()
    while true do
        local ev = events[events_ifirst]
        if not ev then return end
        if ev.is_silent ~= is_silent then return ev end
        drop_event()
    end
end

local schedule_check_time -- function
local function check_time()
    local now = mp.get_time()
    local speed = mp.get_property_number("speed")

    local new_speed = nil
    local did_change = is_silent
    local was_silent = is_silent

    while true do
        local ev = get_next_event()
        if not ev then break end

        -- leave time for gap end to arrive before speeding up
        if ev.is_silent and opts.startdelay > 0 then
            local remaining = opts.startdelay - (now - ev.recv_time)
            if remaining > 0 and events_count() < 2 then
                dprint("event is too recent; recheck in", remaining)
                schedule_check_time(remaining)
                break
            end
        end

        is_silent = ev.is_silent
        did_change = true
        if is_silent then
            stats_start_current(now, speed)
            dprint("silence start")

            if not was_silent then
                orig_speed = speed
                if opts.alt_normal_speed >= 0 and math.abs(orig_speed - 1) < 0.001 then
                    orig_speed = opts.alt_normal_speed
                    new_speed = orig_speed
                end
            end
        else
            stats_end_current(now)

            dprint("silence end, saved:", get_saved_time(now, speed))
            new_speed = orig_speed
        end

        drop_event()
    end
    if is_silent then
        local remaining = opts.speed_updateinterval - (now - last_speed_change_time)
        if remaining > 0 then
            dprint("last speed change too recent; recheck in", remaining)
            schedule_check_time(remaining)
        else
            local length = stats_silence_length(now)
            new_speed = orig_speed * (opts.ramp_constant + (length * opts.ramp_factor) ^ opts.ramp_exponent)
            schedule_check_time(opts.speed_updateinterval)
        end
        did_change = true
    end
    if new_speed then
        local new_speed = math.min(new_speed, opts.speed_max)
        expected_speed = new_speed
        if new_speed ~= speed then
            mp.set_property("speed", new_speed)
            last_speed_change_time = mp.get_time()
        end
    end
    dprint("check_time: new_speed:", new_speed, "is_silent:", is_silent)
    if did_change then
        update_info(now)
    end
end

function schedule_check_time(time)
    if check_time_timer == nil then
        check_time_timer = mp.add_timeout(time, check_time)
    else
        check_time_timer:kill()
        check_time_timer.timeout = time
        check_time_timer:resume()
    end
end

local function handle_pause(name, paused)
    dprint("handle_pause", name, paused)
    is_paused = paused
    stats_handle_pause(mp.get_time(), paused)
    if paused then
        if check_time_timer then
            check_time_timer:kill()
        end
    else
        check_time()
    end
end

local function handle_speed(name, speed)
    dprint("handle_speed", speed)
    if is_silent then
        stats_accumulate(mp.get_time(), speed)
    end
    if math.abs(speed - expected_speed) > 0.01 then
        local do_check = check_time_timer and check_time_timer:is_enabled()
        dprint("handle_speed: external speed change: got", speed, "instead of", expected_speed)
        if is_silent then
            if opts.apply_speed_change == "add" then
                orig_speed = orig_speed + speed - expected_speed
                do_check = true
            elseif opts.apply_speed_change == "multiply" then
                orig_speed = orig_speed * speed / expected_speed
                do_check = true
            end
        end
        if do_check then
            check_time()
        end
    end
end

local function add_event(time, is_silent)
    local prev = events[events_ilast]
    if not prev or is_silent ~= prev.is_silent then
        local i = events_ilast + 1
        events[i] = {
            recv_time = mp.get_time(),
            time = time,
            is_silent = is_silent,
        }
        events_ilast = i
        if not is_paused then
            check_time()
        end
    end
end

local function handle_silence_msg(msg)
    if msg.prefix ~= "ffmpeg" then return end
    if msg.text:find("^silencedetect: silence_start: ") then
        dprint("got silence start:", (msg.text:gsub("\n$", "")))
        add_event(st, true)
    elseif msg.text:find("^silencedetect: silence_end: ") then
        dprint("got silence end:", (msg.text:gsub("\n$", "")))
        add_event(et, false)
    end
end

local function adjust_thresholdDB(change)
    local value = opts.threshold_db + change
    mp.commandv("change-list", "script-opts", "append",
        mp.get_script_name().."-threshold_db="..value)
    mp.osd_message("silence threshold: "..value.."dB")
end

local function toggle_option(opt_name)
    local value = not opts[opt_name]
    local str = value and "yes" or "no"
    mp.commandv("change-list", "script-opts", "append",
        mp.get_script_name().."-"..opt_name.."="..str)
    mp.osd_message(mp.get_script_name().."-"..opt_name..": "..str)
end

local function cycle_info_style(style)
    local value = style or (
        opts.infostyle == "total" and "compact" or (
        opts.infostyle == "compact" and "verbose" or (
        opts.infostyle == "verbose" and "off" or "total")))
    mp.commandv("change-list", "script-opts", "append",
        mp.get_script_name().."-infostyle="..value)
    mp.osd_message(mp.get_script_name().."-infostyle: "..value)
end

local function handle_start_file()
    dprint("handle_start_file")
    clear_silence_state()
    stats_clear()
    update_info_now()
end

local function handle_playback_restart()
    dprint("handle_playback_restart")
    -- avoid clearing events that were received between seek and restart
    if not did_clear_after_seek then
        clear_silence_state()
    end
    did_clear_after_seek = false
end

-- events on seek:
-- 1. seek event
-- 2. core-idle=true
-- 3. seeking=true
-- 4. (if target is silent) silence start msg
-- 5. playback-restart event
-- 6. core-idle=false
-- 7. seeking=false
local function handle_seek()
    dprint("handle_seek")
    clear_silence_state()
    did_clear_after_seek = true
end

local function enable(flag)
    if mp.get_property("af"):find("@"..detect_filter_label..":") then return end
    mp.commandv("af", "pre", get_silence_filter())
    if not mp.get_property("af"):find("@"..detect_filter_label..":") then return end
    mp.set_property_native("user-data/skipsilence/enabled", true)
    if flag ~= "no-osd" then
        mp.osd_message("skipsilence enabled")
    end
    mp.register_event("log-message", handle_silence_msg)
    mp.register_event("start-file", handle_start_file)
    mp.register_event("playback-restart", handle_playback_restart)
    mp.register_event("seek", handle_seek)
    mp.observe_property("core-idle", "bool", handle_pause)
    mp.observe_property("speed", "number", handle_speed)
end

local function disable(opt_orig_speed)
    if not mp.get_property("af"):find("@"..detect_filter_label..":") then return end
    mp.commandv("af", "remove", "@"..detect_filter_label)
    mp.osd_message("skipsilence disabled")
    mp.unregister_event(handle_silence_msg)
    mp.unregister_event(handle_start_file)
    mp.unregister_event(handle_playback_restart)
    mp.unregister_event(handle_seek)
    mp.unobserve_property(handle_pause)
    mp.unobserve_property(handle_speed)
    if check_time_timer ~= nil then
        check_time_timer:kill()
    end
    if opt_orig_speed then
        mp.set_property_number("speed", opt_orig_speed)
    else
        local speed = is_silent and orig_speed or mp.get_property_number("speed")
        if opts.alt_normal_speed and math.abs(speed - opts.alt_normal_speed) < 0.001 then
            mp.set_property_number("speed", 1)
        elseif is_silent then
            mp.set_property_number("speed", speed)
        end
    end
    if is_silent then
        stats_end_current(mp.get_time())
    end
    clear_events()
    is_silent = false
    mp.set_property_native("user-data/skipsilence/enabled", false)
    if opts.resync_threshold_droppedframes >= 0 then
        local drops = mp.get_property_number("frame-drop-count")
        if drops and drops >= opts.resync_threshold_droppedframes then
            mp.commandv("seek", "0", "exact")
        end
    end
end

local function toggle()
    if mp.get_property("af"):find("@"..detect_filter_label..":") then
        disable()
    else
        enable()
    end
end

local function info(style)
    mp.osd_message(format_info(style or opts.infostyle))
end

local function check_reapply_filter()
    if mp.get_property("af"):find("@"..detect_filter_label..":") then
        if is_silent or events_count() > 0 then
            clear_silence_state()
        else
            mp.commandv("af", "remove", "@"..detect_filter_label)
            mp.commandv("af", "pre", get_silence_filter())
        end
    end
end

(require "mp.options").read_options(opts, nil, function(list)
    if list['threshold_db'] or list['threshold_duration']
        or list["arnndn_enable"] or list["arnndn_modelpath"]
        or list["arnndn_output"] then
        check_reapply_filter()
    end
    if list['infostyle'] then
        update_info_now()
    end
    if list["ramp_constant"] or list["ramp_factor"] or list["ramp_exponent"]
        or list["speed_updateinterval"] or list["speed_max"] then
        if is_silent then
            check_time()
        end
        update_info_now()
    end
end)

mp.set_property_native("user-data/skipsilence/info", "")

mp.enable_messages("v")
mp.add_key_binding(nil, "enable", enable)
mp.add_key_binding(nil, "disable", disable)
mp.add_key_binding("F2", "toggle", toggle)
mp.register_script_message("adjust-threshold-db", adjust_thresholdDB)
mp.add_key_binding("F3", "threshold-down", function() adjust_thresholdDB(-1) end, "repeatable")
mp.add_key_binding("F4", "threshold-up", function() adjust_thresholdDB(1) end, "repeatable")
mp.add_key_binding(nil, "info", info, "repeatable")
mp.add_key_binding(nil, "cycle-info-style", cycle_info_style, "repeatable")
mp.add_key_binding(nil, "toggle-arnndn", function() toggle_option("arnndn_enable") end)
mp.add_key_binding(nil, "toggle-arnndn-output", function() toggle_option("arnndn_output") end)

-- vim:set sw=4 sts=0 et tw=0:
