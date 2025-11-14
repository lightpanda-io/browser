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

use std::ptr;
use html5ever::{QualName, Attribute};
use std::os::raw::{c_uchar, c_void};

pub type CreateElementCallback = unsafe extern "C" fn(
    ctx: Ref,
    data: *const c_void,
    name: CQualName,
    attributes: *mut c_void,
) -> Ref;

pub type CreateCommentCallback = unsafe extern "C" fn(
    ctx: Ref,
    str: StringSlice,
) -> Ref;

pub type AppendDoctypeToDocumentCallback = unsafe extern "C" fn(
    ctx: Ref,
    name: StringSlice,
    public_id: StringSlice,
    system_id: StringSlice,
) -> ();

pub type GetDataCallback = unsafe extern "C" fn(ctx: Ref) -> *mut c_void;

pub type AppendCallback = unsafe extern "C" fn(
    ctx: Ref,
    parent: Ref,
    node_or_text: CNodeOrText
) -> ();

pub type ParseErrorCallback = unsafe extern "C" fn(ctx: Ref, str: StringSlice) -> ();

pub type PopCallback = unsafe extern "C" fn(ctx: Ref, node: Ref) -> ();

pub type Ref = *const c_void;

#[repr(C)]
pub struct CNullable<T> {
    tag: u8, // 0 = None, 1 = Some
    value: T,
}
impl<T: Default> CNullable<T> {
    pub fn none() -> CNullable<T> {
        return Self{tag: 0, value: T::default()};
    }

    pub fn some(v: T) -> CNullable<T> {
        return Self{tag: 1, value: v};
    }
}

#[repr(C)]
pub struct Slice<T> {
    pub ptr: *const T,
    pub len: usize,
}
impl<T> Default for Slice<T> {
    fn default() -> Self {
        return Self{ptr: ptr::null(), len: 0};
    }
}

pub type StringSlice = Slice<c_uchar>;

#[repr(C)]
pub struct CQualName {
    prefix: CNullable<StringSlice>,
    ns: StringSlice,
    local: StringSlice,
}
impl CQualName {
    pub fn create(q: &QualName) -> Self {
        let ns = StringSlice { ptr: q.ns.as_ptr(), len: q.ns.len()};
        let local = StringSlice { ptr: q.local.as_ptr(), len: q.local.len()};
        let prefix = match &q.prefix {
            None => CNullable::<StringSlice>::none(),
            Some(prefix) => CNullable::<StringSlice>::some(StringSlice { ptr: prefix.as_ptr(), len: prefix.len()}),
        };
        return CQualName{
            // inner: q as *const _ as *const c_void,
            ns: ns,
            local: local,
            prefix: prefix,
        };
    }
}
impl Default for CQualName {
    fn default() -> Self {
        return Self{
            prefix: CNullable::<StringSlice>::none(),
            ns: StringSlice::default(),
            local: StringSlice::default(),
        };
    }
}

#[repr(C)]
pub struct CAttribute {
    pub name: CQualName,
    pub value: StringSlice,
}
impl Default for CAttribute {
    fn default() -> Self {
        return Self{name: CQualName::default(), value: StringSlice::default()};
    }
}

pub struct CAttributeIterator {
    pub vec: Vec<Attribute>,
    pub pos: usize,
}

#[repr(C)]
pub struct CNodeOrText {
    pub tag: u8, // 0 = node, 1 = text
    pub node: Ref,
    pub text: StringSlice,
}
