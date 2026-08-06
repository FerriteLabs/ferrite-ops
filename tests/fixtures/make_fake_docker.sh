#!/usr/bin/env bash
set -euo pipefail

DESTINATION="${1:?usage: make_fake_docker.sh DESTINATION}"
mkdir -p "$DESTINATION"

cat >"${DESTINATION}/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

LOG="${FAKE_DOCKER_LOG:?FAKE_DOCKER_LOG is required}"
STATE="${FAKE_DOCKER_STATE:?FAKE_DOCKER_STATE is required}"
mkdir -p "$STATE"
printf '%s\n' "$*" >>"$LOG"

if [[ -n "${FAKE_LOCK_OWNER_FILE:-}" &&
      -n "${FAKE_REPLACEMENT_LOCK_PID:-}" &&
      -n "${FAKE_REPLACEMENT_LOCK_START_TIME:-}" &&
      -n "${FAKE_LOCK_REPLACEMENT_MARKER:-}" &&
      ! -e "$FAKE_LOCK_REPLACEMENT_MARKER" ]]; then
  printf '%s\n%s\n' \
    "$FAKE_REPLACEMENT_LOCK_PID" \
    "$FAKE_REPLACEMENT_LOCK_START_TIME" >"$FAKE_LOCK_OWNER_FILE"
  chmod 600 "$FAKE_LOCK_OWNER_FILE"
  : >"$FAKE_LOCK_REPLACEMENT_MARKER"
fi

json_string() {
  printf '"%s"\n' "$1"
}

if [[ "${1:-}" == "--version" ]]; then
  echo "Docker version 27.1.1, build fake"
  exit 0
fi

if [[ "${1:-}" == "container" && "${2:-}" == "ls" ]]; then
  if [[ -n "${FAKE_OWNERSHIP_CHECK_FILE:-}" ]]; then
    ownership_check=0
    if [[ -f "$FAKE_OWNERSHIP_CHECK_FILE" ]]; then
      ownership_check="$(cat "$FAKE_OWNERSHIP_CHECK_FILE")"
    fi
    ownership_check=$((ownership_check + 1))
    printf '%s\n' "$ownership_check" >"$FAKE_OWNERSHIP_CHECK_FILE"
  fi
  if [[ -n "${FAKE_PROJECT_CONTAINER_ID:-}" ]]; then
    echo "$FAKE_PROJECT_CONTAINER_ID"
  fi
  exit 0
fi

if [[ "${1:-}" == "container" && "${2:-}" == "inspect" ]]; then
  ownership_label="${FAKE_CONTAINER_OWNERSHIP_LABEL:-tester.sh}"
  if [[ -n "${FAKE_OWNERSHIP_FAIL_ON_CHECK:-}" &&
        -n "${FAKE_OWNERSHIP_CHECK_FILE:-}" &&
        -f "$FAKE_OWNERSHIP_CHECK_FILE" &&
        "$(cat "$FAKE_OWNERSHIP_CHECK_FILE")" == "$FAKE_OWNERSHIP_FAIL_ON_CHECK" ]]; then
    ownership_label="${FAKE_CHANGED_OWNERSHIP_LABEL:-another-wrapper}"
  fi
  echo "$ownership_label"
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "ls" ]]; then
  if [[ "${FAKE_VOLUME_EXISTS:-}" == "1" ]]; then
    echo "${FERRITE_TEST_PROJECT:-ferrite-tester}_ferrite-tester-data"
  fi
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "inspect" ]]; then
  echo "${FAKE_VOLUME_OWNERSHIP_LABEL:-tester.sh}"
  exit 0
fi

if [[ "${1:-}" == "network" && "${2:-}" == "ls" ]]; then
  if [[ "${FAKE_NETWORK_EXISTS:-}" == "1" ]]; then
    echo "${FERRITE_TEST_PROJECT:-ferrite-tester}_default"
  fi
  exit 0
fi

if [[ "${1:-}" == "network" && "${2:-}" == "inspect" ]]; then
  echo "${FAKE_NETWORK_OWNERSHIP_LABEL:-tester.sh}"
  exit 0
fi

if [[ "${1:-}" == "inspect" ]]; then
  if [[ "$*" == *".State.Health"* ]]; then
    echo "${FAKE_HEALTH_STATUS:-healthy}"
  elif [[ "$*" == *".Config.Image"* ]]; then
    # Defaults to the same digest reference tests use as FERRITE_TEST_IMAGE
    # (see tests/test_tester.sh FAKE_IMAGE) so verify_running_image succeeds
    # unless a test explicitly overrides FAKE_RUNNING_IMAGE to simulate a
    # mismatch, or FAKE_NO_RUNNING_IMAGE to simulate an unreadable/missing
    # value.
    if [[ "${FAKE_NO_RUNNING_IMAGE:-}" == "1" ]]; then
      :
    else
      echo "${FAKE_RUNNING_IMAGE:-ghcr.io/ferritelabs/ferrite@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    fi
  elif [[ "$*" == *".Image"* ]]; then
    echo "sha256:fake-container-image"
  fi
  exit 0
fi

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  echo "ghcr.io/ferritelabs/ferrite@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  exit 0
fi

[[ "${1:-}" == "compose" ]] || exit 0
shift

if [[ "${1:-}" == "version" ]]; then
  echo "Docker Compose version v2.29.2"
  exit 0
fi

while [[ "${1:-}" == "--project-name" ||
         "${1:-}" == "--file" ||
         "${1:-}" == "--profile" ]]; do
  shift 2
done

command="${1:-}"
shift || true

case "$command" in
  down)
    if [[ -n "${FAKE_EXPECT_COMPOSE_IMAGE:-}" &&
          "${FERRITE_TEST_IMAGE:-}" != "$FAKE_EXPECT_COMPOSE_IMAGE" ]]; then
      echo "expected FERRITE_TEST_IMAGE=${FAKE_EXPECT_COMPOSE_IMAGE}, got ${FERRITE_TEST_IMAGE:-<unset>}" >&2
      exit 10
    fi
    exit 0
    ;;
  config | pull | up | restart)
    exit 0
    ;;
  ps)
    if [[ " $* " == *" -q "* ]]; then
      if [[ "${FAKE_NO_CONTAINER:-}" != "1" ]]; then
        echo "fake-ferrite-container"
      fi
    else
      echo "NAME STATUS"
      if [[ "${FAKE_NO_CONTAINER:-}" != "1" ]]; then
        echo "fake-ferrite-container Up (healthy)"
      fi
    fi
    exit 0
    ;;
  logs)
    echo "2026-08-06T14:00:00Z INFO ferrite ready on 0.0.0.0:6379"
    exit 0
    ;;
  exec)
    [[ "${1:-}" == "-T" ]] && shift
    shift # service
    binary="${1:-}"
    shift || true
    [[ "$binary" == "ferrite-cli" ]] || exit 0

    if [[ "${1:-}" == "--version" ]]; then
      echo "ferrite-cli 0.4.0"
      exit 0
    fi

    json=0
    if [[ "${1:-}" == "--format" && "${2:-}" == "json" ]]; then
      json=1
      shift 2
    fi

    cli_command="${1:-}"
    shift || true
    if [[ "${FAKE_FAIL_COMMAND:-}" == "$cli_command" ]]; then
      echo "forced ${cli_command} failure" >&2
      exit 9
    fi

    case "$cli_command" in
      PING)
        ((json)) && json_string "PONG" || echo "PONG"
        ;;
      SET)
        printf '%s' "${2:-}" >"${STATE}/last-value"
        ((json)) && json_string "OK" || echo "OK"
        ;;
      GET)
        value="$(cat "${STATE}/last-value")"
        ((json)) && json_string "$value" || echo "\"${value}\""
        ;;
      HSET)
        printf '%s' "${3:-}" >"${STATE}/hash-value"
        echo "1"
        ;;
      HGET)
        value="$(cat "${STATE}/hash-value")"
        ((json)) && json_string "$value" || echo "\"${value}\""
        ;;
      RPUSH)
        echo "2"
        ;;
      LINDEX)
        if [[ "${2:-}" == "0" ]]; then
          value="alpha"
        else
          value="beta"
        fi
        ((json)) && json_string "$value" || echo "\"${value}\""
        ;;
      ZADD)
        echo "1"
        ;;
      ZSCORE)
        ((json)) && json_string "42" || echo "\"42\""
        ;;
      EXPIRE)
        echo "1"
        ;;
      TTL)
        echo "29"
        ;;
      DEL)
        # Echo the number of keys actually passed, unless a test forces a
        # specific (possibly wrong) count via FAKE_DEL_COUNT, so tests can
        # exercise both correct and mismatched cleanup-verification counts.
        echo "${FAKE_DEL_COUNT:-$#}"
        ;;
      INFO)
        echo "# ${1:-server}"
        echo "ferrite_version:0.4.0"
        ;;
      *)
        echo "unsupported fake ferrite-cli command: ${cli_command}" >&2
        exit 8
        ;;
    esac
    ;;
esac
FAKE_DOCKER

chmod +x "${DESTINATION}/docker"
