// A module worker (`new Worker(url, { type: "module" })`). Unlike a classic
// worker, the entry script may use top-level static `import`/`export`, and
// `importScripts()` is not supported (it throws a TypeError).
import { baseValue } from './modules/base.js';
import { importedValue, localValue } from './modules/importer.js';

export const exported = 'top-level-export-ok';

let importScriptsError = null;
try {
  importScripts('./import-script1.js');
} catch (e) {
  importScriptsError = e.constructor.name;
}

onmessage = function (event) {
  postMessage({
    echo: event.data,
    baseValue: baseValue,
    importedValue: importedValue,
    localValue: localValue,
    importScriptsError: importScriptsError,
    from: 'module-worker',
  });
};
