#!/bin/sh
set -e

kill_child_jobs() {
    # From https://stackoverflow.com/a/23336595
    # Kills all child processes, not just jobs.
    pkill -P $$
}
cleanup() {
    kill_child_jobs
}

# From https://unix.stackexchange.com/a/240736
for sig in INT QUIT HUP TERM; do
  trap "
    cleanup
    trap - $sig EXIT
    kill -s $sig "'"$$"' "$sig"
done
trap cleanup EXIT


verbose=y
cpulimit_args="--lazy"
limit=""
pids=""
exes=""
paths=""
max_processes=100
max_depth=3
watch_interval=0
subprocess_watch_interval=0.5
while [ $# -gt 0 ]
do
    opt="$1"
    case "$opt" in
        *=*)
            arg="${1#*=}"
            opt="${1%%=*}"
            argshift=1
            ;;
        *)
            if [ "$#" -ge 2 ]
            then
                arg="$2"
            else
                arg=""
            fi
            argshift=2
            ;;
    esac

    case "$opt" in
        -h|--help)
            cat <<EOF
Usage: $0 [TARGET] [OPTIONS...] [-- PROGRAM]
   TARGET may be one or more of these (either TARGET or PROGRAM is required):
      -p, --pid=N        pid of a process
      -e, --exe=FILE     name of a executable program file
      -P, --path=PATH    absolute path name of a
                         executable program file
   OPTIONS for $0
          --max-depth=N  If 0, only target explicitly referenced processes.
                         Otherwise, target subprocesses up to N layers deep.
          --max-processes=N
                         Maximum number of processes to limit. After this
                         limit is reached, new processes will be limited
                         as old ones die.
          --watch-interval=INTERVAL
                         If 0 (default), targets will be selected at
                         setup. Otherwise, every INTERVAL (argument to
                         sleep(1)), search for more possible targets.
          --subprocess-watch-interval=INTERVAL
                         During setup, delay INTERVAL (argument to sleep(1))
                         between searches for more subprocesses to avoid
                         spending 100% CPU searching for targets.
          --             This is the final $0 option. All following
                         options are for another program we will launch.
      -h, --help         display this help and exit
   OPTIONS forwarded to CPUlimit
      -c, --cpu=N        override the detection of CPUs on the machine.
      -l, --limit=N      percentage of cpu allowed from 1 up.
                         Usually 1 - 800, but can be higher
                         on multi-core CPUs (mandatory)
      -q, --quiet        run in quiet mode (only print errors).
                         (Also suppresses messages from $0.)
      -k, --kill         kill processes going over their limit
                         instead of just throttling them.
      -r, --restore      Restore processes after they have
                         been killed. Works with the -k flag.
      -s, --signal=SIG   Send this signal to the watched process when cpulimit exits.
                         Signal should be specificed as a number or
                         SIGTERM, SIGCONT, SIGSTOP, etc. SIGCONT is the default.
      -v, --verbose      show control statistics
EOF
            exit 1
            ;;
        --max-depth)
            case $arg in
                ''|*[!0-9]*)
                    echo "Invalid max depth: $arg, must be a non-negative integer."
                    exit 5
                    ;;
                *)
                    max_depth=$arg
                    shift $argshift
                    ;;
            esac
            ;;
        --max-processes)
            case $arg in
                ''|*[!0-9]*)
                    echo "Invalid max processes: $arg, must be a positive integer."
                    exit 5
                    ;;
                *)
                    max_processes=$arg
                    shift $argshift
                    ;;
            esac
            ;;
        --watch-interval)
            watch_interval="$arg"
            shift $argshift
            ;;
        --subprocess-watch-interval)
            subprocess_watch_interval="$arg"
            shift $argshift
            ;;
        -p|--pid)
            if [ -z "$pids" ]
            then
                pids="$arg"
            else
                pids="$pids
$arg"
            fi
            shift $argshift
            ;;
        -e|--exe)
            if [ -z "$exes" ]
            then
                exes="$arg"
            else
                exes="$exes
$arg"
            fi
            shift $argshift
            ;;
        -P|--path)
            if [ -z "$paths" ]
            then
                paths="$arg"
            else
                paths="$paths
$arg"
            fi
            shift $argshift
            ;;
        -l|--limit)
            limit="$arg"
            cpulimit_args="$cpulimit_args --limit=$arg"
            shift $argshift
            ;;
        -c|--cpu)
            cpulimit_args="$cpulimit_args --cpu=$arg"
            shift $argshift
            ;;
        -v|--verbose)
            cpulimit_args="$cpulimit_args --verbose"
            shift
            ;;
        -q|--quiet)
            verbose=""
            cpulimit_args="$cpulimit_args --quiet"
            shift
            ;;
        -k|--kill)
            cpulimit_args="$cpulimit_args --kill"
            shift
            ;;
        -r|--restore)
            cpulimit_args="$cpulimit_args --restore"
            shift
            ;;
        -s|--signal)
            cpulimit_args="$cpulimit_args --signal=$arg"
            shift $argshift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unexpected argument: \"$1\""
            exit 3
            ;;
    esac
done

if [ -z "$limit" ]
then
    echo "Must specify a CPU percentage to limit to (-l/--limit)."
    exit 4
fi
if [ -z "$pids" ] && [ -z "$exes" ] && [ -z "$paths" ] && [ "$#" -eq 0 ]
then
    echo "Must specify at least one PID, executable file, path, or command line to limit."
    exit 5
fi

watched_pids=""
limit_pid() {
    if echo "$watched_pids" | grep --silent -F "$1"
    then
        return
    fi
    if [ "$(echo "$watched_pids" | wc -l)" -ge "$max_processes" ]
    then
        return
    fi

    if [ -n "$verbose" ]
    then
        if [ -n "$3" ]
        then
            echo "Limiting $3: "
        fi
        echo "cpulimit --pid=$1 $cpulimit_args"
    fi
    # shellcheck disable=SC2086  # $cpulimit_args really is the intended args.
    cpulimit --pid="$1" $cpulimit_args &
    cpulimit_pid=$!
    new_watched="$1:$2:$cpulimit_pid:$3"
    if [ -z "$watched_pids" ]
    then
        watched_pids="$new_watched"
    else
        watched_pids="$watched_pids
$new_watched"
    fi
}

limit_pids() {
    pids="$1"
    depth="$2"
    while read -r pid
    do
        # From https://stackoverflow.com/a/3951175
        case $pid in
            ''|*[!0-9]*)
                # PID is not a number
                ;;
            *)
                limit_pid "$pid" "$depth" "$3"
                ;;
        esac
    done <<EOF
$pids
EOF
}

limit_by_executable() {
    if [ -n "$exes" ]
    then
        while read -r exe
        do
            limit_pids "$(pgrep -x "$exe")" 0 "$exe"
        done <<EOF
$exes
EOF
    fi

    if [ -n "$paths" ]
    then
        while read -r path
        do
            limit_pids "$(pgrep -xf "$path")" 0 "$path"
        done <<EOF
$paths
EOF
    fi
}

limit_by_subprocess() {
    if [ -z "$watched_pids" ] || [ "$max_depth" -eq 0 ]
    then
        return
    fi

    while read -r watched
    do
        depth="$(echo "$watched" | cut -d: -f2)"
        if [ "$max_depth" -gt "$depth" ]
        then
            # Make sure the parent is still alive.
            if ps -p "$(echo "$watched" | cut -d: -f3)" >/dev/null
            then
                ppid="$(echo "$watched" | cut -d: -f1)"
                original="$(echo "$watched" | cut -d: -f4-)"
                limit_pids "$(pgrep -P "$ppid")" "$((depth + 1))" "child of $ppid ($original)"
            fi
        fi
    done <<EOF
$watched_pids
EOF
}

clean_dead_cpulimit() {
    if [ -z "$watched_pids" ]
    then
        return
    fi

    tmp="$(echo "$watched_pids" | while read -r watched
    do
        if ps -p "$(echo "$watched" | cut -d: -f3)" >/dev/null
        then
            echo "$watched"
        fi
    done)"
    watched_pids="$tmp"
}

if [ "$#" -gt 0 ]
then
    "$@" &
    limit_pid "$!" 0 "program run on command line: $*"
fi

limit_pids "$pids" 0
while true
do
    clean_dead_cpulimit
    if [ -z "$exes" ] && [ -z "$paths" ] && [ -z "$watched_pids" ]
    then
        # If there's nothing left to wait for, then exit.
        exit
    fi
    limit_by_executable
    if [ -z "$watched_pids" ]
    then
        num_watched_before=0
    else
        num_watched_before="$(echo "$watched_pids" | wc -l)"
    fi
    limit_by_subprocess
    if [ -z "$watched_pids" ]
    then
        num_watched_after=0
    else
        num_watched_after="$(echo "$watched_pids" | wc -l)"
    fi
    if [ "$num_watched_before" -eq "$num_watched_after" ]
    then
        if [ "$watch_interval" = "0" ]
        then
            if [ "$num_watched_after" -eq 0 ]
            then
                if [ -n "$verbose" ]
                then
                    echo "No processes found, exiting. Specify --watch-interval to continue scanning for processes."
                fi
                exit
            else
                if [ -n "$verbose" ]
                then
                    echo "Identified all processes to limit, waiting."
                fi
                wait
            fi
        else
            sleep "$watch_interval"
        fi
    else
        sleep "$subprocess_watch_interval"
    fi
done

