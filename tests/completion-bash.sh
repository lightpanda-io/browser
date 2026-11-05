#!/usr/bin/env bash

set -e
set -o pipefail

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

if [ "$#" -ne 1 ]; then
    fail "usage: $0 /path/to/lightpanda"
fi

completion_binary=$1
case "$completion_binary" in
    /*) ;;
    *) completion_binary="$(cd "$(dirname "$completion_binary")" && pwd)/$(basename "$completion_binary")" ;;
esac
[ -x "$completion_binary" ] || fail "not an executable binary: $completion_binary"

completion_bash=${COMPLETION_BASH:-bash}
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

completion_script="$tmpdir/lightpanda-completion.bash"
generation_stderr="$tmpdir/generation.stderr"
"$completion_binary" completion bash >"$completion_script" 2>"$generation_stderr"
[ ! -s "$generation_stderr" ] || {
    cat "$generation_stderr" >&2
    fail "generating the Bash completion script wrote to stderr"
}

fixture_dir="$tmpdir/fixtures"
mkdir "$fixture_dir"
literal_tab="literal"$'\t'"tab.txt"
literal_apostrophe="literal'apostrophe.txt"
literal_quote='literal"quote.txt'
literal_backslash='literal\backslash.txt'
literal_dollar='literal$dollar.txt'
literal_star='literal*star.txt'
literal_bracket='literal[bracket].txt'
touch "$fixture_dir/script.js" \
    "$fixture_dir/script with space.js" \
    "$fixture_dir/branch.txt" \
    "$fixture_dir/$literal_tab" \
    "$fixture_dir/$literal_apostrophe" \
    "$fixture_dir/$literal_quote" \
    "$fixture_dir/$literal_backslash" \
    "$fixture_dir/$literal_dollar" \
    "$fixture_dir/$literal_star" \
    "$fixture_dir/$literal_bracket" \
    "$fixture_dir/insert with space.js"
mkdir "$fixture_dir/nested directory"
mkdir "$fixture_dir/run" "$fixture_dir/bash" "$fixture_dir/iframe" "$fixture_dir/image,iframe"
touch "$fixture_dir/nested directory/child script.js"
cd "$fixture_dir"

source "$completion_script"

invoke_completion() {
    set +e
    _lightpanda
    set -e
}

assert_candidates() {
    local scenario=$1
    shift
    local expected actual found

    if [ "${#COMPREPLY[@]}" -ne "$#" ]; then
        printf 'not ok - %s: expected %s candidates, got %s' \
            "$scenario" "$#" "${#COMPREPLY[@]}" >&2
        for actual in "${COMPREPLY[@]}"; do
            printf ' <%q>' "$actual" >&2
        done
        printf '\n' >&2
        return 1
    fi

    for expected in "$@"; do
        found=0
        for actual in "${COMPREPLY[@]}"; do
            if [ "$actual" = "$expected" ]; then
                found=1
                break
            fi
        done
        [ "$found" -eq 1 ] || {
            printf 'not ok - %s: missing candidate <%q>' "$scenario" "$expected" >&2
            for actual in "${COMPREPLY[@]}"; do
                printf ' <%q>' "$actual" >&2
            done
            printf '\n' >&2
            return 1
        }
    done

    printf 'ok - %s\n' "$scenario"
}

assert_path_branch() {
    local scenario=$1 command=$2 previous=$3 prefix=$4
    COMPREPLY=("stale candidate")
    COMP_WORDS=(lightpanda "$command" "$previous" "$prefix")
    COMP_CWORD=3
    invoke_completion
    assert_candidates "$scenario" branch.txt
}

# A single prefix can return two filenames, one containing a space.
COMP_WORDS=(lightpanda run script)
COMP_CWORD=2
COMPREPLY=("stale candidate")
invoke_completion
assert_candidates "run-path preserves two filename boundaries" script.js "script with space.js"

# Which flags get path completion is checked against the CLI table by the
# "completion: bash path arms" unit test; here one long flag, one short flag
# and one positional exercise the helper itself.
assert_path_branch "fetch --cookie path completion" fetch --cookie branch
assert_path_branch "agent -a path completion" agent -a branch
assert_path_branch "run positional path completion" run run branch

# Tabs, quotes, backslashes and glob characters stay inside their filename.
COMP_WORDS=(lightpanda run literal)
COMP_CWORD=2
COMPREPLY=()
invoke_completion
assert_candidates "literal-paths keeps special characters in single candidates" \
    "$literal_tab" \
    "$literal_apostrophe" \
    "$literal_quote" \
    "$literal_backslash" \
    "$literal_dollar" \
    "$literal_star" \
    "$literal_bracket"

# A failed call clears stale replies, and a later matching call repopulates them.
COMP_WORDS=(lightpanda run absent-prefix)
COMP_CWORD=2
COMPREPLY=("stale candidate")
invoke_completion
assert_candidates "no-match clears stale path replies"
COMP_WORDS=(lightpanda run branch)
COMP_CWORD=2
invoke_completion
assert_candidates "matching call repopulates path replies" branch.txt

# Directories remain candidates and can be used as a prefix for a nested file.
COMP_WORDS=(lightpanda run nest)
COMP_CWORD=2
COMPREPLY=()
invoke_completion
assert_candidates "directory completion preserves candidate boundary" "nested directory"
COMP_WORDS=(lightpanda run "nested directory/child")
COMP_CWORD=2
COMPREPLY=()
invoke_completion
assert_candidates "nested path completion preserves boundary" "nested directory/child script.js"

# Non-path candidate modes retain their values and comma-list filtering.
COMP_WORDS=(lightpanda ru)
COMP_CWORD=1
COMPREPLY=()
invoke_completion
assert_candidates "other-values includes run command" run
COMP_WORDS=(lightpanda completion ba)
COMP_CWORD=2
COMPREPLY=()
invoke_completion
assert_candidates "other-values includes bash shell" bash
COMP_WORDS=(lightpanda fetch --load-resources image,if)
COMP_CWORD=3
COMPREPLY=()
invoke_completion
assert_candidates "other-values filters comma-list without repeating image" image,iframe

assert_interactive_invocation() {
    local scenario=$1 line=$2 expected=$3
    if [ "$line" != "$expected" ]; then
        printf 'not ok - %s: captured invocation was <%s>, expected <%s>\n' \
            "$scenario" "$line" "$expected" >&2
        return 1
    fi
    printf 'ok - %s\n' "$scenario"
}

run_interactive_completion() {
    local shadow=${1:-baseline}
    local rcfile="$tmpdir/readline.rc"
    local captured="$tmpdir/readline.lines"
    local ready="$tmpdir/readline.ready"
    local transcript="$tmpdir/readline.transcript"
    local bash_command line

    cat >"$rcfile" <<'EOF'
PS1='COMPLETION_TEST> '
case "$LIGHTPANDA_COMPOPT_SHADOW" in
    function) compopt() { :; } ;;
    alias) shopt -s expand_aliases; alias compopt=':' ;;
esac
source "$LIGHTPANDA_COMPLETION_SCRIPT"
lightpanda() {
    # Bash 3.2 leaves READLINE_LINE unset, so the mock records parsed arguments.
    printf '%s:%s:%s:%s\n' "$#" "$1" "$2" "$3" >> "$LIGHTPANDA_CAPTURE_FILE"
}
: >"$LIGHTPANDA_READY_FILE"
EOF
    : >"$captured"
    rm -f "$ready"

    # Polls for up to 10s; on timeout the line count check below reports it.
    wait_for() {
        local tries=0
        until eval "$1"; do
            tries=$((tries + 1))
            [ "$tries" -lt 200 ] || return 0
            sleep 0.05
        done
    }

    # Each line goes in once the previous one has run, so no fixed delay has
    # to outlast a slow runner.
    feed_interactive_input() {
        local sent=0 input
        wait_for '[ -e "$ready" ]'
        for input in \
            'lightpanda run insert\t\n' \
            'lightpanda run "insert with\t\n' \
            'lightpanda run nest\t\n' \
            'lightpanda run "nested directory/child\t\n' \
            'lightpanda ru\t\n' \
            'lightpanda completion ba\t\n' \
            'lightpanda fetch --load-resources image,if\t\n' \
            'lightpanda ru\t --help\n' \
            'lightpanda run bran\t\n'; do
            printf "$input"
            sent=$((sent + 1))
            wait_for '[ "$(wc -l <"$captured")" -ge "$sent" ]'
        done
        printf 'exit\n'
    }

    if [ "$(uname -s)" = Darwin ]; then
        feed_interactive_input | env \
            INPUTRC=/dev/null \
            HISTFILE=/dev/null \
            LIGHTPANDA_COMPOPT_SHADOW="$shadow" \
            LIGHTPANDA_COMPLETION_SCRIPT="$completion_script" \
            LIGHTPANDA_CAPTURE_FILE="$captured" \
            LIGHTPANDA_READY_FILE="$ready" \
            script -q "$transcript" "$completion_bash" --noprofile --rcfile "$rcfile" -i >/dev/null
    else
        printf -v bash_command '%q --noprofile --rcfile %q -i' "$completion_bash" "$rcfile"
        feed_interactive_input | env \
            INPUTRC=/dev/null \
            HISTFILE=/dev/null \
            LIGHTPANDA_COMPOPT_SHADOW="$shadow" \
            LIGHTPANDA_COMPLETION_SCRIPT="$completion_script" \
            LIGHTPANDA_CAPTURE_FILE="$captured" \
            LIGHTPANDA_READY_FILE="$ready" \
            script -q -c "$bash_command" "$transcript" >/dev/null
    fi

    local -a lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done <"$captured"
    [ "${#lines[@]}" -eq 9 ] || fail "interactive TAB test captured ${#lines[@]} lines, expected 9"

    assert_interactive_invocation "interactive unquoted filename insertion" "${lines[0]}" "2:run:insert with space.js:"
    assert_interactive_invocation "interactive quoted-prefix insertion" "${lines[1]}" "2:run:insert with space.js:"
    assert_interactive_invocation "interactive directory insertion" "${lines[2]}" "2:run:nested directory/:"
    assert_interactive_invocation "interactive nested quoted-prefix insertion" "${lines[3]}" "2:run:nested directory/child script.js:"
    assert_interactive_invocation "interactive command insertion" "${lines[4]}" "1:run::"
    assert_interactive_invocation "interactive enum insertion" "${lines[5]}" "2:completion:bash:"
    assert_interactive_invocation "interactive comma-list insertion" "${lines[6]}" "3:fetch:--load-resources:image,iframe"
    assert_interactive_invocation "value insertion leaves room for the next token" "${lines[7]}" "2:run:--help:"
    assert_interactive_invocation "path completion still works after value completion" "${lines[8]}" "2:run:branch.txt:"
}

run_interactive_completion baseline
run_interactive_completion function
run_interactive_completion alias
printf 'All Bash completion checks passed with %s (%s).\n' \
    "$completion_bash" "$("$completion_bash" --version | head -1)"
