export async function loadNext() {
  const c = await import('./dynamic-chain-c.js');
  return c.finalValue;
}

export const chainValue = 'chain-b';
