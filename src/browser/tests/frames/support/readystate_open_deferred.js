var order = parent.order;
order.push('defer:' + document.readyState);
document.open();
order.push('open:' + document.readyState);
document.write('<p id=x>written</p>');

setTimeout(() => {
  order.push('before-close:' + document.readyState + ':' + parent.loads);
  // open() dropped the earlier listeners; these are on the new document.
  document.addEventListener('readystatechange', () => {
    order.push('readystatechange:' + document.readyState);
  });
  document.addEventListener('DOMContentLoaded', () => {
    order.push('DOMContentLoaded:' + document.readyState);
  });
  document.close();
}, 20);
