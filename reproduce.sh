#!/usr/bin/env bash
# Starts the four variants from compose.yaml, sends each the same requests, and prints what the
# kernel.terminate listener could still read. Requires Docker with Compose v2 and curl.
# KEEP=1 leaves the containers running afterwards.
set -euo pipefail
cd "$(dirname "$0")"

VARIANTS=(classic worker worker-67679 worker-followup)
BODY_BYTES=4096
UPLOAD_BYTES=8192
TERMINATE_DELAY_MS=2000

port() {
    case $1 in
        classic) echo 8081 ;;
        worker) echo 8082 ;;
        worker-67679) echo 8083 ;;
        worker-followup) echo 8084 ;;
    esac
}

upload_file=$(mktemp)
cleanup() {
    rm -f "$upload_file"
    if [ "${KEEP:-0}" != 1 ]; then
        docker compose down --remove-orphans >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

head -c "$UPLOAD_BYTES" /dev/urandom > "$upload_file"
body="{\"payload\":\"$(head -c $((BODY_BYTES - 14)) /dev/zero | tr '\0' x)\"}"

build_log=$(mktemp)
docker compose up --detach --build >"$build_log" 2>&1 || { cat "$build_log"; exit 1; }
rm -f "$build_log"

for variant in "${VARIANTS[@]}"; do
    for _ in $(seq 1 120); do
        code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(port "$variant")/terminations/warmup" || true)
        [ "$code" = 404 ] && break
        sleep 0.5
    done
    [ "$code" = 404 ] || { echo "$variant did not start"; docker compose logs "$variant"; exit 1; }
done

# Waits until kernel.terminate has recorded the request, or prints nothing when it never runs.
termination() {
    local url
    url="http://127.0.0.1:$(port "$1")/terminations/$2"
    for _ in $(seq 1 40); do
        if curl -fsS "$url" 2>/dev/null; then
            return
        fi
        sleep 0.25
    done
}

field() {
    sed -nE "s/.*\"$1\":\"?([A-Za-z0-9]+)\"?.*/\1/p"
}

row() {
    printf '%-44s %-16s %-16s %-16s %s\n' "$@"
}

declare body_seen=() put_body_seen=() upload_bytes=() upload_move=() response_time=() delay_terminated=()
declare failure_time=() stream_failure=() runner=()

for variant in "${VARIANTS[@]}"; do
    base="http://127.0.0.1:$(port "$variant")"
    run="$variant-$$"

    if [ "$variant" = classic ]; then
        runner+=(HttpKernelRunner)
    else
        runner+=("$(docker compose exec -T "$variant" sha1sum vendor/symfony/runtime/Runner/FrankenPhpWorkerRunner.php | cut -c1-8)")
    fi

    curl -fsS -o /dev/null -X POST -H "X-Probe-Id: $run-body" -H 'Content-Type: application/json' --data-binary "$body" "$base/submit"
    seen=$(termination "$variant" "$run-body" | field body_bytes)
    body_seen+=("${seen:-not run}")

    curl -fsS -o /dev/null -X PUT -H "X-Probe-Id: $run-put" -H 'Content-Type: application/json' --data-binary "$body" "$base/submit"
    seen=$(termination "$variant" "$run-put" | field body_bytes)
    put_body_seen+=("${seen:-not run}")

    curl -fsS -o /dev/null -H "X-Probe-Id: $run-upload" -F "upload=@$upload_file;type=application/octet-stream" "$base/submit"
    record=$(termination "$variant" "$run-upload")
    seen=$(field upload_bytes <<< "$record")
    upload_bytes+=("${seen:-not run}")
    seen=$(field upload_move <<< "$record")
    upload_move+=("${seen:-not run}")

    response_time+=("$(curl -fsS -o /dev/null -w '%{time_total}' -X POST -H "X-Probe-Id: $run-delay" -H "X-Terminate-Delay-Ms: $TERMINATE_DELAY_MS" "$base/submit")")
    [ -n "$(termination "$variant" "$run-delay")" ] && delay_terminated+=(yes) || delay_terminated+=(no)

    failure_time+=("$(curl -sS -o /dev/null -w '%{time_total}' -H "X-Probe-Id: $run-stream" -H "X-Terminate-Delay-Ms: $TERMINATE_DELAY_MS" "$base/stream-failure" 2>/dev/null || true)")
    [ -n "$(termination "$variant" "$run-stream")" ] && stream_failure+=(yes) || stream_failure+=(no)
done

echo
docker compose exec -T worker frankenphp version
echo "symfony/runtime $(docker compose exec -T worker php -r 'require "vendor/autoload.php"; echo Composer\InstalledVersions::getPrettyVersion("symfony/runtime");')"
echo
row "What kernel.terminate saw" "${VARIANTS[@]}"
row "runner (FrankenPhpWorkerRunner.php sha1)" "${runner[@]}"
row "POST body ($BODY_BYTES bytes sent)" "${body_seen[@]}"
row "PUT body ($BODY_BYTES bytes sent)" "${put_body_seen[@]}"
row "uploaded file ($UPLOAD_BYTES bytes sent)" "${upload_bytes[@]}"
row "UploadedFile::move()" "${upload_move[@]}"
row "response time, terminate sleeps ${TERMINATE_DELAY_MS}ms (s)" "${response_time[@]}"
row "same, when the StreamedResponse throws (s)" "${failure_time[@]}"
row "terminate ran after StreamedResponse threw" "${stream_failure[@]}"
echo

waited_for_listener() {
    awk -v t="$1" -v ms="$TERMINATE_DELAY_MS" 'BEGIN { exit !(t * 1000 >= ms) }'
}

shows_non_worker_behaviour() {
    local expected="$BODY_BYTES ${put_body_seen[0]} $UPLOAD_BYTES moved yes yes"
    [ "${body_seen[$1]} ${put_body_seen[$1]} ${upload_bytes[$1]} ${upload_move[$1]} ${delay_terminated[$1]} ${stream_failure[$1]}" = "$expected" ] \
        && ! waited_for_listener "${response_time[$1]}" && waited_for_listener "${failure_time[$1]}"
}

if [ "${body_seen[1]} ${upload_bytes[1]} ${upload_move[1]}" = "0 unreadable FileException" ]; then
    echo "BUG REPRODUCED: with the stock worker runner, kernel.terminate cannot read the POST body or the uploaded file."
else
    echo "Bug not reproduced by the stock worker runner."
    exit 1
fi

if [ "${runner[2]}" != "${runner[1]}" ] \
    && [ "${body_seen[2]} ${upload_bytes[2]} ${upload_move[2]} ${stream_failure[2]}" = "$BODY_BYTES $UPLOAD_BYTES moved no" ]; then
    echo "REGRESSION REPRODUCED: with the runner of #67679, kernel.terminate can read them, but does not run when sending the response throws."
else
    echo "Regression not reproduced by the runner of #67679."
    exit 1
fi

if [ "${runner[3]}" != "${runner[1]}" ] && [ "${runner[3]}" != "${runner[2]}" ] \
    && shows_non_worker_behaviour 0 && shows_non_worker_behaviour 3; then
    echo "FIX VERIFIED: with the follow-up runner, kernel.terminate sees what it sees outside worker mode, and the client waits for it only when sending the response fails, as outside worker mode with debug off."
else
    echo "Fix not verified: the follow-up runner is the stock or the #67679 one, or does not match the non-worker behaviour."
    exit 1
fi
