const MAX_FAILURES = 20;

class ValidationError extends Error {
	constructor(failures) {
		const f = failures[0];
		super(`${f.path}: expected ${f.expected}, got ${f.got} (${f.count} of ${f.of})`);
		this.name = "ValidationError";
		this.failures = failures;
	}
}

const describe = (v) => {
	if (Array.isArray(v)) return "array";
	if (v !== null && typeof v === "object") return "object";
	if (typeof v === "string") return JSON.stringify(v.length > 40 ? v.slice(0, 40) + "…" : v);
	return String(v);
};

// Failures are grouped by path with the array indexes wildcarded, so a broken
// selector reads "30 of 30" and an edge case "1 of 30".
class Report {
	visits = new Map();
	groups = new Map();

	visit(path) {
		const wild = path.replace(/\[\d+\]/g, "[*]");
		this.visits.set(wild, (this.visits.get(wild) ?? 0) + 1);
		return wild;
	}

	fail(wild, expected, value) {
		const key = wild + "\0" + expected;
		const group = this.groups.get(key);
		if (group) {
			group.count += 1;
		} else {
			this.groups.set(key, { path: wild, expected, got: describe(value), count: 1, of: 0 });
		}
	}

	failures() {
		const failures = Array.from(this.groups.values()).slice(0, MAX_FAILURES);
		for (const f of failures) f.of = this.visits.get(f.path);
		return failures;
	}
}

const type = (expected, ok) => (value, path, report) => {
	const wild = report.visit(path);
	if (!ok(value)) report.fail(wild, expected, value);
};

const canParseURL = (v) => {
	try {
		new URL(v);
		return true;
	} catch {
		return false;
	}
};

const string = type("non-empty string", (v) => typeof v === "string" && v.trim() !== "");
const int = type("int", Number.isSafeInteger);
const number = type("number", Number.isFinite);
const bool = type("bool", (v) => typeof v === "boolean");
const url = type("absolute url", (v) => typeof v === "string" && canParseURL(v));
const date = type("date", (v) => typeof v === "string" && !Number.isNaN(Date.parse(v)));

// A plain object stands for object(shape).
const checker = (c) => (typeof c === "function" ? c : object(c));

const optional = (c) => (value, path, report) => {
	if (value != null) checker(c)(value, path, report);
};

const object = (shape) => (value, path, report) => {
	const wild = report.visit(path);
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		return report.fail(wild, "object", value);
	}
	for (const key of Object.keys(shape)) {
		checker(shape[key])(value[key], `${path}.${key}`, report);
	}
};

const array = (item, { min, max } = {}) => (value, path, report) => {
	const wild = report.visit(path);
	if (!Array.isArray(value)) {
		return report.fail(wild, "array", value);
	}
	if (min != null && value.length < min) report.fail(wild, `at least ${min} items`, value.length);
	if (max != null && value.length > max) report.fail(wild, `at most ${max} items`, value.length);
	value.forEach((v, i) => checker(item)(v, `${path}[${i}]`, report));
};

// true, or throws a ValidationError carrying every failure.
const check = (value, c) => {
	const report = new Report();
	checker(c)(value, "$", report);
	const failures = report.failures();
	if (failures.length === 0) return true;
	throw new ValidationError(failures);
};

export function runValidate(rule, value) {
	if (typeof rule.validate !== "function") return null;
	let result;
	try {
		result = rule.validate(value, helpers);
	} catch (e) {
		if (e instanceof ValidationError) return e.failures;
		throw e;
	}
	if (result instanceof Promise) throw new Error("validate returned a promise");
	if (result) return null;
	return [{ path: "$", expected: "validate to return true", got: describe(result), count: 1, of: 1 }];
}

export const helpers = Object.freeze({
	string,
	int,
	number,
	bool,
	url,
	date,
	optional,
	object,
	array,
	check
});
