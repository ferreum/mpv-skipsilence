
local opts = {
    threshold_db = -20,
    threshold_duration = 0.2,
    startdelay = 0.05,
    speed_updateinterval = 0.2,
    maxspeed = 4,
    arnndn_enable = true,
    arnndn_modelpath = "",
    arnndn_output = false,
    alt_normal_speed = -1,
    ramp_constant = 2,
    ramp_factor = 1.15,
    ramp_exponent = 1.2,
    infostyle = "off",
    resync_threshold_droppedframes = -1,
    debug = false,
}

local orig_speed = 1
local is_silent = false
local expected_speed = 1
local last_speed_change_time = -1
local pause_states = {}
local is_paused = false

local events_ifirst = 1
local events_ilast = 0
local events = {}

local check_time_timer

local detect_filter_label = mp.get_script_name() .. "_silencedetect"

local orig_print = print
local function print(...)
    if opts.debug then
        orig_print(("%.3f"):format(mp.get_time()), ...)
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
        ..("Max speed: %gx, Update interval: %gs\n"):format(opts.maxspeed, opts.speed_updateinterval)
        ..silence_stats
end

local function update_info(now)
    if opts.infostyle == "compact" or opts.infostyle == "verbose" then
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

local function check_time(time_pos)
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
                print("event is too recent; recheck in", remaining)
                schedule_check(remaining)
                break
            end
        end

        is_silent = ev.is_silent
        did_change = true
        if is_silent then
            stats_start_current(now, speed)
            print("silence start at", time_pos)

            if not was_silent then
                orig_speed = speed
                if opts.alt_normal_speed >= 0 and math.abs(orig_speed - 1) < 0.001 then
                    orig_speed = opts.alt_normal_speed
                    new_speed = orig_speed
                end
            end
        else
            stats_end_current(now)

            print("silence end at", time_pos, "saved:", get_saved_time(now, speed))
            new_speed = orig_speed
        end

        drop_event()
    end
    if is_silent then
        local remaining = opts.speed_updateinterval - (now - last_speed_change_time)
        if remaining > 0 then
            print("last speed change too recent; recheck in", remaining)
            schedule_check(remaining)
        else
            local length = stats_silence_length(now)
            new_speed = orig_speed * (opts.ramp_constant + (length * opts.ramp_factor) ^ opts.ramp_exponent)
            schedule_check(opts.speed_updateinterval)
        end
        did_change = true
    end
    if new_speed then
        local new_speed = math.min(new_speed, opts.maxspeed)
        expected_speed = new_speed
        if new_speed ~= speed then
            mp.set_property("speed", new_speed)
            last_speed_change_time = mp.get_time()
        end
    end
    print("check_time:", time_pos, "new_speed:", new_speed, "is_silent:", is_silent)
    if did_change then
        update_info(now)
    end
end

local function check_time_immediate()
    local time = mp.get_property_number("audio-pts")
    if time then
        check_time(time)
    else
        print("invalid state for immediate check_time call; waiting for playback-restart")
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
            check_time_immediate()
        end
    end
end

local function handle_pause(name, value)
    print("handle_pause", name, value)
    pause_states[name] = value
    is_paused = false
    local k, v
    for k, v in pairs(pause_states) do
        if v then is_paused = true break end
    end
    stats_handle_pause(mp.get_time(), is_paused)
    if is_paused then
        if check_time_timer then
            check_time_timer:kill()
        end
    else
        check_time_immediate()
    end
end

local function handle_speed(name, speed)
    print("handle_speed", speed)
    if is_silent then
        stats_accumulate(mp.get_time(), speed)
    end
    local diff = math.abs(speed - expected_speed)
    if diff > 0.1 and check_time_timer and check_time_timer:is_enabled() then
        print("handle_speed: unexpected speed change: got", speed, "instead of", expected_speed)
        check_time_immediate()
    end
end

local function handle_silence_msg(msg)
    if msg.prefix ~= "ffmpeg" then return end
    if msg.text:find("^silencedetect: silence_start: ") then
        print("got silence start:", msg.text:gsub("\n$", ""))
        add_event(st, true)
    elseif msg.text:find("^silencedetect: silence_end: ") then
        print("got silence end:", msg.text:gsub("\n$", ""))
        add_event(et, false)
    end
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
        opts.infostyle == "compact" and "verbose" or (
        opts.infostyle == "verbose" and "off" or "compact"))
    mp.commandv("change-list", "script-opts", "append",
        mp.get_script_name().."-infostyle="..value)
    mp.osd_message(mp.get_script_name().."-infostyle: "..value)
end

local function handle_start_file()
    print("handle_start_file")
    clear_silence_state()
    stats_clear()
    update_info_now()
end

local function handle_playback_restart()
    print("handle_playback_restart")
    clear_silence_state()
end

function schedule_check(time)
    if check_time_timer == nil then
        check_time_timer = mp.add_timeout(time, function()
            check_time_immediate()
        end)
    else
        check_time_timer:kill()
        check_time_timer.timeout = time
        check_time_timer:resume()
    end
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
    mp.observe_property("pause", "bool", handle_pause)
    mp.observe_property("eof-reached", "bool", handle_pause)
    mp.observe_property("paused-for-cache", "bool", handle_pause)
    mp.observe_property("speed", "number", handle_speed)
end


local function disable(opt_orig_speed)
    if not mp.get_property("af"):find("@"..detect_filter_label..":") then return end
    mp.commandv("af", "remove", "@"..detect_filter_label)
    mp.osd_message("skipsilence disabled")
    mp.unregister_event(handle_silence_msg)
    mp.unregister_event(handle_start_file)
    mp.unregister_event(handle_playback_restart)
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

-- volume display seems to have weird side effects (stops arnndn)
-- local function handle_volume_msg(msg)
--     if msg.text:find("^Parsed_volumedetect_[0-9]+: max_volume") then
--         mp.osd_message(msg.text)
--     end
-- end
-- local timer = nil
-- local function voldetect()
--     if timer ~= nil and timer:is_enabled() then
--         timer:kill()
--         timer = nil
--         mp.unregister_event(handle_volume_msg)
--         mp.command("no-osd af remove lavfi=volumedetect")
--     else
--         mp.register_event("log-message", handle_volume_msg)
--         mp.command("no-osd af remove lavfi=volumedetect")
--         timer = mp.add_periodic_timer(0.2, function()
--             mp.command("no-osd af pre lavfi=volumedetect")
--             mp.add_timeout(0.19, function()
--                 mp.command("no-osd af remove lavfi=volumedetect")
--             end)
--         end)
--     end
-- end

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
        or list["speed_updateinterval"] or list["maxspeed"] then
        if is_silent then
            check_time_immediate()
        end
        update_info_now()
    end
end)

mp.set_property_native("user-data/skipsilence/info", "")

mp.enable_messages("v")
mp.add_key_binding(nil, "enable", enable)
mp.add_key_binding(nil, "disable", disable)
mp.add_key_binding("F2", "toggle", toggle)
-- mp.add_key_binding("Shift+F2", "voldetect", voldetect)
mp.register_script_message("adjust-threshold-db", adjust_thresholdDB)
mp.add_key_binding("F3", "threshold-down", function() adjust_thresholdDB(-1) end, "repeatable")
mp.add_key_binding("F4", "threshold-up", function() adjust_thresholdDB(1) end, "repeatable")
mp.add_key_binding(nil, "info", info, "repeatable")
mp.add_key_binding(nil, "cycle-info-style", cycle_info_style, "repeatable")
mp.add_key_binding(nil, "toggle-arnndn", function() toggle_option("arnndn_enable") end)
mp.add_key_binding(nil, "toggle-arnndn-output", function() toggle_option("arnndn_output") end)

-- vim:set sw=4 sts=0 et tw=0:
