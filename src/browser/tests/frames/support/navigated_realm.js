// Loads a document in an iframe or a popup, calls `take` with its window, then
// navigates that window in place. Whatever `take` returned was created in a
// realm that is gone once this resolves.
const navigatedRealm = (() => {
  let count = 0;

  function loaded(tag) {
    return new Promise((resolve) => {
      window.addEventListener('message', function onMessage(e) {
        if (e.data && e.data.realm === tag) {
          window.removeEventListener('message', onMessage);
          resolve();
        }
      });
    });
  }

  function url(tag) {
    return testing.BASE_URL + 'frames/support/realm.html?' + tag;
  }

  return async function(kind, take) {
    count += 1;
    const tag = 'realm' + count;
    const next = tag + '_next';

    let first = loaded(tag);
    let win = null;
    let navigate = null;
    if (kind === 'popup') {
      win = window.open(url(tag), tag);
      navigate = () => window.open(url(next), tag);
    } else {
      const iframe = document.createElement('iframe');
      iframe.src = url(tag);
      document.body.appendChild(iframe);
      navigate = () => { iframe.src = url(next); };
      await first;
      first = null;
      win = iframe.contentWindow;
    }
    await first;

    const taken = await take(win);
    const second = loaded(next);
    navigate();
    await second;
    return taken;
  };
})();
