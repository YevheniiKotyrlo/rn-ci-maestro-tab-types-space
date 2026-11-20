# React Native CI's Maestro 2.6.1 types a space for `pressKey: tab` on Android

React Native's Android E2E job installs Maestro with `export MAESTRO_VERSION=2.6.1; curl -Ls "https://get.maestro.mobile.dev" | bash` (`.github/actions/maestro-android/action.yml`). Under that version, a flow's `pressKey: tab` types a space into the focused `TextInput` of RNTester, and keyboard focus stays where it was.

`./reproduce.sh` takes the newest `main` commit whose Test All run passed and, from that commit and that run:

1. reads the Maestro version `.github/actions/maestro-android/action.yml` installs;
2. downloads the run's `rntester-release` artifact, the APK `test_e2e_android_rntester` installs (`app-arm64-v8a-release.apk`);
3. installs that Maestro version with the same installer, into `.repro/` rather than `~/.maestro`;
4. installs RNTester and opens `rntester://example/TextInput/uncontrolledComponent`;
5. runs `maestro/focus-input.yml` (`tapOn` the `uncontrolled-textinput`, `eraseText`), then `maestro/press-tab.yml` (`pressKey: tab`), and reads the TextInput's `text` and `focused` from `uiautomator dump` after each.

It needs one Android emulator or device on adb (`ANDROID_SERIAL` picks one), `gh` signed in, `curl`, `unzip` and Java 17. It exits 1 while Tab types into the TextInput, 0 once the TextInput stays empty after Tab, and 2 when a step fails before that check. `REPRO_MAESTRO_VERSION=2.12.1 ./reproduce.sh` runs another Maestro version in place of the pin.

The `ReproducerApp/` folder is the template's and is not used.
