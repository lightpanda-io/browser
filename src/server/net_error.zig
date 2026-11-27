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

// Chrome's net errors (net::ERR_*) for transfer errors. CDP reports them,
// and so does BiDi: chromium-bidi puts them in network.fetchError.

// Chrome's net error for a transfer error, net::ERR_FAILED when there's no
// better one.
pub fn netError(err: anyerror) []const u8 {
    return known(err) orelse "net::ERR_FAILED";
}

// Chrome's net error for a transfer error, null when it has none. libcurl
// folds some of Chrome's causes into one code: CouldntConnect is also an
// unreachable host.
fn known(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.CouldntConnect => "net::ERR_CONNECTION_REFUSED",
        error.CouldntResolveHost => "net::ERR_NAME_NOT_RESOLVED",
        error.CouldntResolveProxy => "net::ERR_PROXY_CONNECTION_FAILED",
        error.RecvError, error.SendError => "net::ERR_CONNECTION_RESET",
        error.GotNothing => "net::ERR_EMPTY_RESPONSE",
        error.TooManyRedirects => "net::ERR_TOO_MANY_REDIRECTS",
        error.UrlMalformat => "net::ERR_INVALID_URL",
        error.UnsupportedProtocol => "net::ERR_UNKNOWN_URL_SCHEME",
        error.BadContentEncoding => "net::ERR_CONTENT_DECODING_FAILED",
        error.SslConnectError, error.UseSslFailed => "net::ERR_SSL_PROTOCOL_ERROR",
        error.PeerFailedVerification,
        error.SslCertproblem,
        error.SslCacertBadfile,
        error.SslIssuerError,
        error.SslInvalidcertstatus,
        => "net::ERR_CERT_AUTHORITY_INVALID",
        error.SslPinnedpubkeynotmatch => "net::ERR_SSL_PINNED_KEY_NOT_IN_CERT_CHAIN",
        error.UrlBlocked, error.RobotsBlocked, error.RobotsUnreachable => "net::ERR_BLOCKED_BY_CLIENT",
        // A destination on the Fetch bad-port list.
        error.UnsafePort => "net::ERR_UNSAFE_PORT",
        error.OperationTimedout => "net::ERR_TIMED_OUT",
        // The consumer canceled the request (xhr.abort, AbortController,
        // stopLoading...).
        error.TransferCanceled => "net::ERR_ABORTED",
        // The errors CDP's Fetch.failRequest fails a request with.
        error.Failed => "net::ERR_FAILED",
        error.AccessDenied => "net::ERR_ACCESS_DENIED",
        error.ConnectionClosed => "net::ERR_CONNECTION_CLOSED",
        error.ConnectionReset => "net::ERR_CONNECTION_RESET",
        error.ConnectionRefused => "net::ERR_CONNECTION_REFUSED",
        error.ConnectionAborted => "net::ERR_CONNECTION_ABORTED",
        error.ConnectionFailed => "net::ERR_CONNECTION_FAILED",
        error.NameNotResolved => "net::ERR_NAME_NOT_RESOLVED",
        error.InternetDisconnected => "net::ERR_INTERNET_DISCONNECTED",
        error.AddressUnreachable => "net::ERR_ADDRESS_UNREACHABLE",
        error.BlockedByClient => "net::ERR_BLOCKED_BY_CLIENT",
        error.BlockedByResponse => "net::ERR_BLOCKED_BY_RESPONSE",
        else => null,
    };
}

const testing = @import("../testing.zig");
test "server.net_error: netError" {
    try testing.expectEqualSlices(u8, "net::ERR_CONNECTION_REFUSED", netError(error.CouldntConnect));
    try testing.expectEqualSlices(u8, "net::ERR_TIMED_OUT", netError(error.OperationTimedout));
    try testing.expectEqualSlices(u8, "net::ERR_BLOCKED_BY_CLIENT", netError(error.UrlBlocked));
    try testing.expectEqualSlices(u8, "net::ERR_BLOCKED_BY_CLIENT", netError(error.RobotsBlocked));
    try testing.expectEqualSlices(u8, "net::ERR_BLOCKED_BY_CLIENT", netError(error.RobotsUnreachable));
    try testing.expectEqualSlices(u8, "net::ERR_ACCESS_DENIED", netError(error.AccessDenied));
    try testing.expectEqualSlices(u8, "net::ERR_ABORTED", netError(error.TransferCanceled));
    try testing.expectEqualSlices(u8, "net::ERR_FAILED", netError(error.SomethingElse));
    try testing.expect(known(error.SomethingElse) == null);
}
