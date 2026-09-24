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

// THE ONE THING YOU NEED TO KNOW ABOUT THIS API:
// It's a configuration for generating safe HTML. It can either be in the shape
// of "deny these things" or "allow these things". That's mutually exclusive! You
// can have _allow_elements != null OR _remove_elements != null, but not both.
// Methods need to work with both shapes. E.g. if we're removing something and
// _allow_elements != null, then we remove it from _allow_elements. BUT, if
// _allow_elements == null, then we add it to _remove_elements. This applies
// to every category, e.g _allow_attributes vs _remove_attributes.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const TreeWalker = @import("TreeWalker.zig");
const defaults = @import("sanitizer_defaults.zig");

const String = lp.String;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const Sanitizer = @This();

// intern common namespaces
pub const Namespace = union(enum) {
    none, // always distinct from any other value
    xhtml,
    svg,
    mathml,
    xlink,
    xml,
    xmlns,
    other: []const u8,

    const lookup = std.StaticStringMap(Namespace).initComptime(.{
        .{ defaults.xhtml_ns, .xhtml },
        .{ defaults.svg_ns, .svg },
        .{ defaults.mathml_ns, .mathml },
        .{ defaults.xlink_ns, .xlink },
        .{ defaults.xml_ns, .xml },
        .{ defaults.xmlns_ns, .xmlns },
    });

    fn intern(namespace_: ?[]const u8) Namespace {
        const namespace = namespace_ orelse return .none;
        if (namespace.len == 0) {
            return .none;
        }
        return lookup.get(namespace) orelse .{ .other = namespace };
    }

    pub fn uri(self: Namespace) ?[]const u8 {
        switch (self) {
            .none => return null,
            .other => |value| return value,
            inline else => |_, tag| {
                for (lookup.values(), 0..) |value, i| {
                    if (value == tag) {
                        return lookup.keys()[i];
                    }
                } else unreachable; // has to be in the lookup
            },
        }
    }

    fn eql(a: Namespace, b: Namespace) bool {
        const a_uri = switch (a) {
            .other => |value| value,
            else => return std.meta.activeTag(a) == std.meta.activeTag(b),
        };
        const b_uri = switch (b) {
            .other => |value| value,
            else => return false,
        };
        return std.mem.eql(u8, a_uri, b_uri);
    }
};

pub const Name = struct {
    name: String, // attribute or element name
    namespace: Namespace,

    fn lessThan(_: void, a: Name, b: Name) bool {
        const a_ns = a.namespace.uri() orelse {
            return b.namespace != .none or std.mem.lessThan(u8, a.name.str(), b.name.str());
        };
        const b_ns = b.namespace.uri() orelse return false;
        return switch (std.mem.order(u8, a_ns, b_ns)) {
            .lt => true,
            .gt => false,
            .eq => std.mem.lessThan(u8, a.name.str(), b.name.str()),
        };
    }

    fn eql(a: Name, b: Name) bool {
        return a.namespace.eql(b.namespace) and a.name.eql(b.name);
    }

    fn isDataAttribute(self: Name) bool {
        return self.namespace == .none and std.mem.startsWith(u8, self.name.str(), "data-");
    }
};

const NameContext = struct {
    pub fn hash(_: NameContext, key: Name) u32 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.name.str());
        hasher.update(&.{@intFromEnum(std.meta.activeTag(key.namespace))});
        if (key.namespace == .other) {
            hasher.update(key.namespace.other);
        }
        return @truncate(hasher.final());
    }

    pub fn eql(_: NameContext, a: Name, b: Name, _: usize) bool {
        return a.eql(b);
    }
};

const NameSet = std.array_hash_map.Custom(Name, void, NameContext, true);
const NameMap = std.array_hash_map.Custom(Name, NameSet, NameContext, true);
const TargetSet = std.array_hash_map.String(void);

_rc: lp.RC = .{},
_owned_arena: *lp.Arena,
_arena: Allocator,

_allow_elements: ?NameSet = null,
_remove_elements: ?NameSet = null,
_replace_elements: ?NameSet = null,
_allow_attributes: ?NameSet = null,
_remove_attributes: ?NameSet = null,
_allow_processing_instructions: ?TargetSet = null,
_remove_processing_instructions: ?TargetSet = null,
_element_allow_attributes: NameMap = .empty,
_element_remove_attributes: NameMap = .empty,

// tri-states, need to capture absent
_comments: ?bool = null,
_data_attributes: ?bool = null,
_javascript_urls: ?bool = null,

const ElementNamespace = struct {
    name: []const u8,
    namespace: js.Nullable([]const u8) = .{ .value = defaults.xhtml_ns },
};

const ElementNamespaceWithAttributes = struct {
    attributes: ?[]const SanitizerAttribute = null,
    name: []const u8,
    namespace: js.Nullable([]const u8) = .{ .value = defaults.xhtml_ns },
    removeAttributes: ?[]const SanitizerAttribute = null,
};

const AttributeNamespace = struct {
    name: []const u8,
    namespace: js.Nullable([]const u8) = .{ .value = null },
};

const ProcessingInstruction = struct {
    target: []const u8,
};

const SanitizerElement = union(enum) {
    dictionary: ElementNamespace,
    string: []const u8,
};

const SanitizerElementWithAttributes = union(enum) {
    dictionary: ElementNamespaceWithAttributes,
    string: []const u8,
};

const SanitizerAttribute = union(enum) {
    dictionary: AttributeNamespace,
    string: []const u8,
};

const SanitizerPI = union(enum) {
    dictionary: ProcessingInstruction,
    string: []const u8,
};

const Config = struct {
    attributes: ?[]const SanitizerAttribute = null,
    comments: ?js.Value = null,
    dataAttributes: ?js.Value = null,
    elements: ?[]const SanitizerElementWithAttributes = null,
    javascriptURLs: ?js.Value = null,
    processingInstructions: ?[]const SanitizerPI = null,
    removeAttributes: ?[]const SanitizerAttribute = null,
    removeElements: ?[]const SanitizerElement = null,
    removeProcessingInstructions: ?[]const SanitizerPI = null,
    replaceWithChildrenElements: ?[]const SanitizerElement = null,

    fn boolean(value: ?js.Value, dflt: bool) bool {
        // we use ?js.Value for our booleans to tell the difference between not
        // provided vs null. Not provided -> default. Null -> false
        const v = value orelse return dflt;
        return v.toBool();
    }
};

// ?js.Value because not provided, undefined and null are all handled differently
pub fn init(configuration_: ?js.Value, exec: *const Execution) !*Sanitizer {
    return create(configuration_, true, exec);
}

fn create(configuration_: ?js.Value, permissive_defaults: bool, exec: *const Execution) !*Sanitizer {
    const arena = try exec.getPinnedArena(.small, "Sanitizer");
    errdefer arena.release();

    const self = try arena.create(Sanitizer);
    self.* = .{ ._owned_arena = arena, ._arena = arena.allocator() };

    blk: {
        const configuration = configuration_ orelse {
            try self.setFromDefault();
            break :blk;
        };

        if (configuration.isUndefined()) {
            try self.setFromDefault();
            break :blk;
        }

        if (configuration.isString()) |preset| {
            if ((try preset.toSSO(false)).eql(comptime .wrap("default")) == false) {
                return exec.js.typeError("invalid Sanitizer preset");
            }
            try self.setFromDefault();
            break :blk;
        }

        const config: Config = if (configuration.isNull()) .{} else try configuration.toZig(Config);
        if (try self.setFromConfig(config, permissive_defaults) == false) {
            return exec.js.typeError("invalid Sanitizer configuration");
        }
    }

    arena.report();
    return self;
}

pub fn deinit(self: *Sanitizer, _: *Page) void {
    self._owned_arena.release();
}

pub fn acquireRef(self: *Sanitizer) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *Sanitizer, page: *Page) void {
    self._rc.release(self, page);
}

// `new Sanitizer("default")`, uses the built-in safe defaults
fn setFromDefault(self: *Sanitizer) !void {
    const arena = self._arena;

    var elements: NameSet = .empty;
    try elements.ensureTotalCapacity(arena, defaults.default_elements.len);
    for (defaults.default_elements) |element| {
        const name = staticName(.{ .name = element.name, .namespace = element.namespace });
        elements.putAssumeCapacity(name, {});

        // Every default element carries an attribute list, empty or not.
        var attributes: NameSet = .empty;
        try attributes.ensureTotalCapacity(arena, element.attributes.len);
        for (element.attributes) |attribute| {
            attributes.putAssumeCapacity(staticName(attribute), {});
        }
        try self._element_allow_attributes.put(arena, name, attributes);
    }
    self._allow_elements = elements;

    var attributes: NameSet = .empty;
    try attributes.ensureTotalCapacity(arena, defaults.default_attributes.len);
    for (defaults.default_attributes) |attribute| {
        attributes.putAssumeCapacity(staticName(attribute), {});
    }
    self._allow_attributes = attributes;

    self._allow_processing_instructions = .empty;
    self._comments = false;
    self._data_attributes = false;
    self._javascript_urls = false;
}

fn setFromConfig(self: *Sanitizer, config: Config, permissive_defaults: bool) !bool {
    var all_new = true;

    const arena = self._arena;
    if (config.elements) |elements| {
        var set: NameSet = .empty;
        for (elements) |element| {
            const name = try self.ownName(canonicalElementWithAttributes(element));
            all_new = try insertNew(&set, arena, name) and all_new;

            switch (element) {
                .string => {},
                .dictionary => |dictionary| {
                    if (dictionary.attributes) |attributes| {
                        all_new = try self.putElementAttributes(&self._element_allow_attributes, name, attributes) and all_new;
                    }
                    if (dictionary.removeAttributes) |attributes| {
                        all_new = try self.putElementAttributes(&self._element_remove_attributes, name, attributes) and all_new;
                    }
                },
            }
            // canonical form: an element with neither list has an empty remove-list
            if (self._element_allow_attributes.contains(name) == false and self._element_remove_attributes.contains(name) == false) {
                try self._element_remove_attributes.put(arena, name, .empty);
            }
        }
        self._allow_elements = set;
    }
    if (config.removeElements) |elements| {
        self._remove_elements = try self.elementSet(elements, &all_new);
    }
    if (config.replaceWithChildrenElements) |elements| {
        self._replace_elements = try self.elementSet(elements, &all_new);
    }
    if (config.attributes) |attributes| {
        self._allow_attributes = try self.attributeSet(attributes, &all_new);
    }
    if (config.removeAttributes) |attributes| {
        self._remove_attributes = try self.attributeSet(attributes, &all_new);
    }
    if (config.processingInstructions) |pis| {
        self._allow_processing_instructions = try self.targetSet(pis, &all_new);
    }
    if (config.removeProcessingInstructions) |pis| {
        self._remove_processing_instructions = try self.targetSet(pis, &all_new);
    }

    self._comments = Config.boolean(config.comments, permissive_defaults);
    if (self._allow_attributes != null or config.dataAttributes != null) {
        self._data_attributes = Config.boolean(config.dataAttributes, permissive_defaults);
    }
    self._javascript_urls = Config.boolean(config.javascriptURLs, permissive_defaults);

    if (config.elements == null and config.removeElements == null) {
        self._remove_elements = .empty;
    }
    if (config.attributes == null and config.removeAttributes == null) {
        self._remove_attributes = .empty;
    }
    if (self._allow_processing_instructions == null and self._remove_processing_instructions == null) {
        if (permissive_defaults) {
            self._remove_processing_instructions = .empty;
        } else {
            self._allow_processing_instructions = .empty;
        }
    }

    return all_new and self.isValid();
}

fn elementSet(self: *Sanitizer, elements: []const SanitizerElement, all_new: *bool) !NameSet {
    var set: NameSet = .empty;
    for (elements) |element| {
        const name = try self.ownName(canonicalElement(element));
        all_new.* = try insertNew(&set, self._arena, name) and all_new.*;
    }
    return set;
}

fn attributeSet(self: *Sanitizer, attributes: []const SanitizerAttribute, all_new: *bool) !NameSet {
    var set: NameSet = .empty;
    for (attributes) |attribute| {
        const name = try self.ownName(canonicalAttribute(attribute));
        all_new.* = try insertNew(&set, self._arena, name) and all_new.*;
    }
    return set;
}

fn targetSet(self: *Sanitizer, pis: []const SanitizerPI, all_new: *bool) !TargetSet {
    var set: TargetSet = .empty;
    for (pis) |pi| {
        const target = try self.own(canonicalTarget(pi));
        const gop = try set.getOrPut(self._arena, target);
        all_new.* = gop.found_existing == false and all_new.*;
        gop.value_ptr.* = {};
    }
    return set;
}

fn putElementAttributes(self: *Sanitizer, map: *NameMap, element: Name, attributes: []const SanitizerAttribute) !bool {
    var all_new = true;
    var set: NameSet = .empty;
    for (attributes) |attribute| {
        const name = try self.ownName(canonicalAttribute(attribute));
        all_new = try insertNew(&set, self._arena, name) and all_new;
    }
    const gop = try map.getOrPut(self._arena, element);
    // A duplicated element name is already fatal; don't let it merge lists.
    all_new = gop.found_existing == false and all_new;
    gop.value_ptr.* = set;
    return all_new;
}

fn insertNew(set: *NameSet, arena: Allocator, name: Name) !bool {
    const gop = try set.getOrPut(arena, name);
    gop.value_ptr.* = {};
    return gop.found_existing == false;
}

fn canonicalElement(element: SanitizerElement) defaults.Name {
    return switch (element) {
        .string => |name| .{ .name = name, .namespace = .xhtml },
        .dictionary => |d| .{ .name = d.name, .namespace = .intern(d.namespace.value) },
    };
}

fn canonicalElementWithAttributes(element: SanitizerElementWithAttributes) defaults.Name {
    return switch (element) {
        .string => |name| .{ .name = name, .namespace = .xhtml },
        .dictionary => |d| .{ .name = d.name, .namespace = .intern(d.namespace.value) },
    };
}

fn canonicalAttribute(attribute: SanitizerAttribute) defaults.Name {
    return switch (attribute) {
        .string => |name| .{ .name = name, .namespace = .none },
        .dictionary => |d| .{ .name = d.name, .namespace = .intern(d.namespace.value) },
    };
}

fn canonicalTarget(pi: SanitizerPI) []const u8 {
    return switch (pi) {
        .string => |target| target,
        .dictionary => |d| d.target,
    };
}

fn staticName(name: defaults.Name) Name {
    // no allocation required, comes from sanitizer_defaults, which are all literals
    return .{ .name = .wrap(name.name), .namespace = name.namespace };
}

// Take ownership of the name into our arena
fn ownName(self: *Sanitizer, name: defaults.Name) !Name {
    return .{
        .name = try .init(self._arena, name.name, .{}),
        .namespace = switch (name.namespace) {
            .other => |uri| .{ .other = try self.own(uri) },
            else => name.namespace,
        },
    };
}

fn own(self: *Sanitizer, value: []const u8) ![]const u8 {
    return String.intern(value) orelse self._arena.dupe(u8, value);
}

// -

const JsName = struct {
    name: String,
    namespace: ?[]const u8,
};

const JsTarget = struct {
    target: []const u8,
};

pub fn get(self: *const Sanitizer, exec: *const Execution) !js.Object {
    const local = exec.js.local.?;
    const arena = exec.call_arena;
    const config = local.newObject();

    if (self._allow_elements) |elements| {
        const names = try sortedNames(elements, arena);
        const array = local.newArray(@intCast(names.len));
        for (names, 0..) |*name, i| {
            // name.name == String, need name by ref, else we end up with
            // dangling pointer on this stack when we set.
            const element = local.newObject();
            _ = try element.set("name", name.name, .{});
            _ = try element.set("namespace", name.namespace.uri(), .{});

            const allowed = self._element_allow_attributes.getPtr(name.*);
            const removed = self._element_remove_attributes.getPtr(name.*);
            if (allowed) |set| {
                _ = try element.set("attributes", try nameArray(set.*, arena, local), .{});
            }
            if (removed) |set| {
                _ = try element.set("removeAttributes", try nameArray(set.*, arena, local), .{});
            }
            _ = try array.set(@intCast(i), element, .{});
        }
        _ = try config.set("elements", array, .{});
    }
    if (self._remove_elements) |elements| {
        _ = try config.set("removeElements", try nameArray(elements, arena, local), .{});
    }
    if (self._replace_elements) |elements| {
        _ = try config.set("replaceWithChildrenElements", try nameArray(elements, arena, local), .{});
    }
    if (self._allow_attributes) |attributes| {
        _ = try config.set("attributes", try nameArray(attributes, arena, local), .{});
    }
    if (self._remove_attributes) |attributes| {
        _ = try config.set("removeAttributes", try nameArray(attributes, arena, local), .{});
    }
    if (self._allow_processing_instructions) |pis| {
        _ = try config.set("processingInstructions", try sortedTargets(pis, arena, local), .{});
    }
    if (self._remove_processing_instructions) |pis| {
        _ = try config.set("removeProcessingInstructions", try sortedTargets(pis, arena, local), .{});
    }
    if (self._comments) |comments| {
        _ = try config.set("comments", comments, .{});
    }
    if (self._data_attributes) |data_attributes| {
        _ = try config.set("dataAttributes", data_attributes, .{});
    }
    if (self._javascript_urls) |javascript_urls| {
        _ = try config.set("javascriptURLs", javascript_urls, .{});
    }
    return config;
}

fn sortedNames(set: NameSet, arena: Allocator) ![]Name {
    const names = try arena.dupe(Name, set.keys());
    std.mem.sort(Name, names, {}, Name.lessThan);
    return names;
}

fn nameArray(set: NameSet, arena: Allocator, local: *const js.Local) !js.Array {
    const names = try sortedNames(set, arena);
    const array = local.newArray(@intCast(names.len));
    for (names, 0..) |*name, i| {
        _ = try array.set(@intCast(i), JsName{ .name = name.name, .namespace = name.namespace.uri() }, .{});
    }
    return array;
}

fn sortedTargets(set: TargetSet, arena: Allocator, local: *const js.Local) !js.Array {
    const targets = try arena.dupe([]const u8, set.keys());
    std.mem.sort([]const u8, targets, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const array = local.newArray(@intCast(targets.len));
    for (targets, 0..) |target, i| {
        _ = try array.set(@intCast(i), JsTarget{ .target = target }, .{});
    }
    return array;
}

fn allowElement(self: *Sanitizer, element: SanitizerElementWithAttributes) !bool {
    const name = try self.ownName(canonicalElementWithAttributes(element));
    const dictionary = switch (element) {
        .string => return self.allowName(name, null, null),
        .dictionary => |d| d,
    };

    var allowed: NameSet = .empty;
    if (dictionary.attributes) |attributes| {
        for (attributes) |attribute| {
            _ = try insertNew(&allowed, self._arena, try self.ownName(canonicalAttribute(attribute)));
        }
    }
    var removed: NameSet = .empty;
    if (dictionary.removeAttributes) |attributes| {
        for (attributes) |attribute| {
            _ = try insertNew(&removed, self._arena, try self.ownName(canonicalAttribute(attribute)));
        }
    }
    return self.allowName(
        name,
        if (dictionary.attributes == null) null else &allowed,
        if (dictionary.removeAttributes == null) null else &removed,
    );
}

fn removeElement(self: *Sanitizer, element: SanitizerElement) !bool {
    return self.removeName(try self.ownName(canonicalElement(element)));
}

fn replaceElementWithChildren(self: *Sanitizer, element: SanitizerElement) !bool {
    return self.replaceName(try self.ownName(canonicalElement(element)));
}

fn allowAttribute(self: *Sanitizer, attribute: SanitizerAttribute) !bool {
    return self.allowAttributeName(try self.ownName(canonicalAttribute(attribute)));
}

fn removeAttribute(self: *Sanitizer, attribute: SanitizerAttribute) !bool {
    return self.removeAttributeName(try self.ownName(canonicalAttribute(attribute)));
}

fn allowProcessingInstruction(self: *Sanitizer, pi: SanitizerPI) !bool {
    const target = try self.own(canonicalTarget(pi));
    if (self._allow_processing_instructions) |*allowed| {
        if (allowed.contains(target)) {
            return false;
        }
        try allowed.put(self._arena, target, {});
        return true;
    }
    const removed = &self._remove_processing_instructions.?;
    return removed.swapRemove(target);
}

fn removeProcessingInstruction(self: *Sanitizer, pi: SanitizerPI) !bool {
    const target = try self.own(canonicalTarget(pi));
    if (self._allow_processing_instructions) |*allowed| {
        return allowed.swapRemove(target);
    }
    const removed = &self._remove_processing_instructions.?;
    if (removed.contains(target)) {
        return false;
    }
    try removed.put(self._arena, target, {});
    return true;
}

fn setComments(self: *Sanitizer, allow: bool) bool {
    if (self._comments == allow) {
        return false;
    }
    self._comments = allow;
    return true;
}

fn setDataAttributes(self: *Sanitizer, allow: bool) bool {
    const allowed = &(self._allow_attributes orelse return false);
    if (self._data_attributes == allow) {
        return false;
    }
    if (allow) {
        // any data-* attribte named individually must now be dropped
        for (self._element_allow_attributes.values()) |*set| {
            removeDataAttributes(set);
        }
        removeDataAttributes(allowed);
    }
    self._data_attributes = allow;
    return true;
}

fn setJavascriptURLs(self: *Sanitizer, allow: bool) bool {
    if (self._javascript_urls == allow) {
        return false;
    }
    self._javascript_urls = allow;
    return true;
}

// The baseline is a remove list, removeName and removeAttributeName work with
// both an allow-config and remove-config, so here, we don't need to worry about
// which config shape we have.
fn removeUnsafe(self: *Sanitizer) !bool {
    var modified = false;
    for (defaults.baseline_remove_elements) |element| {
        modified = try self.removeName(staticName(element)) or modified;
    }
    for (defaults.event_handler_attributes) |attribute| {
        modified = try self.removeAttributeName(staticName(.{ .name = attribute, .namespace = .none })) or modified;
    }
    if (self._javascript_urls == true) {
        self._javascript_urls = false;
        modified = true;
    }
    return modified;
}

fn allowName(self: *Sanitizer, name: Name, allowed_: ?*NameSet, removed_: ?*NameSet) !bool {
    const allowed = allowed_;
    var removed = removed_;

    const elements = &(self._allow_elements orelse {
        // A remove-list config has no per-element lists to put these in.
        if (allowed != null or (removed != null and removed.?.count() != 0)) {
            return false;
        }
        var modified = self.takeReplace(name);
        const remove_elements = &self._remove_elements.?;
        if (remove_elements.swapRemove(name)) {
            modified = true;
        }
        return modified;
    });

    const modified = self.takeReplace(name);

    if (self._allow_attributes) |global_allowed| {
        if (allowed) |set| {
            removeAll(set, global_allowed);
            if (self._data_attributes == true) {
                removeDataAttributes(set);
            }
        }
        if (removed) |set| {
            retainAll(set, global_allowed);
        }
    } else {
        const global_removed = self._remove_attributes.?;
        if (allowed) |set| {
            if (removed) |other| {
                removeAll(set, other.*);
                removed = null;
            }
            removeAll(set, global_removed);
        }
        if (removed) |set| {
            removeAll(set, global_removed);
        }
    }

    // canonical form: an element with neither list has an empty remove-list
    var empty: NameSet = .empty;
    if (allowed == null and removed == null) {
        removed = &empty;
    }

    if (elements.contains(name) == false) {
        try elements.put(self._arena, name, {});
        try self.setElementAttributes(name, allowed, removed);
        return true;
    }

    // Already allowed: only report a change if the attribute lists differ.
    if (sameSet(self._element_allow_attributes.getPtr(name), allowed) and
        sameSet(self._element_remove_attributes.getPtr(name), removed))
    {
        return modified;
    }
    try self.setElementAttributes(name, allowed, removed);
    return true;
}

fn setElementAttributes(self: *Sanitizer, name: Name, allowed: ?*NameSet, removed: ?*NameSet) !void {
    _ = self._element_allow_attributes.swapRemove(name);
    if (allowed) |set| {
        try self._element_allow_attributes.put(self._arena, name, set.*);
    }
    _ = self._element_remove_attributes.swapRemove(name);
    if (removed) |set| {
        try self._element_remove_attributes.put(self._arena, name, set.*);
    }
}

fn removeName(self: *Sanitizer, name: Name) !bool {
    var modified = self.takeReplace(name);
    if (self._allow_elements) |*elements| {
        if (elements.swapRemove(name)) {
            modified = true;
        }
        _ = self._element_allow_attributes.swapRemove(name);
        _ = self._element_remove_attributes.swapRemove(name);
        return modified;
    }
    const elements = &self._remove_elements.?;
    const gop = try elements.getOrPut(self._arena, name);
    gop.value_ptr.* = {};
    return modified or gop.found_existing == false;
}

fn replaceName(self: *Sanitizer, name: Name) !bool {
    for (defaults.non_replaceable_elements) |element| {
        if (staticName(element).eql(name)) {
            return false;
        }
    }
    if (self._replace_elements) |elements| {
        if (elements.contains(name)) {
            return false;
        }
    }
    if (self._remove_elements) |*elements| {
        _ = elements.swapRemove(name);
    }
    if (self._allow_elements) |*elements| {
        _ = elements.swapRemove(name);
        _ = self._element_allow_attributes.swapRemove(name);
        _ = self._element_remove_attributes.swapRemove(name);
    }
    if (self._replace_elements == null) {
        self._replace_elements = .empty;
    }
    try self._replace_elements.?.put(self._arena, name, {});
    return true;
}

fn allowAttributeName(self: *Sanitizer, name: Name) !bool {
    const allowed = &(self._allow_attributes orelse {
        const removed = &self._remove_attributes.?;
        return removed.swapRemove(name);
    });

    // Already covered by the blanket data-attribute allowance.
    if (self._data_attributes == true and name.isDataAttribute()) {
        return false;
    }
    if (allowed.contains(name)) {
        return false;
    }
    // A global allowance subsumes any per-element one.
    for (self._element_allow_attributes.values()) |*set| {
        _ = set.swapRemove(name);
    }
    try allowed.put(self._arena, name, {});
    return true;
}

fn removeAttributeName(self: *Sanitizer, name: Name) !bool {
    if (self._allow_attributes) |*allowed| {
        var modified = allowed.swapRemove(name);
        for (self._element_allow_attributes.values()) |*set| {
            if (set.swapRemove(name)) {
                modified = true;
            }
        }
        // Only meaningful against a global allow-list, which just lost `name`.
        for (self._element_remove_attributes.values()) |*set| {
            _ = set.swapRemove(name);
        }
        return modified;
    }

    const removed = &self._remove_attributes.?;
    if (removed.contains(name)) {
        return false;
    }
    for (self._element_allow_attributes.values()) |*set| {
        _ = set.swapRemove(name);
    }
    for (self._element_remove_attributes.values()) |*set| {
        _ = set.swapRemove(name);
    }
    try removed.put(self._arena, name, {});
    return true;
}

fn takeReplace(self: *Sanitizer, name: Name) bool {
    const elements = &(self._replace_elements orelse return false);
    return elements.swapRemove(name);
}

fn removeAll(target: *NameSet, other: NameSet) void {
    for (other.keys()) |key| {
        _ = target.swapRemove(key);
    }
}

fn retainAll(target: *NameSet, other: NameSet) void {
    var i = target.count();
    while (i > 0) {
        i -= 1;
        if (other.contains(target.keys()[i]) == false) {
            target.swapRemoveAt(i);
        }
    }
}

fn removeDataAttributes(target: *NameSet) void {
    var i = target.count();
    while (i > 0) {
        i -= 1;
        if (target.keys()[i].isDataAttribute()) {
            target.swapRemoveAt(i);
        }
    }
}

fn sameSet(current: ?*NameSet, new: ?*NameSet) bool {
    const a = current orelse return new == null;
    const b = new orelse return false;
    if (a.count() != b.count()) {
        return false;
    }
    for (a.keys()) |key| {
        if (b.contains(key) == false) {
            return false;
        }
    }
    return true;
}

// The sets validate themselves, what we need to do here is apply cross-set
// validation, e.g. either allow or remove
fn isValid(self: *const Sanitizer) bool {
    if (self._allow_elements != null and self._remove_elements != null) {
        return false;
    }
    if (self._allow_attributes != null and self._remove_attributes != null) {
        return false;
    }
    if (self._allow_processing_instructions != null and self._remove_processing_instructions != null) {
        return false;
    }

    if (self._replace_elements) |replaced| {
        for (defaults.non_replaceable_elements) |element| {
            if (replaced.contains(staticName(element))) {
                return false;
            }
        }
        if (intersects(self._allow_elements, replaced) or intersects(self._remove_elements, replaced)) {
            return false;
        }
    }

    if (self._allow_attributes) |allowed| {
        if (self._allow_elements) |elements| {
            for (elements.keys()) |element| {
                if (self._element_allow_attributes.getPtr(element)) |per_element| {
                    if (intersects(allowed, per_element.*)) {
                        return false;
                    }
                    if (self._data_attributes == true and hasDataAttribute(per_element.*)) {
                        return false;
                    }
                }
                if (self._element_remove_attributes.getPtr(element)) |per_element| {
                    if (isSubset(per_element.*, allowed) == false) {
                        return false;
                    }
                }
            }
        }
        if (self._data_attributes == true and hasDataAttribute(allowed)) {
            return false;
        }
        return true;
    }

    const removed = self._remove_attributes.?;
    if (self._allow_elements) |elements| {
        for (elements.keys()) |element| {
            const allow_per_element = self._element_allow_attributes.getPtr(element);
            const remove_per_element = self._element_remove_attributes.getPtr(element);
            if (allow_per_element != null and remove_per_element != null) {
                return false;
            }
            if (allow_per_element) |per_element| {
                if (intersects(removed, per_element.*)) {
                    return false;
                }
            }
            if (remove_per_element) |per_element| {
                if (intersects(removed, per_element.*)) {
                    return false;
                }
            }
        }
    }
    return self._data_attributes == null;
}

fn intersects(a_: ?NameSet, b: NameSet) bool {
    const a = a_ orelse return false;
    for (a.keys()) |key| {
        if (b.contains(key)) {
            return true;
        }
    }
    return false;
}

fn isSubset(subset: NameSet, superset: NameSet) bool {
    for (subset.keys()) |key| {
        if (superset.contains(key) == false) {
            return false;
        }
    }
    return true;
}

fn hasDataAttribute(set: NameSet) bool {
    for (set.keys()) |key| {
        if (key.isDataAttribute()) {
            return true;
        }
    }
    return false;
}

// Like init: we need to tell the difference between not-set, null and  undefined
// AND, this can actually be a Sanitizer config already.
pub const Options = struct {
    sanitizer: ?js.Value = null,
};

const FromOptions = struct {
    owned: bool,
    sanitizer: *Sanitizer,

    fn release(self: FromOptions, page: *Page) void {
        if (self.owned) {
            // We have to free a Sanitizer we created, versus a Sanitizer that
            // was passed to use from JS.
            self.sanitizer.deinit(page);
        }
    }
};

fn fromOptions(options: ?Options, safe: bool, exec: *const Execution) !?FromOptions {
    const spec = blk: {
        const o = options orelse break :blk null;
        const spec = o.sanitizer orelse break :blk null;
        if (spec.isUndefined()) {
            break :blk null;
        }
        if (spec.toZig(*Sanitizer)) |sanitizer| {
            return .{ .sanitizer = sanitizer, .owned = false };
        } else |_| {}
        break :blk spec;
    };

    if (spec == null and safe == false) {
        return null;
    }
    // A missing spec takes the "default" preset
    return .{ .sanitizer = try create(spec, safe == false, exec), .owned = true };
}

pub fn setAndFilterHTML(target: *Node, context: *Element, html: []const u8, options: ?Options, safe: bool, frame: *Frame) !void {
    if (safe and std.mem.eql(u8, context.getLocalName(), "script")) {
        if (context._namespace == .html or context._namespace == .svg) {
            // hahaha, nice try!
            return;
        }
    }

    const resolved = try fromOptions(options, safe, &frame.js.execution);
    defer if (resolved) |r| r.release(frame.page);

    // Parsed into a detached fragment, so that nothing is connected (no fetch,
    // no custom element reaction) until it's been sanitized.
    const fragment = (try Node.DocumentFragment.init(target.getDocument(frame), frame)).asNode();
    if (html.len > 0) {
        try Frame.parse.fragment(frame, fragment, html, .{ .context = context, .allow_declarative_shadow = true });
    }
    if (resolved) |r| {
        try r.sanitizer.sanitize(fragment, safe, frame);
    }
    try target.replaceAllWithFragment(fragment, frame);
}

pub fn parseHTML(html: []const u8, options: ?Options, safe: bool, frame: *Frame) !*Node.Document {
    const resolved = try fromOptions(options, safe, &frame.js.execution);
    defer if (resolved) |r| r.release(frame.page);

    const document = (try Frame.parse.htmlDocument(frame, html, .{ .allow_declarative_shadow = true })).asDocument();
    document._url = "about:blank";
    if (resolved) |r| {
        try r.sanitizer.sanitize(document.asNode(), safe, frame);
    }
    return document;
}

fn sanitize(self: *const Sanitizer, root: *Node, safe: bool, frame: *Frame) !void {
    const arena = frame.call_arena;

    // A template's contents and a shadow root are trees of their own
    var trees: std.ArrayList(*Node) = .empty;
    try trees.append(arena, root);

    var remove_attributes: std.ArrayList([]const u8) = .empty;

    // Parents that lost a child, whose text nodes might now be adjacent.
    var touched: std.ArrayList(*Node) = .empty;

    while (trees.pop()) |tree| {
        var tw = TreeWalker.FullExcludeSelf.init(tree, .{});
        while (tw.next()) |node| {
            const parent = node._parent.?;
            const element = node.is(Element) orelse {
                if (self.keepNonElement(node) == false) {
                    tw.skipChildren();
                    frame.removeNode(parent, node, .{ .reconnect_to = null });
                    try touch(&touched, parent, arena);
                }
                continue;
            };

            const element_name: Name = .{ .name = .wrap(element.getLocalName()), .namespace = elementNamespace(element, frame) };
            switch (self.elementAction(element_name, safe)) {
                .keep => {},
                .remove => {
                    tw.skipChildren();
                    frame.removeNode(parent, node, .{ .reconnect_to = null });
                    try touch(&touched, parent, arena);
                    continue;
                },
                .replace => {
                    // Move the children up; the walker's next node is the
                    // first of them (or, if there are none, what follows).
                    // run_ready = false: nothing gets to act on them until
                    // they've been sanitized.
                    if (node.firstChild() != null) {
                        const previous_root = node.getRootNode(.{});
                        while (node.firstChild()) |child| {
                            frame.removeNode(node, child, .{ .reconnect_to = parent });
                            try frame.insertNodeRelative(parent, child, .{ .before = node }, .{ .previous_root = previous_root, .run_ready = false });
                        }
                    }
                    frame.removeNode(parent, node, .{ .reconnect_to = null });
                    try touch(&touched, parent, arena);
                    continue;
                },
            }

            if (element.is(Element.Html.Template)) |template| {
                try trees.append(arena, template.getContent().asNode());
            }
            if (element.hostedShadowRoot(frame)) |shadow_root| {
                try trees.append(arena, shadow_root.asNode());
            }

            // Collected first: removing one can run script (attributeChangedCallback)
            remove_attributes.clearRetainingCapacity();
            for (element.attributeEntries()) |*entry| {
                if (self.keepAttribute(element_name, entry.name(), entry.value(), safe) == false) {
                    try remove_attributes.append(arena, entry.name());
                }
            }
            for (remove_attributes.items) |name| {
                element.removeAttributeSafe(.wrap(name), frame);
            }
        }
    }

    var buffer: std.ArrayList(u8) = .empty;
    for (touched.items) |parent| {
        try mergeAdjacentText(parent, &buffer, frame);
    }
}

fn touch(touched: *std.ArrayList(*Node), parent: *Node, arena: Allocator) !void {
    // Siblings are removed one after another, so this catches most repeats.
    // Those it misses just get a second, no-op, merge.
    if (touched.getLastOrNull() != parent) {
        try touched.append(arena, parent);
    }
}

// if we removed a node between two text nodes, we need to merge the text ndoes

fn mergeAdjacentText(parent: *Node, buffer: *std.ArrayList(u8), frame: *Frame) !void {
    var child = parent.firstChild();
    while (child) |node| {
        var next = node.nextSibling();
        const text = node.is(Node.CData.Text) orelse {
            child = next;
            continue;
        };
        if (next == null or next.?.is(Node.CData.Text) == null) {
            child = next;
            continue;
        }

        buffer.clearRetainingCapacity();
        try buffer.appendSlice(frame.call_arena, text.ownData());
        while (next) |sibling| {
            const sibling_text = sibling.is(Node.CData.Text) orelse break;
            try buffer.appendSlice(frame.call_arena, sibling_text.ownData());
            next = sibling.nextSibling();
            frame.removeNode(parent, sibling, .{ .reconnect_to = null });
        }
        text.asCData()._data = try frame.dupeSSO(buffer.items);
        child = next;
    }
}

fn keepNonElement(self: *const Sanitizer, node: *Node) bool {
    const cdata = node.is(Node.CData) orelse return true; // doctype
    return switch (cdata._type) {
        .text, .cdata_section => true,
        .comment => self._comments == true,
        .processing_instruction => {
            const target = cdata.subtype(Node.CData.ProcessingInstruction)._target;
            if (self._allow_processing_instructions) |allowed| {
                return allowed.contains(target);
            }
            return self._remove_processing_instructions.?.contains(target) == false;
        },
    };
}

fn elementAction(self: *const Sanitizer, name: Name, safe: bool) enum { keep, remove, replace } {
    if (safe) {
        for (defaults.baseline_remove_elements) |unsafe| {
            if (staticName(unsafe).eql(name)) {
                return .remove;
            }
        }
    }
    if (self._replace_elements) |replace| {
        if (replace.contains(name)) {
            return .replace;
        }
    }
    if (self._allow_elements) |allowed| {
        return if (allowed.contains(name)) .keep else .remove;
    }
    return if (self._remove_elements.?.contains(name)) .remove else .keep;
}

fn keepAttribute(self: *const Sanitizer, element: Name, qualified_name: []const u8, value: []const u8, safe: bool) bool {
    const name = attributeName(element.namespace, qualified_name);

    const element_allowed = self._element_allow_attributes.getPtr(element);
    if (self._element_remove_attributes.getPtr(element)) |removed| {
        if (removed.contains(name)) {
            return false;
        }
    }

    if (self._allow_attributes) |allowed| {
        if (allowed.contains(name) == false and
            (element_allowed == null or element_allowed.?.contains(name) == false) and
            (self._data_attributes != true or name.isDataAttribute() == false))
        {
            return false;
        }
    } else {
        if (element_allowed) |set| {
            if (set.contains(name) == false) {
                return false;
            }
        } else if (self._remove_attributes.?.contains(name)) {
            return false;
        }
    }

    if (safe and name.namespace == .none and isEventHandler(qualified_name)) {
        return false;
    }

    if (safe or self._javascript_urls != true) {
        if (isNavigatingURLAttribute(element, name) and isJavascriptURL(value)) {
            return false;
        }
        if (isAnimatingURLAttribute(element, name) and (std.mem.eql(u8, value, "href") or std.mem.eql(u8, value, "xlink:href"))) {
            return false;
        }
    }
    return true;
}

fn elementNamespace(element: *Element, frame: *Frame) Namespace {
    return switch (element._namespace) {
        .html => .xhtml,
        .svg => .svg,
        .mathml => .mathml,
        .xml => .xml,
        .null => .none,
        .unknown => .intern(element.getNamespaceUri(frame)),
    };
}

// Attributes' namespaces aren't tracked, but the HTML parser only ever gives a
// namespace to these attributes of foreign (SVG/MathML) elements.
// https://html.spec.whatwg.org/#adjust-foreign-attributes
const foreign_attributes = std.StaticStringMap(defaults.Name).initComptime(.{
    .{ "xlink:actuate", defaults.Name{ .name = "actuate", .namespace = .xlink } },
    .{ "xlink:arcrole", defaults.Name{ .name = "arcrole", .namespace = .xlink } },
    .{ "xlink:href", defaults.Name{ .name = "href", .namespace = .xlink } },
    .{ "xlink:role", defaults.Name{ .name = "role", .namespace = .xlink } },
    .{ "xlink:show", defaults.Name{ .name = "show", .namespace = .xlink } },
    .{ "xlink:title", defaults.Name{ .name = "title", .namespace = .xlink } },
    .{ "xlink:type", defaults.Name{ .name = "type", .namespace = .xlink } },
    .{ "xml:lang", defaults.Name{ .name = "lang", .namespace = .xml } },
    .{ "xml:space", defaults.Name{ .name = "space", .namespace = .xml } },
    .{ "xmlns", defaults.Name{ .name = "xmlns", .namespace = .xmlns } },
    .{ "xmlns:xlink", defaults.Name{ .name = "xlink", .namespace = .xmlns } },
});

fn attributeName(element_namespace: Namespace, qualified_name: []const u8) Name {
    if (element_namespace == .svg or element_namespace == .mathml) {
        if (foreign_attributes.get(qualified_name)) |name| {
            return staticName(name);
        }
    }
    return .{ .name = .wrap(qualified_name), .namespace = .none };
}

fn isEventHandler(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "on") == false) {
        return false;
    }
    return std.sort.binarySearch([]const u8, defaults.event_handler_attributes, name, struct {
        fn order(key: []const u8, item: []const u8) std.math.Order {
            return std.mem.order(u8, key, item);
        }
    }.order) != null;
}

// https://html.spec.whatwg.org/#built-in-navigating-url-attributes-list
fn isNavigatingURLAttribute(element: Name, attribute: Name) bool {
    const local = attribute.name.str();
    switch (element.namespace) {
        .xhtml => {
            if (attribute.namespace != .none) {
                return false;
            }
            const tag = element.name.str();
            if (std.mem.eql(u8, tag, "a") or std.mem.eql(u8, tag, "area")) {
                return std.mem.eql(u8, local, "href");
            }
            if (std.mem.eql(u8, tag, "form")) {
                return std.mem.eql(u8, local, "action");
            }
            if (std.mem.eql(u8, tag, "button") or std.mem.eql(u8, tag, "input")) {
                return std.mem.eql(u8, local, "formaction");
            }
            return false;
        },
        // any MathML element, not just <a>
        .svg, .mathml => {
            if (element.namespace == .svg and std.mem.eql(u8, element.name.str(), "a") == false) {
                return false;
            }
            return (attribute.namespace == .none or attribute.namespace == .xlink) and std.mem.eql(u8, local, "href");
        },
        else => return false,
    }
}

fn isAnimatingURLAttribute(element: Name, attribute: Name) bool {
    if (element.namespace != .svg or attribute.namespace != .none) {
        return false;
    }
    if (std.mem.eql(u8, attribute.name.str(), "attributeName") == false) {
        return false;
    }
    const tag = element.name.str();
    return std.mem.eql(u8, tag, "animate") or std.mem.eql(u8, tag, "animateTransform") or std.mem.eql(u8, tag, "set");
}

fn isJavascriptURL(value: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, value, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f ");
    const scheme = "javascript:";
    var i: usize = 0;
    for (trimmed) |c| {
        if (c == '\t' or c == '\n' or c == '\r') {
            continue;
        }
        if (std.ascii.toLower(c) != scheme[i]) {
            return false;
        }
        i += 1;
        if (i == scheme.len) {
            return true;
        }
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Sanitizer);

    pub const Meta = struct {
        pub const name = "Sanitizer";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Sanitizer.init, .{});
    pub const get = bridge.function(Sanitizer.get, .{});
    pub const allowElement = bridge.function(Sanitizer.allowElement, .{});
    pub const removeElement = bridge.function(Sanitizer.removeElement, .{});
    pub const replaceElementWithChildren = bridge.function(Sanitizer.replaceElementWithChildren, .{});
    pub const allowAttribute = bridge.function(Sanitizer.allowAttribute, .{});
    pub const removeAttribute = bridge.function(Sanitizer.removeAttribute, .{});
    pub const allowProcessingInstruction = bridge.function(Sanitizer.allowProcessingInstruction, .{});
    pub const removeProcessingInstruction = bridge.function(Sanitizer.removeProcessingInstruction, .{});
    pub const setComments = bridge.function(Sanitizer.setComments, .{});
    pub const setDataAttributes = bridge.function(Sanitizer.setDataAttributes, .{});
    pub const setJavascriptURLs = bridge.function(Sanitizer.setJavascriptURLs, .{});
    pub const removeUnsafe = bridge.function(Sanitizer.removeUnsafe, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Sanitizer" {
    testing.expectLog(&.{.js});
    try testing.htmlRunner("sanitizer.html", .{});
}
