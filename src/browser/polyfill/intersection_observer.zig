const std = @import("std");
// intersection_observer.js code comes from
// https://github.com/GoogleChromeLabs/intersection-observer/blob/main/intersection-observer.js
// It has been modified to not make a local copy of document as this is loaded ahead of time
pub const source = @embedFile("intersection_observer.js");
