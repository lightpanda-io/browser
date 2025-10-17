import { aValue } from './circular-a.js';

export const bValue = 'b';

export function getBValue() {
  return bValue;
}

export function getFromA() {
  return aValue;
}
