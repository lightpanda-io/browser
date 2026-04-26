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

mod sink;
mod types;

#[cfg(debug_assertions)]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

use std::cell::Cell;
use std::os::raw::{c_uchar, c_void};
use types::*;

use encoding_rs::Encoding;
use html5ever::interface::tree_builder::QuirksMode;
use html5ever::tendril::{StrTendril, TendrilSink};
use html5ever::{ns, parse_document, parse_fragment, LocalName, ParseOpts, Parser, QualName};

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
    create_processing_instruction: CreateProcessingInstruction,
    append_doctype_to_document: AppendDoctypeToDocumentCallback,
    add_attrs_if_missing_callback: AddAttrsIfMissingCallback,
    get_template_contents_callback: GetTemplateContentsCallback,
    remove_from_parent_callback: RemoveFromParentCallback,
    reparent_children_callback: ReparentChildrenCallback,
    append_before_sibling_callback: AppendBeforeSiblingCallback,
    append_based_on_parent_node_callback: AppendBasedOnParentNodeCallback,
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
        create_processing_instruction: create_processing_instruction,
        append_doctype_to_document: append_doctype_to_document,
        add_attrs_if_missing_callback: add_attrs_if_missing_callback,
        get_template_contents_callback: get_template_contents_callback,
        remove_from_parent_callback: remove_from_parent_callback,
        reparent_children_callback: reparent_children_callback,
        append_before_sibling_callback: append_before_sibling_callback,
        append_based_on_parent_node_callback: append_based_on_parent_node_callback,
    };

    let bytes = unsafe { std::slice::from_raw_parts(html, len) };
    parse_document(sink, Default::default())
        .from_utf8()
        .one(bytes);
}

/// Parse an HTML document with encoding conversion.
/// If charset is provided, converts from that encoding to UTF-8 before parsing.
/// Uses Cow<str> internally so no allocation if content is already valid UTF-8.
#[no_mangle]
pub extern "C" fn html5ever_parse_document_with_encoding(
    html: *mut c_uchar,
    len: usize,
    charset: *const c_uchar,
    charset_len: usize,
    document: Ref,
    ctx: Ref,
    create_element_callback: CreateElementCallback,
    get_data_callback: GetDataCallback,
    append_callback: AppendCallback,
    parse_error_callback: ParseErrorCallback,
    pop_callback: PopCallback,
    create_comment_callback: CreateCommentCallback,
    create_processing_instruction: CreateProcessingInstruction,
    append_doctype_to_document: AppendDoctypeToDocumentCallback,
    add_attrs_if_missing_callback: AddAttrsIfMissingCallback,
    get_template_contents_callback: GetTemplateContentsCallback,
    remove_from_parent_callback: RemoveFromParentCallback,
    reparent_children_callback: ReparentChildrenCallback,
    append_before_sibling_callback: AppendBeforeSiblingCallback,
    append_based_on_parent_node_callback: AppendBasedOnParentNodeCallback,
) -> () {
    if html.is_null() || len == 0 {
        return ();
    }

    let input = unsafe { std::slice::from_raw_parts(html, len) };
    let charset_bytes = if charset.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(charset, charset_len) }
    };

    // Decode to UTF-8. Returns Cow<str> - no allocation if already valid UTF-8.
    let encoding = Encoding::for_label(charset_bytes).unwrap_or(encoding_rs::UTF_8);
    let (decoded, _, _) = encoding.decode(input);

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
        create_processing_instruction: create_processing_instruction,
        append_doctype_to_document: append_doctype_to_document,
        add_attrs_if_missing_callback: add_attrs_if_missing_callback,
        get_template_contents_callback: get_template_contents_callback,
        remove_from_parent_callback: remove_from_parent_callback,
        reparent_children_callback: reparent_children_callback,
        append_before_sibling_callback: append_before_sibling_callback,
        append_based_on_parent_node_callback: append_based_on_parent_node_callback,
    };

    // Parse directly from decoded string
    parse_document(sink, Default::default())
        .one(StrTendril::from(decoded.as_ref()));
}

// === Encoding API for TextDecoder ===

/// Result of encoding label lookup
#[repr(C)]
pub struct EncodingInfo {
    /// 0 = not found, 1 = found
    pub found: u8,
    /// Opaque handle to the encoding (actually &'static Encoding)
    pub handle: *const c_void,
    /// Length of canonical name
    pub name_len: usize,
    /// Pointer to canonical encoding name (static, lowercase)
    pub name_ptr: *const c_uchar,
}

/// Look up an encoding by its label (case-insensitive, whitespace-trimmed)
#[no_mangle]
pub extern "C" fn encoding_for_label(
    label: *const c_uchar,
    label_len: usize,
) -> EncodingInfo {
    if label.is_null() || label_len == 0 {
        return EncodingInfo {
            found: 0,
            name_len: 0,
            handle: std::ptr::null(),
            name_ptr: std::ptr::null(),
        };
    }

    let label_bytes = unsafe { std::slice::from_raw_parts(label, label_len) };

    match Encoding::for_label(label_bytes) {
        Some(encoding) => {
            let name = encoding.name();
            EncodingInfo {
                found: 1,
                name_len: name.len(),
                name_ptr: name.as_ptr(),
                handle: encoding as *const _ as *const c_void,
            }
        }
        None => EncodingInfo {
            found: 0,
            name_len: 0,
            name_ptr: std::ptr::null(),
            handle: std::ptr::null(),
        },
    }
}

/// Calculate maximum UTF-8 buffer size needed for decoding
#[no_mangle]
pub extern "C" fn encoding_max_utf8_buffer_length(
    handle: *const c_void,
    input_len: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let encoding: &'static Encoding = unsafe { &*(handle as *const Encoding) };
    let decoder = encoding.new_decoder();
    decoder.max_utf8_buffer_length(input_len).unwrap_or(0)
}

/// Result of decoding operation
#[repr(C)]
pub struct DecodeResult {
    /// 0 = no errors, 1 = had malformed sequences (replaced with U+FFFD)
    pub had_errors: u8,
    /// Number of input bytes consumed
    pub bytes_read: usize,
    /// Number of UTF-8 bytes written to output buffer
    pub bytes_written: usize,
}

/// Decode bytes from source encoding to UTF-8
/// For streaming, set is_last=0; for final/complete decode, set is_last=1
#[no_mangle]
pub extern "C" fn encoding_decode(
    handle: *const c_void,
    input: *const c_uchar,
    input_len: usize,
    output: *mut c_uchar,
    output_len: usize,
    is_last: u8,
) -> DecodeResult {
    if handle.is_null() || output.is_null() {
        return DecodeResult {
            had_errors: 1,
            bytes_read: 0,
            bytes_written: 0,
        };
    }

    let encoding: &'static Encoding = unsafe { &*(handle as *const Encoding) };
    let input_bytes = if input.is_null() || input_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(input, input_len) }
    };
    let output_slice = unsafe { std::slice::from_raw_parts_mut(output, output_len) };

    let mut decoder = encoding.new_decoder();
    let last = is_last != 0;

    let (result, bytes_read, bytes_written, had_errors) =
        decoder.decode_to_utf8(input_bytes, output_slice, last);

    // If output buffer was too small, we still report what we could process
    let _ = result; // CoderResult::InputEmpty or CoderResult::OutputFull

    DecodeResult {
        had_errors: if had_errors { 1 } else { 0 },
        bytes_read,
        bytes_written,
    }
}

// === Streaming Decoder API ===

use encoding_rs::Decoder;

/// Create a streaming decoder that maintains state across calls
#[no_mangle]
pub extern "C" fn encoding_decoder_new(handle: *const c_void) -> *mut c_void {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let encoding: &'static Encoding = unsafe { &*(handle as *const Encoding) };
    let decoder = Box::new(encoding.new_decoder());
    Box::into_raw(decoder) as *mut c_void
}

/// Decode using a streaming decoder (maintains state for incomplete sequences)
#[no_mangle]
pub extern "C" fn encoding_decoder_decode(
    decoder_ptr: *mut c_void,
    input: *const c_uchar,
    input_len: usize,
    output: *mut c_uchar,
    output_len: usize,
    is_last: u8,
) -> DecodeResult {
    if decoder_ptr.is_null() || output.is_null() {
        return DecodeResult {
            had_errors: 1,
            bytes_read: 0,
            bytes_written: 0,
        };
    }

    let decoder: &mut Decoder = unsafe { &mut *(decoder_ptr as *mut Decoder) };
    let input_bytes = if input.is_null() || input_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(input, input_len) }
    };
    let output_slice = unsafe { std::slice::from_raw_parts_mut(output, output_len) };

    let last = is_last != 0;
    let (result, bytes_read, bytes_written, had_errors) =
        decoder.decode_to_utf8(input_bytes, output_slice, last);

    let _ = result;

    DecodeResult {
        had_errors: if had_errors { 1 } else { 0 },
        bytes_read,
        bytes_written,
    }
}

/// Free a streaming decoder
#[no_mangle]
pub extern "C" fn encoding_decoder_free(decoder_ptr: *mut c_void) {
    if !decoder_ptr.is_null() {
        unsafe {
            drop(Box::from_raw(decoder_ptr as *mut Decoder));
        }
    }
}

// === Encoding API (UTF-8 to legacy encoding with NCR fallback) ===

/// Result of encoding operation
#[repr(C)]
pub struct EncodeResult {
    /// 0 = success, 1 = output buffer too small
    pub status: u8,
    /// Number of input bytes consumed
    pub bytes_read: usize,
    /// Number of bytes written to output buffer
    pub bytes_written: usize,
}

/// Encode UTF-8 to a legacy encoding, replacing unencodable characters with
/// HTML decimal numeric character references (&#codepoint;).
///
/// This is used for URL query string encoding per WHATWG URL spec.
/// encoding_rs's encode_from_utf8 already produces NCRs for unmappable chars.
#[no_mangle]
pub extern "C" fn encoding_encode_with_ncr(
    handle: *const c_void,
    input: *const c_uchar,
    input_len: usize,
    output: *mut c_uchar,
    output_capacity: usize,
) -> EncodeResult {
    if handle.is_null() || output.is_null() {
        return EncodeResult {
            status: 1,
            bytes_read: 0,
            bytes_written: 0,
        };
    }

    let encoding: &'static Encoding = unsafe { &*(handle as *const Encoding) };

    let input_str = if input.is_null() || input_len == 0 {
        ""
    } else {
        let bytes = unsafe { std::slice::from_raw_parts(input, input_len) };
        match std::str::from_utf8(bytes) {
            Ok(s) => s,
            Err(_) => {
                return EncodeResult {
                    status: 1,
                    bytes_read: 0,
                    bytes_written: 0,
                };
            }
        }
    };

    // For UTF-8 encoding, just copy directly (no NCR needed)
    if encoding == encoding_rs::UTF_8 {
        if input_len > output_capacity {
            return EncodeResult {
                bytes_read: 0,
                bytes_written: 0,
                status: 1,
            };
        }
        let output_slice = unsafe { std::slice::from_raw_parts_mut(output, output_capacity) };
        output_slice[..input_len].copy_from_slice(input_str.as_bytes());
        return EncodeResult {
            bytes_read: input_len,
            bytes_written: input_len,
            status: 0,
        };
    }

    let output_slice = unsafe { std::slice::from_raw_parts_mut(output, output_capacity) };
    let mut encoder = encoding.new_encoder();

    // encode_from_utf8 automatically produces NCRs for unmappable characters
    let (result, bytes_read, bytes_written, _had_unmappables) =
        encoder.encode_from_utf8(input_str, output_slice, true);

    match result {
        encoding_rs::CoderResult::InputEmpty => EncodeResult {
            bytes_read,
            bytes_written,
            status: 0,
        },
        encoding_rs::CoderResult::OutputFull => EncodeResult {
            bytes_read,
            bytes_written,
            status: 1,
        },
    }
}

/// Calculate maximum output buffer size needed for encoding with NCR fallback.
/// Worst case: every character becomes &#codepoint; where codepoint is up to 7 digits.
#[no_mangle]
pub extern "C" fn encoding_max_encode_buffer_length(
    handle: *const c_void,
    input_len: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let encoding: &'static Encoding = unsafe { &*(handle as *const Encoding) };
    let encoder = encoding.new_encoder();
    // This returns the max buffer size accounting for NCR expansion
    encoder
        .max_buffer_length_from_utf8_if_no_unmappables(input_len)
        .map(|len| {
            // Add extra space for potential NCRs (each char could become &#nnnnnn; = 10 bytes)
            // But realistically, most chars are mappable, so add 2x as safety margin
            len.saturating_mul(2)
        })
        .unwrap_or(input_len * 10)
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
    create_processing_instruction: CreateProcessingInstruction,
    append_doctype_to_document: AppendDoctypeToDocumentCallback,
    add_attrs_if_missing_callback: AddAttrsIfMissingCallback,
    get_template_contents_callback: GetTemplateContentsCallback,
    remove_from_parent_callback: RemoveFromParentCallback,
    reparent_children_callback: ReparentChildrenCallback,
    append_before_sibling_callback: AppendBeforeSiblingCallback,
    append_based_on_parent_node_callback: AppendBasedOnParentNodeCallback,
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
        create_processing_instruction: create_processing_instruction,
        append_doctype_to_document: append_doctype_to_document,
        add_attrs_if_missing_callback: add_attrs_if_missing_callback,
        get_template_contents_callback: get_template_contents_callback,
        remove_from_parent_callback: remove_from_parent_callback,
        reparent_children_callback: reparent_children_callback,
        append_before_sibling_callback: append_before_sibling_callback,
        append_based_on_parent_node_callback: append_based_on_parent_node_callback,
    };

    let bytes = unsafe { std::slice::from_raw_parts(html, len) };
    parse_fragment(
        sink,
        Default::default(),
        QualName::new(None, ns!(html), LocalName::from("body")),
        vec![], // attributes
        false,  // context_element_allows_scripting
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
    CNullable::<CAttribute>::some(CAttribute {
        name: CQualName::create(&attr.name),
        value: StringSlice {
            ptr: attr.value.as_ptr(),
            len: attr.value.len(),
        },
    })
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
    use tikv_jemalloc_ctl::{epoch, stats};

    // many statistics are cached and only updated when the epoch is advanced.
    drop(epoch::advance());

    Memory {
        resident: stats::resident::read().unwrap_or(0),
        allocated: stats::allocated::read().unwrap_or(0),
    }
}

// Streaming parser API
// The Parser type from html5ever implements TendrilSink and supports streaming
pub struct StreamingParser {
    #[allow(dead_code)]
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
    create_processing_instruction: CreateProcessingInstruction,
    append_doctype_to_document: AppendDoctypeToDocumentCallback,
    add_attrs_if_missing_callback: AddAttrsIfMissingCallback,
    get_template_contents_callback: GetTemplateContentsCallback,
    remove_from_parent_callback: RemoveFromParentCallback,
    reparent_children_callback: ReparentChildrenCallback,
    append_before_sibling_callback: AppendBeforeSiblingCallback,
    append_based_on_parent_node_callback: AppendBasedOnParentNodeCallback,
) -> *mut c_void {
    let arena = Box::new(typed_arena::Arena::new());

    // SAFETY: We're creating a self-referential structure here.
    // The arena is stored in the StreamingParser and lives as long as the parser.
    // The sink contains a reference to the arena that's valid for the parser's lifetime.
    let arena_ref: &'static typed_arena::Arena<sink::ElementData> =
        unsafe { std::mem::transmute(arena.as_ref()) };

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
        create_processing_instruction: create_processing_instruction,
        append_doctype_to_document: append_doctype_to_document,
        add_attrs_if_missing_callback: add_attrs_if_missing_callback,
        get_template_contents_callback: get_template_contents_callback,
        remove_from_parent_callback: remove_from_parent_callback,
        reparent_children_callback: reparent_children_callback,
        append_before_sibling_callback: append_before_sibling_callback,
        append_based_on_parent_node_callback: append_based_on_parent_node_callback,
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
) -> i32 {
    if parser_ptr.is_null() || html.is_null() || len == 0 {
        return 0;
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let streaming_parser = unsafe { &mut *(parser_ptr as *mut StreamingParser) };
        let bytes = unsafe { std::slice::from_raw_parts(html, len) };

        // Convert bytes to UTF-8 string
        if let Ok(s) = std::str::from_utf8(bytes) {
            let tendril = StrTendril::from(s);

            // Feed the chunk to the parser
            // The Parser implements TendrilSink, so we can call process() on it
            let parser = streaming_parser
                .parser
                .downcast_mut::<Parser<sink::Sink>>()
                .expect("Invalid parser type");

            parser.process(tendril);
        }
    }));

    match result {
        Ok(_) => 0,   // Success
        Err(_) => -1, // Panic occurred
    }
}

#[no_mangle]
pub extern "C" fn html5ever_streaming_parser_finish(parser_ptr: *mut c_void) {
    if parser_ptr.is_null() {
        return;
    }

    let streaming_parser = unsafe { Box::from_raw(parser_ptr as *mut StreamingParser) };

    // Extract and finish the parser
    let parser = streaming_parser
        .parser
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
        drop(Box::from_raw(parser_ptr as *mut StreamingParser));
    }
}

#[no_mangle]
pub extern "C" fn xml5ever_parse_document(
    xml: *mut c_uchar,
    len: usize,
    document: Ref,
    ctx: Ref,
    create_element_callback: CreateElementCallback,
    get_data_callback: GetDataCallback,
    append_callback: AppendCallback,
    parse_error_callback: ParseErrorCallback,
    pop_callback: PopCallback,
    create_comment_callback: CreateCommentCallback,
    create_processing_instruction: CreateProcessingInstruction,
    append_doctype_to_document: AppendDoctypeToDocumentCallback,
    add_attrs_if_missing_callback: AddAttrsIfMissingCallback,
    get_template_contents_callback: GetTemplateContentsCallback,
    remove_from_parent_callback: RemoveFromParentCallback,
    reparent_children_callback: ReparentChildrenCallback,
    append_before_sibling_callback: AppendBeforeSiblingCallback,
    append_based_on_parent_node_callback: AppendBasedOnParentNodeCallback,
) -> () {
    if xml.is_null() || len == 0 {
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
        create_processing_instruction: create_processing_instruction,
        append_doctype_to_document: append_doctype_to_document,
        add_attrs_if_missing_callback: add_attrs_if_missing_callback,
        get_template_contents_callback: get_template_contents_callback,
        remove_from_parent_callback: remove_from_parent_callback,
        reparent_children_callback: reparent_children_callback,
        append_before_sibling_callback: append_before_sibling_callback,
        append_based_on_parent_node_callback: append_based_on_parent_node_callback,
    };

    let bytes = unsafe { std::slice::from_raw_parts(xml, len) };
    xml5ever::driver::parse_document(sink, xml5ever::driver::XmlParseOpts::default())
        .from_utf8()
        .one(bytes);
}
