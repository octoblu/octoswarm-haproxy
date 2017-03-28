#!/bin/bash

SCRIPT_NAME='run'

matches_debug() {
  if [ -z "$DEBUG" ]; then
    return 1
  fi
  if [[ $SCRIPT_NAME == $DEBUG ]]; then
    return 0
  fi
  return 1
}

debug() {
  local cyan='\033[0;36m'
  local no_color='\033[0;0m'
  local message="$@"
  matches_debug || return 0
  (>&2 echo -e "[${cyan}${SCRIPT_NAME}${no_color}]: $message")
}

script_directory(){
  local source="${BASH_SOURCE[0]}"
  local dir=""

  while [ -h "$source" ]; do # resolve $source until the file is no longer a symlink
    dir="$( cd -P "$( dirname "$source" )" && pwd )"
    source="$(readlink "$source")"
    [[ $source != /* ]] && source="$dir/$source" # if $source was a relative symlink, we need to resolve it relative to the path where the symlink file was located
  done

  dir="$( cd -P "$( dirname "$source" )" && pwd )"

  echo "$dir"
}

assert_required_params() {
  local services="$1"

  if [ -n "$services" ]; then
    return 0
  fi

  usage

  if [ -z "$services" ]; then
    echo "Missing SERVICES environment"
  fi

  exit 1
}

usage(){
  echo "USAGE: ${SCRIPT_NAME}"
  echo ''
  echo 'Description: ...'
  echo ''
  echo 'Arguments:'
  echo '  -h, --help       print this help text'
  echo '  -v, --version    print the version'
  echo ''
  echo 'Environment:'
  echo '  DEBUG            print debug output'
  echo ''
}

version(){
  local directory="$(script_directory)"

  if [ -f "$directory/VERSION" ]; then
    cat "$directory/VERSION"
  else
    echo "unknown-version"
  fi
}

split_comma(){
  local in="$1"
  local data="$(IFS=',' read -ra DATA <<< "$in"; echo "${DATA[@]}")"
  echo $data
}

run_static(){
  busybox httpd -p 8080 -h static
  sleep 5
}

run_haproxy() {
  haproxy -f /usr/local/etc/haproxy/haproxy.cfg &
  child=$!
  echo "Waiting for child process: $child"
  wait "$child"
}

add_backend() {
  local service_id="$1"
  local exit_code
  local service_name="$(docker service inspect "$service_id" | jq -r '.[].Spec.Name')"
  local hostname="$(docker service inspect "$service_id" | jq -r '.[].Spec.Labels."octoswarm.haproxy.host"')"
  if [ "$hostname" == "null" ]; then
    hostname="$service_name"
  fi
  local port="$(docker service inspect "$service_id" | jq -r '.[].Spec.Labels."octoswarm.haproxy.port"')"
  if [ "$port" == "null" ]; then
    port="80"
  fi
  local protocol="$(docker service inspect "$service_id" | jq -r '.[].Spec.Labels."octoswarm.haproxy.protocol"')"
  if [ "$protocol" == "null" ]; then
    protocol="http"
  fi
  local healthcheck_path="$(docker service inspect "$service_id" | jq -r '.[].Spec.Labels."octoswarm.haproxy.healthcheck_path"')"
  if [ "$healthcheck_path" == "null" ]; then
    healthcheck_path="/healthcheck"
  fi
  echo -n "adding $service_name ($service_id) [$protocol://$hostname:$port$healthcheck_path]... "
  echo >> /usr/local/etc/haproxy/haproxy.cfg
  echo "$hostname b-$service_name" >> /usr/local/etc/haproxy/subdomains.map
  env SERVICE="$service_name" HOSTNAME="$hostname" PORT="$port" PROTOCOL="$protocol" HEALTHCHECK_PATH="$healthcheck_path" envsubst < backend.template >> /usr/local/etc/haproxy/haproxy.cfg

  exit_code=$?

  if [ "$exit_code" != "0" ]; then
    echo 'ERROR!'
  else
    echo 'done.'
  fi
}

main() {
  # Define args up here
  while [ "$1" != "" ]; do
    local param="$1"
    local value="$2"
    case "$param" in
      -h | --help)
        usage
        exit 0
        ;;
      -v | --version)
        version
        exit 0
        ;;
      # Arg with value
      # -x | --example)
      #   example="$value"
      #   shift
      #   ;;
      # Arg without value
      # -e | --example-flag)
      #   example_flag='true'
      #   ;;
      *)
        if [ "${param::1}" == '-' ]; then
          echo "ERROR: unknown parameter \"$param\""
          usage
          exit 1
        fi
        # Set main arguments
        # if [ -z "$main_arg" ]; then
        #   main_arg="$param"
        # elif [ -z "$main_arg_2"]; then
        #   main_arg_2="$param"
        # fi
        ;;
    esac
    shift
  done

  local services=( $(docker service ls -q --filter label=octoswarm.haproxy.enabled=true) )

  assert_required_params "$services"

  mkdir -p /usr/local/etc/haproxy \
    && cp haproxy.cfg.template /usr/local/etc/haproxy/haproxy.cfg

  for service_id in "${services[@]}"; do
    add_backend "$service_id"
  done

  run_static
  run_haproxy
}

main "$@"
