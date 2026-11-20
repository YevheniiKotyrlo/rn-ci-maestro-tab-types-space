#!/usr/bin/env bash
# Presses Tab in RNTester's uncontrolled TextInput through the Maestro version React Native's Android E2E CI
# installs, on the RNTester release APK that CI built from the same main commit.
#
# Needs: one Android emulator or device on adb (ANDROID_SERIAL picks one), gh signed in, curl, unzip and Java 17.
# REPRO_MAESTRO_VERSION=<version> runs another Maestro version in place of the pin.
#
# Exits 1 while Tab types into the focused TextInput, 0 once the TextInput stays empty after Tab, and 2 when a step
# fails before that check.
set -uo pipefail

repo=react/react-native
app_id=com.facebook.react.uiapp
link=rntester://example/TextInput/uncontrolledComponent
input_id=uncontrolled-textinput
work=.repro

inconclusive() {
  echo "SUMMARY: inconclusive: $1"
  exit 2
}

cd "$(dirname "$0")" || inconclusive "cannot enter the reproducer's folder"
rm -rf "$work" || inconclusive "cannot clear $work"
mkdir -p "$work/home" || inconclusive "cannot make $work"

host=$(uname -srm) || inconclusive "uname failed"
java_version=$(java -version 2>&1 | head -n 1) || inconclusive "java -version failed"
adb_version=$(adb version | head -n 1) || inconclusive "adb version failed"
echo "host: $host; $java_version; $adb_version"

# 1. The newest react-native main commit whose Test All run passed, and the Maestro version that commit's Android E2E
#    action installs.
run_line=$(gh run list --repo "$repo" --branch main --workflow test-all.yml --status success --limit 1 \
  --json databaseId,headSha --jq '.[0] | "\(.databaseId) \(.headSha)"') || inconclusive "gh run list failed"
run_id=${run_line%% *}
sha=${run_line#* }
[[ -n $run_id && -n $sha && $run_id != "$sha" ]] || inconclusive "no successful Test All run on main"
echo "react-native main $sha, Test All run https://github.com/$repo/actions/runs/$run_id"
action=$(gh api -H 'Accept: application/vnd.github.raw+json' \
  "repos/$repo/contents/.github/actions/maestro-android/action.yml?ref=$sha") ||
  inconclusive "cannot read .github/actions/maestro-android/action.yml at $sha"
install_line=$(grep -m 1 -E 'MAESTRO_VERSION=' <<<"$action") ||
  inconclusive "no MAESTRO_VERSION in .github/actions/maestro-android/action.yml at $sha"
pin=$(grep -oE 'MAESTRO_VERSION=[0-9][0-9.]*' <<<"$install_line") || inconclusive "cannot read the version in: $install_line"
pin=${pin#MAESTRO_VERSION=}
install_command=$(sed -E 's/^ *run: *//' <<<"$install_line") || inconclusive "cannot read: $install_line"
echo ".github/actions/maestro-android/action.yml at ${sha:0:10}: $install_command"
version=${REPRO_MAESTRO_VERSION:-$pin}
[[ $version == "$pin" ]] || echo "REPRO_MAESTRO_VERSION: running Maestro $version in place of the pinned $pin"

# 2. RNTester's release APK from that run: the APK test_e2e_android_rntester installs.
gh run download "$run_id" --repo "$repo" --name rntester-release --dir "$work/apk" > /dev/null ||
  inconclusive "cannot download the rntester-release artifact of run $run_id"
apk=$work/apk/app-arm64-v8a-release.apk
[[ -f $apk ]] || inconclusive "the rntester-release artifact holds no app-arm64-v8a-release.apk"
apk_bytes=$(wc -c < "$apk") || inconclusive "cannot read $apk"
echo "APK: rntester-release/app-arm64-v8a-release.apk, $((apk_bytes)) bytes"

# 3. Maestro, installed the way the action installs it, into .repro/ rather than ~/.maestro.
curl -fsSL https://get.maestro.mobile.dev -o "$work/install-maestro.sh" || inconclusive "cannot download Maestro's installer"
HOME=$PWD/$work/home ZDOTDIR=$PWD/$work/home MAESTRO_DIR=$PWD/$work/maestro MAESTRO_VERSION=$version \
  bash "$work/install-maestro.sh" > "$work/install-maestro.log" 2>&1 ||
  inconclusive "Maestro $version did not install; see $work/install-maestro.log"
export MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true
maestro=$work/maestro/bin/maestro
maestro_version=$("$maestro" --version 2> /dev/null | tail -n 1) || inconclusive "the installed Maestro does not run"
echo "Maestro CLI: $maestro_version"
device=()
[[ -z ${ANDROID_SERIAL:-} ]] || device=(--device "$ANDROID_SERIAL")

# 4. The device.
adb wait-for-device || inconclusive "no device on adb"
release=$(adb shell getprop ro.build.version.release | tr -d '\r') || inconclusive "adb shell failed"
sdk=$(adb shell getprop ro.build.version.sdk | tr -d '\r') || inconclusive "adb shell failed"
abis=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r') || inconclusive "adb shell failed"
ime=$(adb shell settings get secure default_input_method | tr -d '\r') || inconclusive "adb shell failed"
echo "device: Android $release (API $sdk), ABIs $abis, input method $ime"

# Prints the TextInput's text and focused attributes, as uiautomator dumps the window, as `<text>|<focused>`.
read_input() {
  local xml node text focused
  adb shell uiautomator dump /sdcard/repro-window.xml > /dev/null || return 1
  xml=$(adb exec-out cat /sdcard/repro-window.xml) || return 1
  node=$(grep -oE "<node [^>]*resource-id=\"$input_id\"[^>]*>" <<<"$xml") || return 1
  text=$(sed -E 's/.* text="([^"]*)".*/\1/' <<<"$node") || return 1
  focused=$(sed -E 's/.* focused="([^"]*)".*/\1/' <<<"$node") || return 1
  echo "$text|$focused"
}

# 5. Install RNTester and open the uncontrolled TextInput example alone, as CI's textinput-uncontrolled.yml does.
adb install -r "$apk" > "$work/install-apk.log" 2>&1 || inconclusive "adb install failed; see $work/install-apk.log"
adb shell am force-stop "$app_id" || inconclusive "adb shell failed"
adb shell am start -W -a android.intent.action.VIEW -d "$link" -p "$app_id" > "$work/start.log" 2>&1 ||
  inconclusive "cannot open $link; see $work/start.log"
echo "opened $link in $app_id"

# 6. Tap the TextInput and empty it, then press Tab: two flows, so the TextInput is read between them.
"$maestro" "${device[@]}" test -e "APP_ID=$app_id" maestro/focus-input.yml > "$work/focus-input.log" 2>&1 ||
  inconclusive "maestro/focus-input.yml failed; see $work/focus-input.log"
before=$(read_input) || inconclusive "uiautomator found no $input_id after focus-input.yml"
echo "after tapOn + eraseText: $input_id text=\"${before%|*}\" focused=${before##*|}"
[[ $before == "|true" ]] || inconclusive "focus-input.yml did not leave $input_id empty and focused"

"$maestro" "${device[@]}" test -e "APP_ID=$app_id" maestro/press-tab.yml > "$work/press-tab.log" 2>&1 ||
  inconclusive "maestro/press-tab.yml failed; see $work/press-tab.log"
after=$(read_input) || inconclusive "uiautomator found no $input_id after press-tab.yml"
text=${after%|*}
focused=${after##*|}
echo "after pressKey: tab: $input_id text=\"$text\" focused=$focused"

if [[ -n $text ]]; then
  echo "SUMMARY: Maestro $maestro_version, pressKey: tab typed \"$text\" into the TextInput it had focused (focused=$focused after it) on react-native main ${sha:0:10}"
  exit 1
fi
echo "SUMMARY: Maestro $maestro_version, pressKey: tab left the TextInput empty (focused=$focused after it) on react-native main ${sha:0:10}"
exit 0
