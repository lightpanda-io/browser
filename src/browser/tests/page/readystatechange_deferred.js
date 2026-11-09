order.push('defer:' + document.readyState);
testing.expectEqual('interactive', document.readyState);
