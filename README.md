# mpv-skipsilence

Increase playback speed during silence - a revolution in attention-deficit
induction technology.

Main repository: https://codeberg.org/ferreum/mpv-skipsilence/

Based on the script https://gist.github.com/bitingsock/e8a56446ad9c1ed92d872aeb38edf124

This is similar to the NewPipe app's built-in "Fast-forward during silence"
feature.

> Note: In mpv version 0.36 and below, the `scaletempo2` filter (default since
> mpv version 0.34) caused audio-video de-synchronization when changing speed a
> lot. See [mpv issue #12028](https://github.com/mpv-player/mpv/issues/12028).
> Small, frequent speed changes instead of large steps can help to reduce this
> problem. The scaletempo and rubberband filters didn't have this problem, but
> have different audio quality characteristics.

## Features:

- Parameterized speedup ramp, allowing profiles for different kinds of
  media (`ramp_*`, `speed_*`, `startdelay` options).
- Noise reduction of the detected signal. This allows to speed up
  pauses in speech despite background noise. The output audio is
  unaffected by default (`arnndn_*` options).
- Workaround for scaletempo2 audio-video desynchronization in mpv 0.36 and
  below (`resync_threshold_droppedframes` option).
- Workaround for clicks during speed changes with scaletempo2 in mpv 0.36 and
  below (`alt_normal_speed` option).
- Saved time estimation.
- Integration with osd-msg, auto profiles, etc. (with user-data, mpv 0.36 and
  above only).

## Default bindings

- F2 - toggle
- F3 - threshold-down
- F4 - threshold-up

## Documentation

For detailed usage check the comments in the [script](skipsilence.lua).

## Recommendations

### Temporarily disable display sync

When using `video-sync=display-*`, speed changes tend to cause increased video
lag. Because display sync is less useful while speed keeps changing, it's
recommended to use `video-sync=audio` (the default) while this script is
active. This results in smoother video playback during speed transitions.

The following profile can be used to automatically switch to `video-sync=audio`
when skipsilence is enabled and restore it when disabled (requires mpv 0.36 or
above for user-data):

    [auto-skipsilence-videosync]
    profile-cond=get("user-data/skipsilence/enabled")
    profile-restore=copy-equal
    video-sync=audio

### Profiles

Mpv's profiles can be used to switch between different presets. Create profiles
in `mpv.conf` and apply them with the `apply-profile` command.

    [skipsilence-default]
    script-opts-append=skipsilence-ramp_constant=1.5
    script-opts-append=skipsilence-ramp_factor=1.15
    script-opts-append=skipsilence-ramp_exponent=1.2
    script-opts-append=skipsilence-speed_max=4
    script-opts-append=skipsilence-speed_updateinterval=0.2
    script-opts-append=skipsilence-startdelay=0.05

Bind it to a key in `input.conf`:

    F5 script-message-to skipsilence enable no-osd; apply-profile skipsilence-default; show-text "skipsilence profile: default"

#### Examples

    # very smooth speed increase, up to 3x
    [skipsilence-smooth]
    script-opts-append=skipsilence-ramp_constant=1
    script-opts-append=skipsilence-ramp_factor=0.4
    script-opts-append=skipsilence-ramp_exponent=1.45
    script-opts-append=skipsilence-speed_max=3
    script-opts-append=skipsilence-speed_updateinterval=0.05
    script-opts-append=skipsilence-startdelay=0
    script-opts-append=skipsilence-threshold_duration=0.25

    # very aggressive skipping, will destroy audio-video sync,
    # tends to make it hard to listen
    [skipsilence-extreme]
    script-opts-append=skipsilence-ramp_constant=1.75
    script-opts-append=skipsilence-ramp_factor=4
    script-opts-append=skipsilence-ramp_exponent=0.9
    script-opts-append=skipsilence-speed_max=6
    script-opts-append=skipsilence-speed_updateinterval=0.05
    script-opts-append=skipsilence-startdelay=0
    script-opts-append=skipsilence-threshold_duration=0.05

    # long wait (1s) before speeding up quickly
    [skipsilence-patient]
    script-opts-append=skipsilence-ramp_constant=1.25
    script-opts-append=skipsilence-ramp_factor=3
    script-opts-append=skipsilence-ramp_exponent=0.9
    script-opts-append=skipsilence-speed_max=4
    script-opts-append=skipsilence-speed_updateinterval=0.05
    script-opts-append=skipsilence-startdelay=0
    script-opts-append=skipsilence-threshold_duration=1
