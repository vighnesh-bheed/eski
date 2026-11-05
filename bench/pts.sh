#!/usr/bin/env bash
set -uo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MEMTIER_PROFILE="pts/memtier-benchmark-1.5.0"
MEMTIER_PROFILE_UPDATED="2023-07-22"
MEMTIER_PROFILE_SOURCE="https://openbenchmarking.org/test/pts/memtier-benchmark-1.5.0"
MEMTIER_PROFILE_SERVER="Redis 7.0.12 from source, make MALLOC=libc, redis.conf: io-threads NUM_CPU_PHYSICAL_CORES, io-threads-do-reads yes, tcp-keepalive 0"
MEMTIER_PROFILE_CLIENT="memtier_benchmark 2.0.0 from source"
MEMTIER_PROFILE_COMMAND='memtier_benchmark -s 127.0.0.1 --hide-histogram -t $NUM_CPU_PHYSICAL_CORES --pipeline=120 --test-time=60 -P redis -c CLIENTS --ratio=RATIO'
MEMTIER_DEFAULT_ARGS=(--pipeline=120 --test-time=60)
MEMTIER_QUICK_ARGS=(--pipeline=120 --test-time=5)
MEMTIER_PROTOCOL=redis
MEMTIER_CLIENTS=(50 100 500)
MEMTIER_RATIOS=(1:10 1:5 1:1 5:1 10:1)
MEMTIER_TIMES_TO_RUN=3

REDIS_PROFILE="pts/redis-1.5.1"
REDIS_PROFILE_UPDATED="2026-04-19"
REDIS_PROFILE_SOURCE="https://openbenchmarking.org/test/pts/redis-1.5.1"
REDIS_PROFILE_SERVER="Redis 8.6.0 from source, make MALLOC=libc, redis.conf: io-threads 8, io-threads-do-reads yes, tcp-keepalive 0"
REDIS_PROFILE_CLIENT="redis-benchmark of Redis 8.6.0"
REDIS_PROFILE_COMMAND='redis-benchmark --threads min($NUM_CPU_CORES,128) -n 50000000 -P 16 -q -d 256 --csv -t TEST -c CONNECTIONS'
REDIS_DEFAULT_ARGS=(-n 50000000 -P 16 -q -d 256 --csv)
REDIS_QUICK_ARGS=(-n 1000000 -P 16 -q -d 256 --csv)
REDIS_TESTS=(SET:set GET:get LPUSH:lpush LPOP:lpop SADD:sadd)
REDIS_CONNECTIONS=(50 500 1000)
REDIS_TIMES_TO_RUN=3
REDIS_THREAD_LIMIT=128
REDIS_IO_THREADS=8

usage() {
  cat <<EOF
usage: bench/pts.sh [--quick] [--profiles memtier,redis] [--select GLOB,...] [--server-config harness|profile]
                    [--targets redis,valkey,dragonfly,eski,eski-docker] [--label name]

Runs the fixed parameter invocations of the OpenBenchmarking.org test profiles
$MEMTIER_PROFILE (updated $MEMTIER_PROFILE_UPDATED) and $REDIS_PROFILE (updated $REDIS_PROFILE_UPDATED)
against the harness targets through bench/run.sh, with the same server and client CPU pinning,
and writes one record per profile option under the profile's own result name.

  $MEMTIER_PROFILE: $MEMTIER_PROFILE_COMMAND
    clients: ${MEMTIER_CLIENTS[*]}; ratios: ${MEMTIER_RATIOS[*]}; $MEMTIER_TIMES_TO_RUN runs averaged
  $REDIS_PROFILE: $REDIS_PROFILE_COMMAND
    tests: ${REDIS_TESTS[*]%%:*}; connections: ${REDIS_CONNECTIONS[*]}; $REDIS_TIMES_TO_RUN runs averaged

  --quick          one run per option, memtier --test-time=5, redis-benchmark -n 1000000
  --profiles       which profiles to run (default: memtier,redis)
  --select         only options whose result key matches one of these shell globs,
                   for example 'pts-redis-*-set-c50' (keys are printed in the results)
  --server-config  harness (default): servers start exactly as in bench/run.sh;
                   profile: redis and valkey also get the profile's redis.conf settings
  --targets, --label are passed to bench/run.sh (the label defaults to pts or pts-quick)

Every run starts from an empty dataset (FLUSHALL), as the profile starts a fresh server per run.
Options whose command eski does not implement are recorded as skipped on eski only.
EOF
}

die() { printf 'pts.sh: error: %s\n' "$*" >&2; exit 1; }

QUICK=0
PROFILES="memtier,redis"
SELECT=""
SERVER_CONFIG=harness
LABEL=""
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1; PASS+=(--quick) ;;
    --profiles) [ $# -ge 2 ] || die "--profiles needs a value"; PROFILES=$2; shift ;;
    --profiles=*) PROFILES=${1#--profiles=} ;;
    --select) [ $# -ge 2 ] || die "--select needs a value"; SELECT=$2; shift ;;
    --select=*) SELECT=${1#--select=} ;;
    --server-config) [ $# -ge 2 ] || die "--server-config needs a value"; SERVER_CONFIG=$2; shift ;;
    --server-config=*) SERVER_CONFIG=${1#--server-config=} ;;
    --label) [ $# -ge 2 ] || die "--label needs a value"; LABEL=$2; shift ;;
    --label=*) LABEL=${1#--label=} ;;
    --targets) [ $# -ge 2 ] || die "--targets needs a value"; PASS+=(--targets "$2"); shift ;;
    --targets=*) PASS+=("$1") ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

case "$SERVER_CONFIG" in
  harness|profile) ;;
  *) die "--server-config must be harness or profile" ;;
esac
for p in ${PROFILES//,/ }; do
  case "$p" in
    memtier|redis) ;;
    *) die "unknown profile '$p' (valid: memtier, redis)" ;;
  esac
done
command -v jq >/dev/null 2>&1 || die "required command not found: jq"

PHYSICAL_CORES=$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l)
[ "$PHYSICAL_CORES" -gt 0 ] 2>/dev/null || PHYSICAL_CORES=$(nproc --all)
LOGICAL_CORES=$(nproc --all)
MEMTIER_THREADS=${BENCH_PTS_MEMTIER_THREADS:-$PHYSICAL_CORES}
RB_THREADS=${BENCH_PTS_RB_THREADS:-$((LOGICAL_CORES > REDIS_THREAD_LIMIT ? REDIS_THREAD_LIMIT : LOGICAL_CORES))}

if [ "$QUICK" = 1 ]; then
  MEMTIER_ARGS=("${MEMTIER_QUICK_ARGS[@]}")
  REDIS_ARGS=("${REDIS_QUICK_ARGS[@]}")
  MEMTIER_RUNS=1
  REDIS_RUNS=1
  ADJUSTMENTS="one run per option, memtier --test-time=5 instead of 60, redis-benchmark -n 1000000 instead of 50000000"
else
  MEMTIER_ARGS=("${MEMTIER_DEFAULT_ARGS[@]}")
  REDIS_ARGS=("${REDIS_DEFAULT_ARGS[@]}")
  MEMTIER_RUNS=$MEMTIER_TIMES_TO_RUN
  REDIS_RUNS=$REDIS_TIMES_TO_RUN
  ADJUSTMENTS=""
fi
[ -n "$LABEL" ] || LABEL=$([ "$QUICK" = 1 ] && echo pts-quick || echo pts)

selected() {
  local key=$1 glob
  [ -n "$SELECT" ] || return 0
  for glob in ${SELECT//,/ }; do
    [[ $key == $glob ]] && return 0
  done
  return 1
}

server_args_json() {
  local io=$1
  if [ "$SERVER_CONFIG" = profile ]; then
    jq -n --arg io "$io" '{redis: ["--io-threads", $io, "--io-threads-do-reads", "yes", "--tcp-keepalive", "0"],
      valkey: ["--io-threads", $io, "--io-threads-do-reads", "yes", "--tcp-keepalive", "0"]}'
  else
    echo '{}'
  fi
}

item_json() {
  local key=$1 display=$2 tool=$3 runs=$4 timeout=$5 required=$6 server_args=$7 info=$8 argv; shift 8
  argv=$(printf '%s\n' "$@" | jq -R . | jq -s .) || return 1
  jq -n --arg key "$key" --arg display "$display" --arg tool "$tool" --argjson runs "$runs" \
    --argjson timeout "$timeout" --argjson required "$required" --argjson server_args "$server_args" \
    --argjson info "$info" --argjson argv "$argv" --argjson fresh "$([ "$SERVER_CONFIG" = profile ] && echo true || echo false)" \
    '{suite: "pts", name: $key, key: $key, display: $display, fresh_server: $fresh, flush_each_run: true,
      runs: $runs, config: [], preload: null, init_commands: [], init_lua: [], check: null,
      clients: [{tool: $tool, image: "", argv: $argv, cpus: "", timeout: $timeout}],
      required_commands: $required, applicability: "per_target", server_args: $server_args, info: $info}'
}

ITEMS=()

if [[ ",$PROFILES," == *,memtier,* ]]; then
  margs=$(server_args_json "$PHYSICAL_CORES")
  for c in "${MEMTIER_CLIENTS[@]}"; do
    for ratio in "${MEMTIER_RATIOS[@]}"; do
      key="pts-memtier-benchmark-1.5.0-$MEMTIER_PROTOCOL-c$c-${ratio/:/to}"
      selected "$key" || continue
      display="$MEMTIER_PROFILE: Protocol: Redis - Clients: $c - Set To Get Ratio: $ratio"
      required='["set","get"]'
      info=$(jq -n --arg profile "$MEMTIER_PROFILE" --arg c "$c" --arg ratio "$ratio" --argjson threads "$MEMTIER_THREADS" \
        '{profile: $profile, options: {protocol: "Redis", clients: ($c | tonumber), set_to_get_ratio: $ratio}, threads: $threads}')
      item=$(item_json "$key" "$display" memtier_benchmark "$MEMTIER_RUNS" 300 "$required" "$margs" "$info" \
        --hide-histogram -t "$MEMTIER_THREADS" "${MEMTIER_ARGS[@]}" -P "$MEMTIER_PROTOCOL" -c "$c" "--ratio=$ratio") \
        || die "cannot describe $key"
      ITEMS+=("$item")
    done
  done
fi

if [[ ",$PROFILES," == *,redis,* ]]; then
  rargs=$(server_args_json "$REDIS_IO_THREADS")
  for t in "${REDIS_TESTS[@]}"; do
    name=${t%%:*}
    test=${t#*:}
    for c in "${REDIS_CONNECTIONS[@]}"; do
      key="pts-redis-1.5.1-$test-c$c"
      selected "$key" || continue
      display="$REDIS_PROFILE: Test: $name - Parallel Connections: $c"
      required=$(jq -n --arg t "$test" '[$t]')
      info=$(jq -n --arg profile "$REDIS_PROFILE" --arg name "$name" --arg c "$c" --argjson threads "$RB_THREADS" \
        '{profile: $profile, options: {test: $name, parallel_connections: ($c | tonumber)}, threads: $threads}')
      item=$(item_json "$key" "$display" redis-benchmark "$REDIS_RUNS" 1800 "$required" "$rargs" "$info" \
        --threads "$RB_THREADS" "${REDIS_ARGS[@]}" -t "$test" -c "$c") || die "cannot describe $key"
      ITEMS+=("$item")
    done
  done
fi

[ "${#ITEMS[@]}" -gt 0 ] || die "no profile option matches --profiles $PROFILES --select '$SELECT'"

PLAN_FILE=$(mktemp "${TMPDIR:-/tmp}/pts-plan.XXXXXX.json") || die "cannot create a plan file"
trap 'rm -f -- "$PLAN_FILE"' EXIT

profiles_json=$(jq -n \
  --arg mp "$MEMTIER_PROFILE" --arg mu "$MEMTIER_PROFILE_UPDATED" --arg ms "$MEMTIER_PROFILE_SOURCE" \
  --arg msv "$MEMTIER_PROFILE_SERVER" --arg mc "$MEMTIER_PROFILE_CLIENT" --arg mcmd "$MEMTIER_PROFILE_COMMAND" \
  --argjson mt "$MEMTIER_THREADS" --argjson mr "$MEMTIER_TIMES_TO_RUN" \
  --arg rp "$REDIS_PROFILE" --arg ru "$REDIS_PROFILE_UPDATED" --arg rs "$REDIS_PROFILE_SOURCE" \
  --arg rsv "$REDIS_PROFILE_SERVER" --arg rc "$REDIS_PROFILE_CLIENT" --arg rcmd "$REDIS_PROFILE_COMMAND" \
  --argjson rt "$RB_THREADS" --argjson rr "$REDIS_TIMES_TO_RUN" --arg which ",$PROFILES," \
  '[(if ($which | contains(",memtier,")) then {profile: $mp, updated: $mu, source: $ms, server: $msv, client: $mc, command: $mcmd, threads: $mt, times_to_run: $mr} else empty end),
    (if ($which | contains(",redis,")) then {profile: $rp, updated: $ru, source: $rs, server: $rsv, client: $rc, command: $rcmd, threads: $rt, times_to_run: $rr} else empty end)]')

printf '%s\n' "${ITEMS[@]}" | jq -s \
  --argjson profiles "$profiles_json" --argjson quick "$([ "$QUICK" = 1 ] && echo true || echo false)" \
  --arg adjustments "$ADJUSTMENTS" --arg server_config "$SERVER_CONFIG" \
  --argjson physical "$PHYSICAL_CORES" --argjson logical "$LOGICAL_CORES" \
  '{items: ., suites: {pts: {profiles: $profiles, quick: $quick, quick_adjustments: (if $adjustments != "" then $adjustments else null end),
     server_config: $server_config, machine: {physical_cores: $physical, logical_cores: $logical},
     note: ("server config " + $server_config + (if $quick then ", quick" else "" end))}}}' >"$PLAN_FILE" \
  || die "cannot write the plan"

"$BENCH_DIR/run.sh" --scenarios none --plan "$PLAN_FILE" --label "$LABEL" "${PASS[@]}"
