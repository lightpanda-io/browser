use std::ptr;
use std::cell::Cell;
use std::borrow::Cow;
use std::os::raw::{c_void};

use crate::types::*;

use html5ever::tendril::{StrTendril};
use html5ever::{Attribute, QualName};
use html5ever::interface::tree_builder::{ElementFlags, NodeOrText, QuirksMode, TreeSink};

type Arena<'arena> = &'arena typed_arena::Arena<ElementData>;

// Made public so it can be used from lib.rs
pub struct ElementData {
    pub qname: QualName,
    pub mathml_annotation_xml_integration_point: bool,
}
impl ElementData {
    fn new(qname: QualName, flags: ElementFlags) -> Self {
        return Self {
            qname: qname,
            mathml_annotation_xml_integration_point: flags.mathml_annotation_xml_integration_point,
        };
    }
}

pub struct Sink<'arena> {
    pub ctx: Ref,
    pub document: Ref,
    pub arena: Arena<'arena>,
    pub quirks_mode: Cell<QuirksMode>,
    pub pop_callback: PopCallback,
    pub append_callback: AppendCallback,
    pub get_data_callback: GetDataCallback,
    pub parse_error_callback: ParseErrorCallback,
    pub create_element_callback: CreateElementCallback,
    pub create_comment_callback: CreateCommentCallback,
    pub append_doctype_to_document: AppendDoctypeToDocumentCallback,
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
        let opaque = unsafe { (self.get_data_callback)(*target) };
        let data = opaque as *mut ElementData;
        return unsafe { &(*data).qname };
    }

    fn get_template_contents(&self, target: &Ref) -> Ref {
        _ = target;
        panic!("get_template_contents")
    }

    fn is_mathml_annotation_xml_integration_point(&self, target: &Ref) -> bool {
        let opaque = unsafe { (self.get_data_callback)(*target) };
        let data = opaque as *mut ElementData;
        return unsafe { (*data).mathml_annotation_xml_integration_point };
    }

    fn pop(&self, node: &Ref) {
        unsafe {
            (self.pop_callback)(self.ctx, *node);
        }
    }

    fn create_element(&self, name: QualName, attrs: Vec<Attribute>, flags: ElementFlags) -> Ref {
        let data = self.arena.alloc(ElementData::new(name.clone(), flags));

        unsafe {
            let mut c_attrs: Vec<CAttribute> = Vec::with_capacity(attrs.len());

            for attr in attrs.iter() {
                let v: &str = &attr.value;
                c_attrs.push(CAttribute {
                    name: CQualName::create(&attr.name),
                    value: StringSlice {
                        ptr: v.as_ptr(),
                        len: attr.value.len(),
                    },
                })
            }

            let mut attribute_iterator = CAttributeIterator { vec: attrs, pos: 0 };

            return (self.create_element_callback)(
                self.ctx,
                data as *mut _ as *mut c_void,
                CQualName::create(&name),
                &mut attribute_iterator as *mut _ as *mut c_void,
            );
        }
    }

    fn create_comment(&self, txt: StrTendril) -> Ref {
        let str = StringSlice{ ptr: txt.as_ptr(), len: txt.len()};
        unsafe {
            return (self.create_comment_callback)(self.ctx, str);
        }
    }

    fn create_pi(&self, target: StrTendril, data: StrTendril) -> Ref {
        _ = target;
        _ = data;
        panic!("create_pi");
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
                let static_slice: &'static [u8] = unsafe {
                    std::mem::transmute(byte_slice)
                };
                unsafe {
                    (self.append_callback)(self.ctx, *parent, CNodeOrText{
                        tag: 1,
                        node: ptr::null(),
                        text: StringSlice { ptr: static_slice.as_ptr(), len: static_slice.len()},
                     });
                };
            },
            NodeOrText::AppendNode(node) => {
               unsafe {
                    (self.append_callback)(self.ctx, *parent, CNodeOrText{
                        tag: 0,
                        node: node,
                        text: StringSlice::default()
                    });
                };
            }
        }
    }

    fn append_before_sibling(&self, sibling: &Ref, child: NodeOrText<Ref>) {
        _ = sibling;
        _ = child;
        panic!("append_before_sibling");
    }

    fn append_based_on_parent_node(
        &self,
        element: &Ref,
        prev_element: &Ref,
        child: NodeOrText<Ref>,
    ) {
        _ = element;
        _ = prev_element;
        _ = child;
        panic!("append_based_on_parent_node");
    }

    fn append_doctype_to_document(
        &self,
        name: StrTendril,
        public_id: StrTendril,
        system_id: StrTendril,
    ) {
        let name_str = StringSlice{ ptr: name.as_ptr(), len: name.len()};
        let public_id_str = StringSlice{ ptr: public_id.as_ptr(), len: public_id.len()};
        let system_id_str = StringSlice{ ptr: system_id.as_ptr(), len: system_id.len()};
        unsafe {
            (self.append_doctype_to_document)(self.ctx, name_str, public_id_str, system_id_str);
        }
    }

    fn add_attrs_if_missing(&self, target: &Ref, attrs: Vec<Attribute>) {
        _ = target;
        _ = attrs;
        panic!("add_attrs_if_missing");
    }

    fn remove_from_parent(&self, target: &Ref) {
        _ = target;
        panic!("remove_from_parent");
    }

    fn reparent_children(&self, node: &Ref, new_parent: &Ref) {
        _ = node;
        _ = new_parent;
        panic!("reparent_children");
    }
}
