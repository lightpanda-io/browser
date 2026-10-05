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

// A preload scanner: a lightweight tokenizer-only pass over a document that
// reports fetchable script resources, so downloads can start before the tree
// builder (which stalls on every blocking <script src>) reaches them. Purely
// a hint source — it builds no tree and a wrong guess only costs a fetch.
// Same idea as Servo's dom/servoparser/prefetch.rs.

use std::cell::Cell;
use std::os::raw::{c_uchar, c_void};

use encoding_rs::Encoding;
use html5ever::tendril::StrTendril;
use html5ever::tokenizer::states::RawKind;
use html5ever::tokenizer::{
    BufferQueue, Tag, TagKind, Token, TokenSink, TokenSinkResult, Tokenizer, TokenizerOpts,
};
use html5ever::{local_name, ns, Attribute, LocalName};

// Keep in sync with PrescanResource in src/browser/parser/html5ever.zig.
const KIND_SCRIPT: u32 = 0;
const KIND_MODULE: u32 = 1;
const KIND_BASE: u32 = 2;

pub type PrescanCallback =
    extern "C" fn(ctx: *mut c_void, kind: u32, url: *const c_uchar, url_len: usize);

struct PrescanSink {
    ctx: *mut c_void,
    callback: PrescanCallback,
    // Only the first <base href> counts, per spec.
    base_seen: Cell<bool>,
    // Scripts inside <template> are inert until cloned; don't fetch them.
    template_depth: Cell<u32>,
}

impl PrescanSink {
    fn attr<'a>(tag: &'a Tag, name: &LocalName) -> Option<&'a Attribute> {
        tag.attrs
            .iter()
            .find(|a| a.name.ns == ns!() && a.name.local == *name)
    }

    fn emit(&self, kind: u32, url: &str) {
        (self.callback)(self.ctx, kind, url.as_ptr(), url.len());
    }

    fn scan_script(&self, tag: &Tag) {
        // Mirrors ScriptManager.addFromElement: nomodule scripts are skipped,
        // and only classic javascript and module types are fetched.
        if Self::attr(tag, &local_name!("nomodule")).is_some() {
            return;
        }
        let Some(src) = Self::attr(tag, &local_name!("src")) else {
            return;
        };
        if src.value.is_empty() {
            return;
        }
        let kind = match Self::attr(tag, &local_name!("type")) {
            None => KIND_SCRIPT,
            Some(attr) => {
                let t: &str = &attr.value;
                if t.is_empty()
                    || t.eq_ignore_ascii_case("application/javascript")
                    || t.eq_ignore_ascii_case("text/javascript")
                {
                    KIND_SCRIPT
                } else if t.eq_ignore_ascii_case("module") {
                    KIND_MODULE
                } else {
                    return;
                }
            }
        };
        self.emit(kind, &src.value);
    }
}

impl TokenSink for PrescanSink {
    type Handle = ();

    fn process_token(&self, token: Token, _line_number: u64) -> TokenSinkResult<()> {
        let Token::TagToken(tag) = token else {
            return TokenSinkResult::Continue;
        };

        if tag.kind == TagKind::EndTag {
            if tag.name == local_name!("template") {
                let depth = self.template_depth.get();
                self.template_depth.set(depth.saturating_sub(1));
            }
            return TokenSinkResult::Continue;
        }

        if tag.name == local_name!("script") {
            if self.template_depth.get() == 0 {
                self.scan_script(&tag);
            }
            // The tokenizer has no tree builder giving it state feedback, so
            // the sink must request the script-data state itself or the
            // script body would be tokenized as markup.
            return TokenSinkResult::RawData(RawKind::ScriptData);
        }
        if tag.name == local_name!("base") {
            if !self.base_seen.get() {
                if let Some(href) = Self::attr(&tag, &local_name!("href")) {
                    self.base_seen.set(true);
                    self.emit(KIND_BASE, &href.value);
                }
            }
            return TokenSinkResult::Continue;
        }
        if tag.name == local_name!("template") {
            self.template_depth.set(self.template_depth.get() + 1);
            return TokenSinkResult::Continue;
        }
        // The remaining raw-text/rcdata elements: their content must not be
        // tokenized as markup, or text mentioning "<script src=…>" (a style
        // rule, a <noscript> fallback, an <iframe> srcdoc-ish body) would
        // produce phantom fetches. noscript is raw text because scripting is
        // enabled in this browser.
        if tag.name == local_name!("style")
            || tag.name == local_name!("noscript")
            || tag.name == local_name!("iframe")
            || tag.name == local_name!("xmp")
            || tag.name == local_name!("noembed")
            || tag.name == local_name!("noframes")
        {
            return TokenSinkResult::RawData(RawKind::Rawtext);
        }
        if tag.name == local_name!("title") || tag.name == local_name!("textarea") {
            return TokenSinkResult::RawData(RawKind::Rcdata);
        }
        if tag.name == local_name!("plaintext") {
            return TokenSinkResult::Plaintext;
        }
        TokenSinkResult::Continue
    }
}

/// Tokenize the (fully buffered) document and report each fetchable script
/// resource through `callback`: raw (unresolved) src values for classic and
/// module scripts, plus the first <base href> so the caller can resolve
/// subsequent URLs the way the real parse will.
#[no_mangle]
pub extern "C" fn html5ever_prescan(
    html: *const c_uchar,
    len: usize,
    charset: *const c_uchar,
    charset_len: usize,
    ctx: *mut c_void,
    callback: PrescanCallback,
) {
    if html.is_null() || len == 0 {
        return;
    }
    let input = unsafe { std::slice::from_raw_parts(html, len) };
    let charset_bytes: &[u8] = if charset.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(charset, charset_len) }
    };

    // No allocation when the content is already valid UTF-8.
    let encoding = Encoding::for_label(charset_bytes).unwrap_or(encoding_rs::UTF_8);
    let (decoded, _, _) = encoding.decode(input);

    // A panic must not unwind across the FFI boundary; hints are best-effort,
    // so just stop scanning.
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let sink = PrescanSink {
            ctx,
            callback,
            base_seen: Cell::new(false),
            template_depth: Cell::new(0),
        };
        let tokenizer = Tokenizer::new(sink, TokenizerOpts::default());
        let queue = BufferQueue::default();
        queue.push_back(StrTendril::from(decoded.as_ref()));
        // The sink never returns TokenSinkResult::Script, so one feed
        // consumes the whole buffer.
        let _ = tokenizer.feed(&queue);
        tokenizer.end();
    }));
}
