#!/bin/bash
#
# Tests for the Conductor scripts. Each test runs the real script inside a
# throwaway app at <sandbox>/workspaces/<repo>/<workspace>, with herd, npm and
# npx replaced by fakes.
#
# Usage: tests/conductor.test.sh [test_name_filter]

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
failures=0
passes=0

# --- harness -----------------------------------------------------------------

# Fakes log their arguments to ~/fakebin/<tool>.log; files in the sandbox steer them.
FAKE_HERD='#!/bin/bash
echo "$*" >> "$HOME/fakebin/herd.log"
case "$*" in
	links) cat "$HOME/herd-links" 2>/dev/null ;;
	"php artisan list --raw")
		echo "schedule:run                Run the scheduled commands"
		[ -e "$HOME/old-laravel" ] || echo "schedule:work               Start the schedule worker" ;;
	"php artisan about --only=drivers --json")
		[ -e "$HOME/php-warnings" ] && printf "\nDeprecated: Constant PDO::MYSQL_ATTR_SSL_CA is deprecated\n"
		echo "{\"drivers\":{\"queue\":\"$(cat "$HOME/queue-driver" 2>/dev/null || echo sync)\"}}" ;;
	"php artisan schedule:list")
		if [ -e "$HOME/has-schedule" ]; then
			echo "  */5 * * * *  php artisan inspire  Next Due: 4 minutes from now"
		else
			echo "   INFO  No scheduled tasks have been defined."
		fi ;;
esac'
FAKE_LOGGER='#!/bin/bash
echo "$*" >> "$HOME/fakebin/$(basename "$0").log"'

add_fake() {
	printf '%s\n' "$2" > "$SANDBOX/fakebin/$1"
	chmod +x "$SANDBOX/fakebin/$1"
}

# new_app <repo> <workspace> — fresh sandbox with an app that has a .env and
# installed vendor/. Sets $SANDBOX and $APP.
new_app() {
	SANDBOX="$(mktemp -d)"
	SANDBOX="$(cd "$SANDBOX" && pwd -P)"
	APP="$SANDBOX/workspaces/$1/$2"
	mkdir -p "$APP" "$SANDBOX/fakebin"
	add_fake herd "$FAKE_HERD"
	add_fake npm "$FAKE_LOGGER"
	add_fake npx "$FAKE_LOGGER"
	ln -s "$(command -v jq)" "$SANDBOX/fakebin/jq"
	printf '%s\n' 'APP_NAME=App' 'APP_KEY=base64:existing' 'APP_URL=http://localhost' > "$APP/.env"
	mkdir -p "$APP/vendor"
	touch "$APP/vendor/autoload.php"
}

# write <path relative to the app> <contents>
write() {
	mkdir -p "$(dirname "$APP/$1")"
	printf '%s\n' "$2" > "$APP/$1"
}

# run_script <setup|run|archive>. Sets $OUT (stdout+stderr) and $STATUS.
run_script() {
	OUT="$(cd "$APP" && HOME="$SANDBOX" PATH="$SANDBOX/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
		bash "$REPO/conductor/$1.sh" 2>&1)"
	STATUS=$?
}

fail() {
	echo "    $*"
	test_failed=1
}

assert_status() {
	[ "$STATUS" -eq "$1" ] || fail "expected exit $1, got $STATUS. Output:"$'\n'"$OUT"
}

assert_output_contains() {
	case "$OUT" in
		*"$1"*) ;;
		*) fail "expected output to contain '$1'. Output:"$'\n'"$OUT" ;;
	esac
}

assert_logged() {
	grep -qxF -- "$2" "$SANDBOX/fakebin/$1.log" 2>/dev/null ||
		fail "expected $1 to be run with '$2'. Log:"$'\n'"$(cat "$SANDBOX/fakebin/$1.log" 2>/dev/null)"
}

assert_not_logged() {
	grep -qF -- "$2" "$SANDBOX/fakebin/$1.log" 2>/dev/null &&
		fail "expected $1 not to be run with '$2'"
}

assert_env_line() {
	grep -qxF -- "$1" "$APP/.env" || fail "expected .env to contain '$1'. .env:"$'\n'"$(cat "$APP/.env")"
}

# --- setup -------------------------------------------------------------------

test_setup_links_and_isolates_with_herd_yml_php_version() {
	new_app bisnow-api moscow
	write herd.yml "name: bisnow-api-v2"$'\n'"php: '8.3'"
	write composer.json '{"require":{"php":"^8.5"}}'
	run_script setup
	assert_status 0
	assert_logged herd "link bisnow-api-moscow"
	assert_logged herd "isolate 8.3 --site=bisnow-api-moscow"
	assert_logged herd "secure bisnow-api-moscow"
}

test_setup_falls_back_to_composer_php_constraint() {
	new_app iterable-webhooks moscow
	write composer.json '{"require":{"php":"^8.4"}}'
	run_script setup
	assert_status 0
	assert_logged herd "isolate 8.4 --site=iterable-webhooks-moscow"
}

test_setup_skips_isolate_without_a_php_version() {
	new_app outbound lima
	write composer.json '{"require":{}}'
	run_script setup
	assert_status 0
	assert_not_logged herd "isolate"
	assert_logged herd "link outbound-lima"
}

test_setup_points_app_url_at_the_herd_site() {
	new_app outbound lima
	run_script setup
	assert_status 0
	assert_env_line "APP_URL=https://outbound-lima.test"
}

test_setup_appends_missing_app_url() {
	new_app outbound lima
	printf 'APP_KEY=base64:existing' > "$APP/.env"
	run_script setup
	assert_status 0
	assert_env_line "APP_KEY=base64:existing"
	assert_env_line "APP_URL=https://outbound-lima.test"
}

test_setup_keeps_existing_app_key() {
	new_app outbound lima
	run_script setup
	assert_status 0
	assert_not_logged herd "key:generate"
}

test_setup_generates_empty_app_key() {
	new_app outbound lima
	printf '%s\n' 'APP_KEY=""' > "$APP/.env"
	run_script setup
	assert_status 0
	assert_logged herd "php artisan key:generate"
}

test_setup_copies_env_example_when_env_is_missing() {
	new_app outbound lima
	mv "$APP/.env" "$APP/.env.example"
	run_script setup
	assert_status 0
	assert_env_line "APP_URL=https://outbound-lima.test"
}

test_setup_fails_without_any_env_file() {
	new_app outbound lima
	rm "$APP/.env"
	run_script setup
	assert_status 1
	assert_output_contains "No .env or .env.example"
	assert_not_logged herd "link"
}

test_setup_skips_npm_without_package_json() {
	new_app outbound lima
	run_script setup
	assert_status 0
	[ ! -e "$SANDBOX/fakebin/npm.log" ] || fail "expected npm not to run. Log:"$'\n'"$(cat "$SANDBOX/fakebin/npm.log")"
}

test_setup_installs_and_builds_frontend() {
	new_app bisnow vancouver
	write package.json '{"scripts":{"dev":"vite","build":"vite build"}}'
	run_script setup
	assert_status 0
	assert_logged npm "install"
	assert_logged npm "run build"
}

test_setup_builds_laravel_mix_assets_once() {
	new_app webapp abuja
	write package.json '{"scripts":{"dev":"mix","watch":"mix watch"}}'
	run_script setup
	assert_status 0
	assert_logged npm "install"
	assert_logged npm "run dev"
}

test_setup_skips_build_without_a_build_script() {
	new_app bisnow vancouver
	write package.json '{"scripts":{"dev":"vite"}}'
	run_script setup
	assert_status 0
	assert_logged npm "install"
	assert_not_logged npm "run build"
	assert_not_logged npm "run dev"
}

# --- run ---------------------------------------------------------------------

test_run_starts_everything_a_full_app_uses() {
	new_app bisnow vancouver
	echo redis > "$SANDBOX/queue-driver"
	touch "$SANDBOX/has-schedule"
	write vendor/laravel/pail/composer.json '{}'
	write package.json '{"scripts":{"dev":"vite"}}'
	run_script run
	assert_status 0
	assert_logged npx "concurrently -k -n queue,schedule,logs,vite -c #93c5fd,#c4b5fd,#fb7185,#fdba74 herd php artisan queue:listen --tries=1 --timeout=0 herd php artisan schedule:work herd php artisan pail --timeout=0 npm run dev"
}

test_run_skips_queue_on_sync_driver_and_missing_pail_and_vite() {
	new_app outbound lima
	touch "$SANDBOX/has-schedule"
	run_script run
	assert_status 0
	assert_logged npx "concurrently -k -n schedule -c #c4b5fd herd php artisan schedule:work"
}

test_run_skips_vite_when_package_json_has_no_dev_script() {
	new_app bisnow-api moscow
	echo database > "$SANDBOX/queue-driver"
	write package.json '{"scripts":{"build":"vite build"}}'
	run_script run
	assert_status 0
	assert_logged npx "concurrently -k -n queue -c #93c5fd herd php artisan queue:listen --tries=1 --timeout=0"
}

test_run_skips_schedule_on_laravel_without_schedule_work() {
	new_app webapp abuja
	touch "$SANDBOX/old-laravel" "$SANDBOX/has-schedule"
	echo redis > "$SANDBOX/queue-driver"
	run_script run
	assert_status 0
	assert_logged npx "concurrently -k -n queue -c #93c5fd herd php artisan queue:listen --tries=1 --timeout=0"
	assert_not_logged herd "schedule:list"
}

test_run_prefers_laravel_mix_watch_over_dev() {
	new_app webapp abuja
	write package.json '{"scripts":{"dev":"mix","watch":"mix watch"}}'
	run_script run
	assert_status 0
	assert_logged npx "concurrently -k -n watch -c #fdba74 npm run watch"
}

test_run_with_nothing_to_start_says_so() {
	new_app iterable-webhooks moscow
	run_script run
	assert_status 0
	assert_output_contains "Nothing to run — site is served by Herd at http://localhost"
	[ ! -e "$SANDBOX/fakebin/npx.log" ] || fail "expected npx not to run"
}

test_run_reads_queue_driver_past_php_warnings() {
	new_app departureboard missoula
	echo redis > "$SANDBOX/queue-driver"
	touch "$SANDBOX/php-warnings"
	run_script run
	assert_status 0
	assert_logged npx "concurrently -k -n queue -c #93c5fd herd php artisan queue:listen --tries=1 --timeout=0"
}

test_run_without_vendor_asks_for_setup() {
	new_app departureboard missoula
	rm -rf "$APP/vendor"
	run_script run
	assert_status 1
	assert_output_contains "run the setup script first"
	[ ! -e "$SANDBOX/fakebin/npx.log" ] || fail "expected npx not to run"
}

# --- archive -----------------------------------------------------------------

herd_links_table() {
	local site
	for site in "$@"; do
		printf '| %-20s |  X  | https://%s.test |\n' "$site" "$site"
	done > "$SANDBOX/herd-links"
}

test_archive_unlinks_the_workspace_site() {
	new_app bisnow zagreb
	herd_links_table bisnow-kabul bisnow-zagreb
	run_script archive
	assert_status 0
	assert_logged herd "unsecure bisnow-zagreb"
	assert_logged herd "unlink bisnow-zagreb"
}

test_archive_ignores_sites_that_only_share_a_prefix() {
	new_app bisnow zagreb
	herd_links_table bisnow-zagreb-v1
	run_script archive
	assert_status 0
	assert_not_logged herd "unlink"
}

# --- runner ------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${1:-}"); do
	test_failed=0
	"$t"
	[ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
	SANDBOX=""
	if [ "$test_failed" -eq 0 ]; then
		passes=$((passes + 1))
		echo "ok   $t"
	else
		failures=$((failures + 1))
		echo "FAIL $t"
	fi
done

echo
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
