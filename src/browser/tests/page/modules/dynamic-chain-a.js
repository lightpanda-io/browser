export async function loadChain() {
  const b = await import('./dynamic-chain-b.js');
  return b.loadNext();
}

export const chainValue = 'chain-a';
