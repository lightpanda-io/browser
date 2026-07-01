# Invariant check for the live Hacker News agent output.
#
# The output contract lives in two co-located halves: cases/hn-live.task pins
# what the agent must return, this file verifies it. Edit them together.
#
# We cannot assert exact values (live site + LLM both vary run to run), so we
# assert the *shape*: a JSON array of exactly 5 stories, each with a non-empty
# `title` string and a `comments` array of 0..3 objects, each comment having
# non-empty `user` and `text` strings. A fresh story may legitimately have no
# comments yet, but all 5 empty means extraction is broken — so at least one
# story must have a comment.
#
# Evaluates to true iff every invariant holds. Use with `jq -e -f` so the
# process exit code reflects the result.
def nonempty_string: type == "string" and (length > 0);

(type == "array")
and (length == 5)
and all(.[];
      (.title | nonempty_string)
  and (.comments | type == "array" and length <= 3)
  and (.comments | all(.[]; (.user | nonempty_string) and (.text | nonempty_string)))
)
and any(.[]; .comments | length > 0)
