#!/usr/bin/env node
// PR triage: labels large PRs from untrusted contributors that were not
// discussed in an issue first, so maintainers can decide what to do with them. See CONTRIBUTING.md "Discuss large changes first".
//
//   node pr-triage.js                 run inside the pr-triage workflow
//   node pr-triage.js backtest [N]    classify the last N PRs, print a TSV

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const LIMITS = {
  medium_lines: 100,
  large_lines: 400,
  large_files: 15,
  new_api_lines: 100,
  cli_lines: 20,
};

// PRs opened before this date are never touched.
const ROLLOUT_DATE = "2026-11-18";

const LABEL_LARGE = "needs-discussion";
const LABEL_MEDIUM = "triage:medium";
const LABEL_OVERRIDE = "triage-override";
const LABEL_ACCEPTED = "accepted";

const TEST_PATH = /(^|\/)(tests?|fixtures?|testdata)\//;
const UNCOUNTED = /\.(md|lock|html?|xhtml)$/;
const DEPENDENCY = /^(build\.zig\.zon|src\/rust\/(.+\/)?Cargo\.toml)$/;
const NEW_API = /^src\/(browser\/webapi|server\/cdp)\/.+\.zig$/;
const CLI = /^src\/(cli|Config)\.zig$/;

const TEST_DECL = /^(\s*)test\s+("|[A-Za-z_@][\w.@"]*\s*\{|\{)/;

/// Changed lines of a file, leaving out Zig `test` blocks. Works on the diff
/// alone, so it relies on `zig fmt` layout: a block ends at the `}` that sits
/// at the indentation of its `test` line.
function codeLines(file) {
  if (!file.filename.endsWith(".zig") || !file.patch) return file.additions + file.deletions;
  let count = 0;
  let indent = null;
  for (const line of file.patch.split("\n")) {
    if (line.startsWith("@@")) {
      // The hunk header names the enclosing top-level declaration.
      indent = /^test\s/.test(line.replace(/^@@.*?@@ ?/, "")) ? 0 : null;
      continue;
    }
    if (line.startsWith("\\")) continue;
    const text = line.slice(1);
    const own = text.length - text.trimStart().length;
    let in_test = indent !== null;
    if (in_test && text.trim() && own <= indent) {
      if (own === indent && text.trimStart().startsWith("}")) {
        indent = null;
      } else {
        indent = null;
        in_test = false;
      }
    }
    if (!in_test) {
      const decl = TEST_DECL.exec(text);
      if (decl) {
        indent = decl[1].length;
        in_test = true;
      }
    }
    if (!in_test && (line[0] === "+" || line[0] === "-")) count++;
  }
  return count;
}

/// `files` is the payload of GET /repos/{o}/{r}/pulls/{n}/files.
function classify(files) {
  const counted = files.filter((f) => !TEST_PATH.test(f.filename) && !UNCOUNTED.test(f.filename));
  const lines = counted.reduce((n, f) => n + codeLines(f), 0);
  const names = (list) => list.map((f) => `\`${f.filename}\``).join(", ");

  const rules = [];
  if (lines > LIMITS.large_lines) {
    rules.push({ id: "size", detail: `${lines} changed lines outside tests (limit ${LIMITS.large_lines})` });
  }
  if (counted.length > LIMITS.large_files) {
    rules.push({ id: "wide", detail: `${counted.length} files outside tests (limit ${LIMITS.large_files})` });
  }
  const deps = files.filter((f) => DEPENDENCY.test(f.filename));
  if (deps.length) rules.push({ id: "dependency", detail: `changes dependencies: ${names(deps)}` });
  const apis = files.filter(
    (f) => f.status === "added" && NEW_API.test(f.filename) && !TEST_PATH.test(f.filename) && codeLines(f) >= LIMITS.new_api_lines,
  );
  if (apis.length) rules.push({ id: "new-api", detail: `adds a new Web API or CDP module: ${names(apis)}` });
  const cli = files.filter((f) => CLI.test(f.filename) && codeLines(f) >= LIMITS.cli_lines);
  if (cli.length) rules.push({ id: "cli", detail: `changes the CLI or configuration surface: ${names(cli)}` });

  const verdict = rules.length ? "large" : lines >= LIMITS.medium_lines ? "medium" : "small";
  return { verdict, rules, lines, files: counted.length };
}

function parseAllowlist(text) {
  return new Set(
    text
      .split("\n")
      .map((line) => line.replace(/#.*/, "").trim().replace(/^@/, "").toLowerCase())
      .filter(Boolean),
  );
}

function readAllowlist() {
  const file = path.join(__dirname, "..", "trusted-contributors");
  return fs.existsSync(file) ? parseAllowlist(fs.readFileSync(file, "utf8")) : new Set();
}

function client(token) {
  const call = async (method, route, body) => {
    const res = await fetch(`https://api.github.com${route}`, {
      method,
      headers: {
        authorization: `Bearer ${token}`,
        accept: "application/vnd.github+json",
        "x-github-api-version": "2022-11-28",
        "user-agent": "pr-triage",
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) {
      const err = new Error(`${method} ${route}: ${res.status} ${await res.text()}`);
      err.status = res.status;
      throw err;
    }
    return res.status === 204 ? null : res.json();
  };
  const paginate = async (route, max = 3000) => {
    const out = [];
    for (let page = 1; out.length < max; page++) {
      const batch = await call("GET", `${route}${route.includes("?") ? "&" : "?"}per_page=100&page=${page}`);
      out.push(...batch);
      if (batch.length < 100) break;
    }
    return out.slice(0, max);
  };
  return { call, paginate };
}

async function hasWriteAccess(gh, repo, login) {
  try {
    const { permission } = await gh.call("GET", `/repos/${repo}/collaborators/${login}/permission`);
    return permission === "admin" || permission === "write";
  } catch (err) {
    if (err.status === 404) return false;
    throw err;
  }
}

async function acceptedIssue(gh, repo, number) {
  const [owner, name] = repo.split("/");
  const query = `query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        closingIssuesReferences(first: 20) {
          nodes { number repository { nameWithOwner } labels(first: 50) { nodes { name } } }
        }
      }
    }
  }`;
  const res = await gh.call("POST", "/graphql", { query, variables: { owner, name, number } });
  if (res.errors) throw new Error(JSON.stringify(res.errors));
  const issues = res.data.repository.pullRequest.closingIssuesReferences.nodes;
  const hit = issues.find(
    (i) => i.repository.nameWithOwner === repo && i.labels.nodes.some((l) => l.name === LABEL_ACCEPTED),
  );
  return hit ? hit.number : null;
}

async function setLabel(gh, repo, pr, label, want) {
  const has = pr.labels.some((l) => l.name === label);
  if (want && !has) {
    await gh.call("POST", `/repos/${repo}/issues/${pr.number}/labels`, { labels: [label] });
  } else if (!want && has) {
    await gh.call("DELETE", `/repos/${repo}/issues/${pr.number}/labels/${encodeURIComponent(label)}`);
  }
}

async function run() {
  const event = JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));
  const pr = event.pull_request;
  const repo = process.env.GITHUB_REPOSITORY;
  const gh = client(process.env.GITHUB_TOKEN);
  const login = pr.user.login;

  const summary = (text) => {
    console.log(text);
    if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${text}\n`);
  };
  const pass = async (reason) => {
    await setLabel(gh, repo, pr, LABEL_LARGE, false);
    summary(`**pass**: ${reason}`);
  };

  if (pr.state !== "open" || pr.draft) return summary("**skipped**: closed or draft");
  if (pr.created_at.slice(0, 10) < ROLLOUT_DATE) return summary("**skipped**: opened before rollout");

  if (pr.user.type === "Bot") return pass("author is a bot");
  if (pr.labels.some((l) => l.name === LABEL_OVERRIDE)) return pass(`\`${LABEL_OVERRIDE}\` label`);
  if (readAllowlist().has(login.toLowerCase())) return pass("author is a trusted contributor");
  if (await hasWriteAccess(gh, repo, login)) return pass("author has write access");
  const issue = await acceptedIssue(gh, repo, pr.number);
  if (issue) return pass(`linked issue #${issue} is \`${LABEL_ACCEPTED}\``);

  const files = await gh.paginate(`/repos/${repo}/pulls/${pr.number}/files`);
  const result = classify(files);
  await setLabel(gh, repo, pr, LABEL_MEDIUM, result.verdict === "medium");
  if (result.verdict !== "large") {
    return pass(`${result.verdict}, ${result.lines} lines in ${result.files} files outside tests`);
  }

  await setLabel(gh, repo, pr, LABEL_LARGE, true);
  summary(`**large**\n\n${result.rules.map((r) => `- \`${r.id}\`: ${r.detail}`).join("\n")}`);
}

async function backtest(count) {
  const repo = process.env.GITHUB_REPOSITORY || "lightpanda-io/browser";
  const token = process.env.GITHUB_TOKEN || execFileSync("gh", ["auth", "token"], { encoding: "utf8" }).trim();
  const gh = client(token);
  const allowlist = readAllowlist();
  const prs = await gh.paginate(`/repos/${repo}/pulls?state=all`, count);
  console.log(["pr", "author", "outcome", "verdict", "lines", "files", "rules", "title"].join("\t"));
  for (const pr of prs) {
    const insider = ["OWNER", "MEMBER", "COLLABORATOR"].includes(pr.author_association);
    if (insider || pr.user.type === "Bot" || allowlist.has(pr.user.login.toLowerCase())) continue;
    const result = classify(await gh.paginate(`/repos/${repo}/pulls/${pr.number}/files`));
    const outcome = pr.merged_at ? "merged" : pr.state;
    const rules = result.rules.map((r) => r.id).join(",");
    console.log([pr.number, pr.user.login, outcome, result.verdict, result.lines, result.files, rules, pr.title.slice(0, 60)].join("\t"));
  }
}

module.exports = { classify, codeLines, parseAllowlist, client, hasWriteAccess, acceptedIssue, LIMITS };

if (require.main === module) {
  const [mode, arg] = process.argv.slice(2);
  (mode === "backtest" ? backtest(Number(arg) || 300) : run()).catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
