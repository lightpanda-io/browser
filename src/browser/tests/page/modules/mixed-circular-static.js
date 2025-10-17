export const staticValue = 'static-side';

export async function loadDynamicSide() {
  const dynamic = await import('./mixed-circular-dynamic.js');
  return dynamic.dynamicValue;
}
