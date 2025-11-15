// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

mod types;
mod sink;

#[cfg(debug_assertions)]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

use types::*;
use std::cell::Cell;
use std::os::raw::{c_uchar, c_void};

use html5ever::{parse_document, parse_fragment, QualName, LocalName, ns, ParseOpts, Parser};
use html5ever::tendril::{TendrilSink, StrTendril};
use html5ever::interface::tree_builder::QuirksMode;

#[no_mangle]
pub extern "C" fn html5ever_parse_document(
    html: *mut c_uchar,
    len: usize,
    document: Ref,
    ctx: Ref,
    create_element_callback: CreateElementCallback,
    get_data_callback: GetDataCallback,
    append_callback: AppendCallback,
    parse_error_callback: ParseErrorCallback,
    pop_callback: PopCallback,
    create_comment_callback: CreateCommentCallback,
    append_doctype_to_document: AppendDoctypeToDocumentCallback,
    add_attrs_if_missing_callback: AddAttrsIfMissingCallback,
    get_template_contents_callback: GetTemplateContentsCallback,
    remove_from_parent_callback: RemoveFromParentCallback,
    reparent_children_callback: ReparentChildrenCallback,
) -> () {
    if html.is_null() || len == 0 {
        return ();
    }

    let arena = typed_arena::Arena::new();

    let sink = sink::Sink {
        ctx: ctx,
        arena: &arena,
        document: document,
        quirks_mode: Cell::new(QuirksMode::NoQuirks),
        pop_callback: pop_callback,
        append_callback: append_callback,
        get_data_callback: get_data_callback,
        parse_error_callback: parse_error_callback,
        create_element_callback: create_element_callback,
        create_comment_callback: create_comment_callback,
        append_doctype_to_document: append_doctype_to_document,
        add_attrs_if_missing_callback: add_attrs_if_missing_callback,
        get_template_contents_callback: get_template_contents_callback,
        remove_from_parent_callback: remove_from_parent_callback,
        reparent_children_callback: reparent_children_callback,
    };

    let bytes = unsafe { std::slice::from_raw_parts(html, len) };
    parse_document(sink, Default::default())
        .from_utf8()
        .one(bytes);
}

#[no_mangle]
pub extern "C" fn html5ever_parse_fragment(
    html: *mut c_uchar,
    len: usize,
    document: Ref,
    ctx: Ref,
    create_element_callback: CreateElementCallback,
    get_data_callback: GetDataCallback,
    append_callback: AppendCallback,
    parse_error_callback: ParseErrorCallback,
    pop_callback: PopCallback,
    create_comment_callback: CreateCommentCallback,
    append_doctype_to_document: AppendDoctypeToDocumentCallback,
    add_attrs_if_missing_callback: AddAttrsIfMissingCallback,
    get_template_contents_callback: GetTemplateContentsCallback,
    remove_from_parent_callback: RemoveFromParentCallback,
    reparent_children_callback: ReparentChildrenCallback,
) -> () {
    if html.is_null() || len == 0 {
        return ();
    }

    let arena = typed_arena::Arena::new();

    let sink = sink::Sink {
        ctx: ctx,
        arena: &arena,
        document: document,
        quirks_mode: Cell::new(QuirksMode::NoQuirks),
        pop_callback: pop_callback,
        append_callback: append_callback,
        get_data_callback: get_data_callback,
        parse_error_callback: parse_error_callback,
        create_element_callback: create_element_callback,
        create_comment_callback: create_comment_callback,
        append_doctype_to_document: append_doctype_to_document,
        add_attrs_if_missing_callback: add_attrs_if_missing_callback,
        get_template_contents_callback: get_template_contents_callback,
        remove_from_parent_callback: remove_from_parent_callback,
        reparent_children_callback: reparent_children_callback,
    };

    let bytes = unsafe { std::slice::from_raw_parts(html, len) };
    parse_fragment(
        sink, Default::default(),
        QualName::new(None, ns!(html), LocalName::from("body")),
        vec![],     // attributes
        false,      // context_element_allows_scripting
    )
        .from_utf8()
        .one(bytes);
}

#[no_mangle]
pub extern "C" fn html5ever_attribute_iterator_next(
    c_iter: *const c_void,
) -> CNullable<CAttribute> {
    let iter: &mut CAttributeIterator = unsafe { &mut *(c_iter as *mut CAttributeIterator) };

    let pos = iter.pos;
    if pos == iter.vec.len() {
        return CNullable::<CAttribute>::none();
    }

    let attr = &iter.vec[pos];
    iter.pos += 1;
    return CNullable::<CAttribute>::some(CAttribute {
        name: CQualName::create(&attr.name),
        value: StringSlice {
            ptr: attr.value.as_ptr(),
            len: attr.value.len(),
        },
    });
}

#[no_mangle]
pub extern "C" fn html5ever_attribute_iterator_count(c_iter: *const c_void) -> usize {
    let iter: &mut CAttributeIterator = unsafe { &mut *(c_iter as *mut CAttributeIterator) };
    return iter.vec.len();
}

#[cfg(debug_assertions)]
#[repr(C)]
pub struct Memory {
    pub resident: usize,
    pub allocated: usize,
}

#[cfg(debug_assertions)]
#[no_mangle]
pub extern "C" fn html5ever_get_memory_usage() -> Memory {
    use tikv_jemalloc_ctl::{stats, epoch};

    // many statistics are cached and only updated when the epoch is advanced.
    epoch::advance().unwrap();

    return Memory{
        resident: stats::resident::read().unwrap(),
        allocated: stats::allocated::read().unwrap(),
    }
}

// Streaming parser API
// The Parser type from html5ever implements TendrilSink and supports streaming
pub struct StreamingParser {
    arena: Box<typed_arena::Arena<sink::ElementData>>,
    parser: Box<dyn std::any::Any>,
}

#[no_mangle]
pub extern "C" fn html5ever_streaming_parser_create(
    document: Ref,
    ctx: Ref,
    create_element_callback: CreateElementCallback,
    get_data_callback: GetDataCallback,
    append_callback: AppendCallback,
    parse_error_callback: ParseErrorCallback,
    pop_callback: PopCallback,
    create_comment_callback: CreateCommentCallback,
    append_doctype_to_document: AppendDoctypeToDocumentCallback,
    add_attrs_if_missing_callback: AddAttrsIfMissingCallback,
    get_template_contents_callback: GetTemplateContentsCallback,
    remove_from_parent_callback: RemoveFromParentCallback,
    reparent_children_callback: ReparentChildrenCallback,
) -> *mut c_void {
    let arena = Box::new(typed_arena::Arena::new());

    // SAFETY: We're creating a self-referential structure here.
    // The arena is stored in the StreamingParser and lives as long as the parser.
    // The sink contains a reference to the arena that's valid for the parser's lifetime.
    let arena_ref: &'static typed_arena::Arena<sink::ElementData> = unsafe {
        std::mem::transmute(arena.as_ref())
    };

    let sink = sink::Sink {
        ctx: ctx,
        arena: arena_ref,
        document: document,
        quirks_mode: Cell::new(QuirksMode::NoQuirks),
        pop_callback: pop_callback,
        append_callback: append_callback,
        get_data_callback: get_data_callback,
        parse_error_callback: parse_error_callback,
        create_element_callback: create_element_callback,
        create_comment_callback: create_comment_callback,
        append_doctype_to_document: append_doctype_to_document,
        add_attrs_if_missing_callback: add_attrs_if_missing_callback,
        get_template_contents_callback: get_template_contents_callback,
        remove_from_parent_callback: remove_from_parent_callback,
        reparent_children_callback: reparent_children_callback,
    };

    // Create a parser which implements TendrilSink for streaming parsing
    let parser = parse_document(sink, ParseOpts::default());

    let streaming_parser = Box::new(StreamingParser {
        arena,
        parser: Box::new(parser),
    });

    return Box::into_raw(streaming_parser) as *mut c_void;
}

#[no_mangle]
pub extern "C" fn html5ever_streaming_parser_feed(
    parser_ptr: *mut c_void,
    html: *const c_uchar,
    len: usize,
) {
    if parser_ptr.is_null() || html.is_null() || len == 0 {
        return;
    }

    let streaming_parser = unsafe { &mut *(parser_ptr as *mut StreamingParser) };
    let bytes = unsafe { std::slice::from_raw_parts(html, len) };

    // Convert bytes to UTF-8 string
    if let Ok(s) = std::str::from_utf8(bytes) {
        let tendril = StrTendril::from(s);

        // Feed the chunk to the parser
        // The Parser implements TendrilSink, so we can call process() on it
        let parser = streaming_parser.parser
            .downcast_mut::<Parser<sink::Sink>>()
            .expect("Invalid parser type");

        parser.process(tendril);
    }
}

#[no_mangle]
pub extern "C" fn html5ever_streaming_parser_finish(parser_ptr: *mut c_void) {
    if parser_ptr.is_null() {
        return;
    }

    let streaming_parser = unsafe { Box::from_raw(parser_ptr as *mut StreamingParser) };

    // Extract and finish the parser
    let parser = streaming_parser.parser
        .downcast::<Parser<sink::Sink>>()
        .expect("Invalid parser type");

    // Finish consumes the parser, which will call finish() on the sink
    parser.finish();

    // Note: The arena will be dropped here automatically
}

#[no_mangle]
pub extern "C" fn html5ever_streaming_parser_destroy(parser_ptr: *mut c_void) {
    if parser_ptr.is_null() {
        return;
    }

    // Drop the parser box without finishing
    // This is for cases where you want to cancel parsing
    unsafe {
        let _ = Box::from_raw(parser_ptr as *mut StreamingParser);
    }
}
