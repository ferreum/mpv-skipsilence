# mpv-skipsilence

Increase playback speed during silence - a revolution in attention-deficit
induction technology.

Main repository: https://codeberg.org/ferreum/mpv-skipsilence/

Based on the script https://gist.github.com/bitingsock/e8a56446ad9c1ed92d872aeb38edf124

This is similar to the NewPipe app's built-in "Fast-forward during silence"
feature. The main caveat is that audio-video is desynchronized very easily.
For audio-only or audio-focused playback, it works very well.

## Features:

- Parameterized speedup ramp, allowing profiles for different kinds of
  media (`ramp_*`, `speed_*`, `startdelay` options).
- Noise reduction of the detected signal. This allows to speed up
  pauses in speech despite background noise. The output audio is
  unaffected by default (`arnndn_*` options).
- Workaround for audio-video desynchronization
  (`resync_threshold_droppedframes` option).
- Workaround for clicks during speed changes (`alt_normal_speed` option).
- Saved time estimation.
- osd-msg integration (with user-data, mpv 0.36 and above only).

## Default bindings

- F2 - toggle
- F3 - threshold-down
- F4 - threshold-up

## Documentation

For detailed usage check the comments in the [script](skipsilence.lua).

## Profiles

Mpv's named profiles can be used to switch between different presets. Create
profiles in `mpv.conf` and apply them with the `apply-profile` command.

    [skipsilence-default]
    script-opts-append=skipsilence-ramp_constant=1.5
    script-opts-append=skipsilence-ramp_factor=1.15
    script-opts-append=skipsilence-ramp_exponent=1.2
    script-opts-append=skipsilence-speed_max=4
    script-opts-append=skipsilence-speed_updateinterval=0.2
    script-opts-append=skipsilence-startdelay=0.05

Bind it to a key in `input.conf`:

    F5 script-message-to skipsilence enable no-osd; apply-profile skipsilence-default; show-text "skipsilence profile: default"

### Profile suggestions

    # very smooth speed increase, up to 3x
    [skipsilence-smooth]
    script-opts-append=skipsilence-ramp_constant=1.1
    script-opts-append=skipsilence-ramp_factor=0.25
    script-opts-append=skipsilence-ramp_exponent=1.15
    script-opts-append=skipsilence-speed_max=3
    script-opts-append=skipsilence-speed_updateinterval=0.25
    script-opts-append=skipsilence-startdelay=0.2

    # very aggressive skipping, will destroy audio-video sync,
    # tends to make it hard to listen
    [skipsilence-extreme]
    script-opts-append=skipsilence-ramp_constant=2
    script-opts-append=skipsilence-ramp_factor=1.5
    script-opts-append=skipsilence-ramp_exponent=2
    script-opts-append=skipsilence-speed_max=6
    script-opts-append=skipsilence-speed_updateinterval=0.1
    script-opts-append=skipsilence-startdelay=0

    # long wait (1s) before speeding up quickly
    [skipsilence-patient]
    script-opts-append=skipsilence-ramp_constant=1.5
    script-opts-append=skipsilence-ramp_factor=1
    script-opts-append=skipsilence-ramp_exponent=1.2
    script-opts-append=skipsilence-speed_max=4
    script-opts-append=skipsilence-speed_updateinterval=0.25
    script-opts-append=skipsilence-startdelay=1
