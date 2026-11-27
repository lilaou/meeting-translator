# Test fixtures

This directory is copied into the test bundle (`resources: [.copy("Fixtures")]` in
`Package.swift`); tests load its files through `Bundle.module`, so they are found on a
device as well as on a Mac.

## Benchmark recording for the Apple speech engine device test

`AppleSpeechEngineDeviceTests.appleEngineTranscribesTheBenchmarkRecording` needs two files
that are not in the repository yet:

- `benchmark-en.wav` — an English meeting or lecture recording (about 1-3 minutes). The
  repository is public, so the recording's license must allow redistribution. Do not add
  private meeting recordings here (those go in the ignored `recordings/` directory).
- `benchmark-en.txt` — exactly three keywords that are clearly spoken in the recording, one
  per line. The test checks that the joined final text contains each one (case-insensitive).

## Running the device test

The test is skipped unless `RUN_DEVICE_TESTS` is set and both files are in the test bundle;
the skip message names whatever is missing. Run it on an iPhone with iOS 26 or later and the
English speech assets installed, with the environment variable `RUN_DEVICE_TESTS=1` set in
the test scheme, or as `TEST_RUNNER_RUN_DEVICE_TESTS=1` in the shell when running
`xcodebuild test` on a device (see `docs/phase1-acceptance.md`; unverified).
