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
- osd-msg integration (with user-data, mpv 0.35 dev build and above only).

## Default bindings:

- F2 - toggle
- F3 - threshold-down
- F4 - threshold-up

For detailed usage check the comments in the [script](skipsilence.lua).
