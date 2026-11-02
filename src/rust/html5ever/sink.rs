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

use std::borrow::Cow;
use std::cell::Cell;
use std::os::raw::c_void;
use std::ptr;

use crate::types::*;

use html5ever::interface::tree_builder::{ElementFlags, NodeOrText, QuirksMode, TreeSink};
use html5ever::tendril::StrTendril;
use html5ever::tokenizer::BufferQueue;
use html5ever::{local_name, ns, Attribute, QualName};

type Arena<'arena> = &'arena typed_arena::Arena<ElementData>;

// Made public so it can be used from lib.rs
pub struct ElementData {
    pub qname: QualName,
    pub mathml_annotation_xml_integration_point: bool,
    // Where the text of a <script> in a document starts.
    pub text_position: Option<TextPosition>,
}
impl ElementData {
    fn new(qname: QualName, flags: ElementFlags, text_position: Option<TextPosition>) -> Self {
        Self {
            qname: qname,
            mathml_annotation_xml_integration_point: flags.mathml_annotation_xml_integration_point,
            text_position: text_position,
        }
    }
}

// A document parse's input, for the position the tokenizer is at in it.
pub struct DocumentInput<'a> {
    text: &'a str,
    // The queue the tokenizer reads `text` from: what it hasn't read yet.
    unread: &'a BufferQueue,
    // Counting resumes from the previous position, or a minified document
    // (one long line) would be rescanned for each of its scripts.
    last: Cell<Counted>,
}

#[derive(Clone, Copy)]
struct Counted {
    offset: usize,
    line: usize,
    column: usize,
}

impl<'a> DocumentInput<'a> {
    pub fn new(text: &'a str, unread: &'a BufferQueue) -> Self {
        // Not a column: Chrome decodes a BOM away, the tokenizer reads past it.
        let bom_len = if text.starts_with('\u{feff}') { 3 } else { 0 };
        Self {
            text: text,
            unread: unread,
            last: Cell::new(Counted {
                offset: bom_len,
                line: 0,
                column: 0,
            }),
        }
    }

    // As in Chrome, a lone \r doesn't end a line.
    fn position(&self) -> Option<TextPosition> {
        let unread = self.unread.clone();
        let unread_len: usize = std::iter::from_fn(|| unread.pop_front())
            .map(|chunk| chunk.len())
            .sum();
        let read = self.text.len().checked_sub(unread_len)?;

        let last = self.last.get();
        let segment = self.text.as_bytes().get(last.offset..read)?;
        let counted = match segment.iter().rposition(|&b| b == b'\n') {
            Some(i) => Counted {
                offset: read,
                line: last.line + segment.iter().filter(|&&b| b == b'\n').count(),
                column: utf16_len(&segment[i + 1..]),
            },
            None => Counted {
                offset: read,
                line: last.line,
                column: last.column + utf16_len(segment),
            },
        };
        self.last.set(counted);

        Some(TextPosition {
            line: u32::try_from(counted.line).unwrap_or(u32::MAX),
            column: u32::try_from(counted.column).unwrap_or(u32::MAX),
        })
    }
}

fn utf16_len(utf8: &[u8]) -> usize {
    utf8.iter()
        .map(|&b| match b {
            0x80..=0xBF => 0, // continuation byte
            0xF0..=0xFF => 2, // outside the BMP: a surrogate pair
            _ => 1,
        })
        .sum()
}

// Mirrors Parser.ParsedNode (an extern struct). Every element Ref the tree
// builder hands back is one of these, created by create_element_callback.
#[repr(C)]
struct ParsedNode {
    _node: *const c_void,
    data: *const ElementData,
    _placed: bool,
    _root: *const c_void,
    _root_version: usize,
}

fn element_data<'a>(target: Ref) -> &'a ElementData {
    let data = unsafe { (*(target as *const ParsedNode)).data };
    debug_assert!(!data.is_null(), "element data requested for a non-element");
    return unsafe { &*data };
}

pub struct Sink<'arena> {
    pub ctx: Ref,
    pub document: Ref,
    pub arena: Arena<'arena>,
    pub quirks_mode: Cell<QuirksMode>,
    pub pop_callback: PopCallback,
    pub append_callback: AppendCallback,
    pub parse_error_callback: ParseErrorCallback,
    pub create_element_callback: CreateElementCallback,
    pub create_comment_callback: CreateCommentCallback,
    pub create_processing_instruction: CreateProcessingInstruction,
    pub append_doctype_to_document: AppendDoctypeToDocumentCallback,
    pub add_attrs_if_missing_callback: AddAttrsIfMissingCallback,
    pub get_template_contents_callback: GetTemplateContentsCallback,
    pub remove_from_parent_callback: RemoveFromParentCallback,
    pub reparent_children_callback: ReparentChildrenCallback,
    pub append_before_sibling_callback: AppendBeforeSiblingCallback,
    pub append_based_on_parent_node_callback: AppendBasedOnParentNodeCallback,
    pub attach_declarative_shadow_callback: AttachDeclarativeShadowCallback,
    pub allow_declarative_shadow: bool,
    // Only for the parse of a document from its source, not of a fragment
    // or of document.write() input.
    pub input: Option<DocumentInput<'arena>>,
}

impl<'arena> TreeSink for Sink<'arena> {
    type Handle = *const c_void;
    type Output = ();
    type ElemName<'a>
        = &'a QualName
    where
        Self: 'a;

    fn finish(self) -> () {
        return ();
    }

    fn parse_error(&self, err: Cow<'static, str>) {
        unsafe {
            (self.parse_error_callback)(
                self.ctx,
                StringSlice {
                    ptr: err.as_ptr(),
                    len: err.len(),
                },
            );
        }
    }

    fn get_document(&self) -> *const c_void {
        return self.document;
    }

    fn set_quirks_mode(&self, mode: QuirksMode) {
        self.quirks_mode.set(mode);
    }

    fn same_node(&self, x: &Ref, y: &Ref) -> bool {
        ptr::eq::<c_void>(*x, *y)
    }

    fn elem_name(&self, target: &Ref) -> Self::ElemName<'_> {
        return &element_data(*target).qname;
    }

    fn get_template_contents(&self, target: &Ref) -> Ref {
        unsafe {
            return (self.get_template_contents_callback)(self.ctx, *target);
        }
    }

    fn is_mathml_annotation_xml_integration_point(&self, target: &Ref) -> bool {
        return element_data(*target).mathml_annotation_xml_integration_point;
    }

    fn pop(&self, node: &Ref) {
        unsafe {
            (self.pop_callback)(self.ctx, *node);
        }
    }

    fn create_element(&self, name: QualName, attrs: Vec<Attribute>, flags: ElementFlags) -> Ref {
        // Browsers compile an inline script with the document position of its
        // text, which starts right after the start tag the tokenizer just read.
        let text_position = match &self.input {
            Some(input) if name.ns == ns!(html) && name.local == local_name!("script") => {
                input.position()
            }
            _ => None,
        };
        let data = self
            .arena
            .alloc(ElementData::new(name.clone(), flags, text_position));

        unsafe {
            let mut attribute_iterator = CAttributeIterator { vec: attrs, pos: 0 };

            (self.create_element_callback)(
                self.ctx,
                data as *mut _ as *mut c_void,
                CQualName::create(&name),
                &mut attribute_iterator as *mut _ as *mut c_void,
            )
        }
    }

    fn create_comment(&self, txt: StrTendril) -> Ref {
        let str = StringSlice {
            ptr: txt.as_ptr(),
            len: txt.len(),
        };
        unsafe {
            return (self.create_comment_callback)(self.ctx, str);
        }
    }

    fn create_pi(&self, target: StrTendril, data: StrTendril) -> Ref {
        let str_target = StringSlice {
            ptr: target.as_ptr(),
            len: target.len(),
        };
        let str_data = StringSlice {
            ptr: data.as_ptr(),
            len: data.len(),
        };
        unsafe {
            return (self.create_processing_instruction)(self.ctx, str_target, str_data);
        }
    }

    fn append(&self, parent: &Ref, child: NodeOrText<Ref>) {
        match child {
            NodeOrText::AppendText(ref t) => {
                // The child exists for the duration of the append_callback call,
                // but sometimes the memory on the Zig side, in append_callback,
                // is zeroed. If you try to refactor this code a bit, and do:
                //   unsafe {
                //       (self.append_callback)(self.ctx, *parent, CNodeOrText::create(child));
                //   }
                // Where CNodeOrText::create returns the property CNodeOrText,
                // you'll occasionally see that zeroed memory. Makes no sense to
                // me, but a far as I can tell, this version works.
                let byte_slice = t.as_ref().as_bytes();
                let static_slice: &'static [u8] = unsafe { std::mem::transmute(byte_slice) };
                unsafe {
                    (self.append_callback)(
                        self.ctx,
                        *parent,
                        CNodeOrText {
                            tag: 1,
                            node: ptr::null(),
                            text: StringSlice {
                                ptr: static_slice.as_ptr(),
                                len: static_slice.len(),
                            },
                        },
                    );
                };
            }
            NodeOrText::AppendNode(node) => {
                unsafe {
                    (self.append_callback)(
                        self.ctx,
                        *parent,
                        CNodeOrText {
                            tag: 0,
                            node: node,
                            text: StringSlice::default(),
                        },
                    );
                };
            }
        }
    }

    fn append_before_sibling(&self, sibling: &Ref, child: NodeOrText<Ref>) {
        match child {
            NodeOrText::AppendText(ref t) => {
                let byte_slice = t.as_ref().as_bytes();
                let static_slice: &'static [u8] = unsafe { std::mem::transmute(byte_slice) };
                unsafe {
                    (self.append_before_sibling_callback)(
                        self.ctx,
                        *sibling,
                        CNodeOrText {
                            tag: 1,
                            node: ptr::null(),
                            text: StringSlice {
                                ptr: static_slice.as_ptr(),
                                len: static_slice.len(),
                            },
                        },
                    );
                };
            }
            NodeOrText::AppendNode(node) => {
                unsafe {
                    (self.append_before_sibling_callback)(
                        self.ctx,
                        *sibling,
                        CNodeOrText {
                            tag: 0,
                            node: node,
                            text: StringSlice::default(),
                        },
                    );
                };
            }
        }
    }

    fn append_based_on_parent_node(
        &self,
        element: &Ref,
        prev_element: &Ref,
        child: NodeOrText<Ref>,
    ) {
        match child {
            NodeOrText::AppendText(ref t) => {
                let byte_slice = t.as_ref().as_bytes();
                let static_slice: &'static [u8] = unsafe { std::mem::transmute(byte_slice) };
                unsafe {
                    (self.append_based_on_parent_node_callback)(
                        self.ctx,
                        *element,
                        *prev_element,
                        CNodeOrText {
                            tag: 1,
                            node: ptr::null(),
                            text: StringSlice {
                                ptr: static_slice.as_ptr(),
                                len: static_slice.len(),
                            },
                        },
                    );
                };
            }
            NodeOrText::AppendNode(node) => {
                unsafe {
                    (self.append_based_on_parent_node_callback)(
                        self.ctx,
                        *element,
                        *prev_element,
                        CNodeOrText {
                            tag: 0,
                            node: node,
                            text: StringSlice::default(),
                        },
                    );
                };
            }
        }
    }

    fn append_doctype_to_document(
        &self,
        name: StrTendril,
        public_id: StrTendril,
        system_id: StrTendril,
    ) {
        let name_str = StringSlice {
            ptr: name.as_ptr(),
            len: name.len(),
        };
        let public_id_str = StringSlice {
            ptr: public_id.as_ptr(),
            len: public_id.len(),
        };
        let system_id_str = StringSlice {
            ptr: system_id.as_ptr(),
            len: system_id.len(),
        };
        unsafe {
            (self.append_doctype_to_document)(self.ctx, name_str, public_id_str, system_id_str);
        }
    }

    fn add_attrs_if_missing(&self, target: &Ref, attrs: Vec<Attribute>) {
        unsafe {
            let mut attribute_iterator = CAttributeIterator { vec: attrs, pos: 0 };

            (self.add_attrs_if_missing_callback)(
                self.ctx,
                *target,
                &mut attribute_iterator as *mut _ as *mut c_void,
            );
        }
    }

    fn remove_from_parent(&self, target: &Ref) {
        unsafe {
            (self.remove_from_parent_callback)(self.ctx, *target);
        }
    }

    fn reparent_children(&self, node: &Ref, new_parent: &Ref) {
        unsafe {
            (self.reparent_children_callback)(self.ctx, *node, *new_parent);
        }
    }

    fn allow_declarative_shadow_roots(&self, _intended_parent: &Ref) -> bool {
        self.allow_declarative_shadow
    }

    fn attach_declarative_shadow(
        &self,
        location: &Ref,
        template: &Ref,
        attrs: &[Attribute],
    ) -> bool {
        // html5ever only calls this when shadowrootmode is "open" or "closed",
        // so anything other than "open" is treated as "closed".
        let mode_is_open = attrs
            .iter()
            .find(|a| a.name.local == local_name!("shadowrootmode"))
            .map(|a| a.value.as_ref() == "open")
            .unwrap_or(true);
        unsafe {
            (self.attach_declarative_shadow_callback)(
                self.ctx,
                *location,
                *template,
                if mode_is_open { 1 } else { 0 },
            ) != 0
        }
    }
}
