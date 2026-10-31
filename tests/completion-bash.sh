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

# Exercise every path-valued shared flag branch for each command that emits it.
common_path_flags=(
    --http-cache-dir
    --render-font
    --web-bot-auth-key-file
    --adblock-lists
    --cookie
    --cookie-jar
    --ca-cert
    --ca-path
)
common_path_commands=(serve fetch mcp agent run)
for command in "${common_path_commands[@]}"; do
    for flag in "${common_path_flags[@]}"; do
        assert_path_branch "$command $flag path completion" "$command" "$flag" branch
    done
done

assert_path_branch "serve --unix-socket path completion" serve --unix-socket branch
assert_path_branch "fetch --wait-script-file path completion" fetch --wait-script-file branch
assert_path_branch "fetch --inject-script-file path completion" fetch --inject-script-file branch
assert_path_branch "agent --trace path completion" agent --trace branch
assert_path_branch "agent --save path completion" agent --save branch
assert_path_branch "agent --attach path completion" agent --attach branch
assert_path_branch "agent -a path completion" agent -a branch
assert_path_branch "agent positional path completion" agent agent branch
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
    local rcfile="$tmpdir/readline.rc"
    local captured="$tmpdir/readline.lines"
    local transcript="$tmpdir/readline.transcript"
    local bash_command line

    cat >"$rcfile" <<'EOF'
PS1='COMPLETION_TEST> '
source "$LIGHTPANDA_COMPLETION_SCRIPT"
lightpanda() {
    # Bash 3.2 leaves READLINE_LINE unset, so the mock records parsed arguments.
    printf '%s:%s:%s:%s\n' "$#" "$1" "$2" "$3" >> "$LIGHTPANDA_CAPTURE_FILE"
}
EOF
    : >"$captured"

    feed_interactive_input() {
        sleep 1
        printf 'lightpanda run insert'; sleep 0.2; printf '\t'; sleep 0.2; printf '\n'; sleep 0.5
        printf 'lightpanda run "insert with'; sleep 0.2; printf '\t'; sleep 0.2; printf '\n'; sleep 0.5
        printf 'lightpanda run nest'; sleep 0.2; printf '\t'; sleep 0.2; printf '\n'; sleep 0.5
        printf 'lightpanda run "nested directory/child'; sleep 0.2; printf '\t'; sleep 0.2; printf '\n'; sleep 0.5
        printf 'lightpanda ru'; sleep 0.2; printf '\t'; sleep 0.2; printf '\n'; sleep 0.5
        printf 'lightpanda completion ba'; sleep 0.2; printf '\t'; sleep 0.2; printf '\n'; sleep 0.5
        printf 'lightpanda fetch --load-resources image,if'; sleep 0.2; printf '\t'; sleep 0.2; printf '\n'; sleep 0.5
        printf 'exit\n'
    }

    if [ "$(uname -s)" = Darwin ]; then
        feed_interactive_input | env \
            INPUTRC=/dev/null \
            HISTFILE=/dev/null \
            LIGHTPANDA_COMPLETION_SCRIPT="$completion_script" \
            LIGHTPANDA_CAPTURE_FILE="$captured" \
            script -q "$transcript" "$completion_bash" --noprofile --rcfile "$rcfile" -i >/dev/null
    else
        printf -v bash_command '%q --noprofile --rcfile %q -i' "$completion_bash" "$rcfile"
        feed_interactive_input | env \
            INPUTRC=/dev/null \
            HISTFILE=/dev/null \
            LIGHTPANDA_COMPLETION_SCRIPT="$completion_script" \
            LIGHTPANDA_CAPTURE_FILE="$captured" \
            script -q -c "$bash_command" "$transcript" >/dev/null
    fi

    local -a lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done <"$captured"
    [ "${#lines[@]}" -eq 7 ] || fail "interactive TAB test captured ${#lines[@]} lines, expected 7"

    assert_interactive_invocation "interactive unquoted filename insertion" "${lines[0]}" "2:run:insert with space.js:"
    assert_interactive_invocation "interactive quoted-prefix insertion" "${lines[1]}" "2:run:insert with space.js:"
    assert_interactive_invocation "interactive directory insertion" "${lines[2]}" "2:run:nested directory/:"
    assert_interactive_invocation "interactive nested quoted-prefix insertion" "${lines[3]}" "2:run:nested directory/child script.js:"
    assert_interactive_invocation "interactive command insertion" "${lines[4]}" "1:run::"
    assert_interactive_invocation "interactive enum insertion" "${lines[5]}" "2:completion:bash:"
    assert_interactive_invocation "interactive comma-list insertion" "${lines[6]}" "3:fetch:--load-resources:image,iframe"
}

run_interactive_completion
printf 'All Bash completion checks passed with %s (%s).\n' \
    "$completion_bash" "$("$completion_bash" --version | head -1)"
