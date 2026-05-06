// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! XPath 1.0 AST.
//!
//! Mirrors the polyfill AST in capybara-lightpanda
//! (lib/capybara/lightpanda/javascripts/index.js, the `op:`-tagged
//! object literals built by Parser.prototype.parse*). Slices and
//! pointers are arena-owned by the Parser; the AST has no destructor.

pub const Expr = union(enum) {
    /// Absolute or relative location path: `/foo/bar`, `//x`, `foo/bar`.
    path: Path,
    /// Filter expression followed by a location-path tail:
    /// `(//a)/b`, `(expr)//c`.
    filter_path: FilterPath,
    /// Filter expression with a single predicate: `(expr)[n]`.
    /// Multi-predicate filters nest: `(e)[1][2]` → filter(filter(e,1),2).
    filter: Filter,
    binop: BinOp,
    /// Unary minus. The polyfill has no unary `+`.
    neg: *Expr,
    /// String literal, quotes stripped.
    literal: []const u8,
    /// Numeric literal, parsed to f64.
    number: f64,
    /// Variable reference. The leading `$` is stripped; per decision #3
    /// the evaluator always returns the empty string.
    var_ref: []const u8,
    fn_call: FnCall,
};

pub const Path = struct {
    absolute: bool,
    steps: []const Step,
};

pub const FilterPath = struct {
    filter: *Expr,
    steps: []const Step,
};

pub const Filter = struct {
    expr: *Expr,
    predicate: *Expr,
};

pub const BinOp = struct {
    op: BinOpKind,
    left: *Expr,
    right: *Expr,
};

pub const BinOpKind = enum {
    or_,
    and_,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    add,
    sub,
    mul,
    div,
    mod,
    union_,
};

pub const FnCall = struct {
    name: []const u8,
    args: []const *Expr,
};

pub const Step = struct {
    axis: Axis,
    node_test: NodeTest,
    predicates: []const *Expr,
};

pub const Axis = enum {
    child,
    descendant,
    descendant_or_self,
    self,
    parent,
    ancestor,
    ancestor_or_self,
    following_sibling,
    preceding_sibling,
    following,
    preceding,
    attribute,
    namespace,
    /// Polyfill parity (decision #2): unknown axis names parse to
    /// this variant; the evaluator returns an empty node-set.
    unknown,
};

pub const NodeTest = union(enum) {
    /// Element / attribute name. `"*"` is the wildcard. Namespaced forms
    /// (`prefix:*`, `prefix:local`) are stored verbatim — the evaluator
    /// does not split them, so they fall through to a literal `mem.eql`
    /// against the node name (consistent with the `namespace::` axis stub
    /// per decision #3).
    /// TODO: real namespace support if the polyfill ever drops the stub.
    name: []const u8,
    /// `node()`, `text()`, `comment()`, `processing-instruction()`.
    /// The optional target literal of `processing-instruction("foo")`
    /// is consumed but not stored (decision #3 stub).
    type_test: TypeTest,
};

pub const TypeTest = enum {
    node,
    text,
    comment,
    processing_instruction,
};
