// Fetches /cache/set-cookie twice, dropping its cookie in between. The body
// and the cookie carry how many times the server sent the response, as
// `served <n>` and `lp_cache_test=<n>`.
export async function fetchTwice() {
  const url = 'http://127.0.0.1:9582/cache/set-cookie';
  const cookie = () => document.cookie.match(/lp_cache_test=(\d+)/)?.[1] ?? null;

  const clear = () => document.cookie = 'lp_cache_test=; expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/';

  const first = await (await fetch(url)).text();
  const first_cookie = cookie();
  clear();
  const cleared = cookie();
  const second = await (await fetch(url)).text();
  const second_cookie = cookie();
  // The jar is shared with the tests that run after this one.
  clear();
  return {
    n: Number(first.slice('served '.length)),
    first_cookie,
    cleared,
    second,
    second_cookie,
  };
}
