export const xValue = 'dynamic-x';

export async function loadY() {
  const y = await import('./dynamic-circular-y.js');
  return y.yValue;
}
