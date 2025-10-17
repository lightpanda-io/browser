import { staticValue } from './mixed-circular-static.js';

export const dynamicValue = 'dynamic-side';

export function getStaticValue() {
  return staticValue;
}
