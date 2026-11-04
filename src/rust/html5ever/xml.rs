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

use std::cell::{Cell, RefCell};

use html5ever::{namespace_prefix, ns, Attribute};

use crate::types::CreateCDATASectionCallback;

// xml5ever drops namespace declarations while binding names, and exposes
// CDATA as character tokens. Keep the DOM information its TreeSink lacks.
pub struct XmlState {
    namespace_attrs: RefCell<Vec<Attribute>>,
    pub creating_cdata: Cell<bool>,
    pub create_cdata: Option<CreateCDATASectionCallback>,
}

impl XmlState {
    pub fn new(create_cdata: Option<CreateCDATASectionCallback>) -> Self {
        Self {
            namespace_attrs: RefCell::new(Vec::new()),
            creating_cdata: Cell::new(false),
            create_cdata,
        }
    }

    pub fn preserve_namespaces(&self, attrs: &[Attribute]) {
        let mut declarations = self.namespace_attrs.borrow_mut();
        declarations.clear();
        // The tokenizer prepends each declaration, reversing their order.
        for attr in attrs.iter().rev() {
            if attr.name.prefix == Some(namespace_prefix!("xmlns"))
                || (attr.name.prefix.is_none() && &*attr.name.local == "xmlns")
            {
                let mut attr = attr.clone();
                attr.name.ns = ns!(xmlns);
                declarations.push(attr);
            }
        }
    }

    pub fn restore_namespaces(&self, attrs: Vec<Attribute>) -> Vec<Attribute> {
        let mut declarations = self.namespace_attrs.take();
        if declarations.is_empty() {
            return attrs;
        }
        declarations.extend(attrs);
        declarations
    }
}

// Find a complete CDATA section in markup, skipping comments, processing
// instructions and quoted attributes. This only locates feed boundaries:
// every byte still goes through xml5ever for validation and CR/LF handling.
// Incomplete markup is left to the tokenizer's normal EOF/error handling.
pub fn next_cdata(text: &str, mut offset: usize) -> Option<(usize, usize)> {
    while let Some(relative) = text[offset..].find('<') {
        let start = offset + relative;
        let rest = &text[start..];
        if let Some(content) = rest.strip_prefix("<![CDATA[") {
            let end = start + 9 + content.find("]]>")? + 3;
            return Some((start, end));
        }
        if let Some(content) = rest.strip_prefix("<!--") {
            offset = start + 4 + content.find("-->")? + 3;
        } else if let Some(content) = rest.strip_prefix("<?") {
            offset = start + 2 + content.find("?>")? + 2;
        } else {
            let mut quote = None;
            offset = text.len();
            for (index, byte) in rest.bytes().enumerate().skip(1) {
                match quote {
                    Some(q) if byte == q => quote = None,
                    Some(_) => {}
                    None if byte == b'\'' || byte == b'"' => quote = Some(byte),
                    None if byte == b'>' => {
                        offset = start + index + 1;
                        break;
                    }
                    None => {}
                }
            }
        }
    }
    None
}
