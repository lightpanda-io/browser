export const yValue = 'dynamic-y';

export async function loadX() {
  const x = await import('./dynamic-circular-x.js');
  return x.xValue;
}
