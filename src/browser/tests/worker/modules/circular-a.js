import { getBValue } from './circular-b.js';

export const aValue = 'a';

export function getFromB() {
  return getBValue();
}
