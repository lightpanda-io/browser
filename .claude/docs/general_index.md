# General Index

## Root

- `Makefile` - Build and test convenience Makefile for the project [BUILD]
- `build.zig` - Zig build script that defines build targets, links native deps (V8, curl, brotli, zlib, boringssl, nghttp2), and creates artifacts (executables, snapshot creator, tests).. Key: `Build`, `build`, `linkV8`, `linkHtml5Ever`, `linkCurl` [BUILD]

## src/

- `App.zig` - Top-level application context: initializes and owns global subsystems and resources. Key: `App`, `init`, `shutdown`, `deinit`, `getAndMakeAppDir` [SOURCE_CODE]
- `ArenaPool.zig` - A thread-safe pool of std.heap.ArenaAllocator instances with optional debug leak/double-free tracking and unit tests.. Key: `ArenaPool`, `Entry`, `DebugInfo`, `init`, `deinit` [SOURCE_CODE]
- `Config.zig` - Central CLI/configuration schema and accessors for runtime flags and derived values. Key: `RunMode`, `CDP_MAX_HTTP_REQUEST_SIZE`, `CDP_MAX_MESSAGE_SIZE`, `Config`, `init` [CONFIG]
- `Notification.zig` - Scoped notification/event bus for browser contexts. Key: `Notification`, `EventListeners`, `register`, `unregisterAll`, `dispatch` [SOURCE_CODE]
- `SemanticTree.zig` - Builds and serializes an accessibility-like semantic tree from DOM Nodes (JSON/text and node details).. Key: `jsonStringify`, `textStringify`, `walk`, `OptionData`, `NodeData` [SOURCE_CODE]
- `Server.zig` - TCP/CDP server: accepts HTTP requests, upgrades to WebSocket/CDP sessions, and manages client lifecycle and threading.. Key: `init`, `shutdown`, `deinit`, `spawnWorker`, `runWorker` [SOURCE_CODE]
- `Sighandler.zig` - Asynchronous OS signal handling and graceful shutdown callbacks. Key: `install`, `on`, `sighandle`, `Listener` [SOURCE_CODE]
- `TestHTTPServer.zig` - Lightweight local HTTP test server fixture. Key: `init`, `run`, `sendFile` [TEST]
- `TestWSServer.zig` - Small WebSocket echo/test server used by tests. Key: `TestWSServer`, `run`, `handleClient`, `RecvBuffer`, `sendLargeMessage` [SOURCE_CODE]
- `crash_handler.zig` - Central crash/panic handler and optional crash reporter. Key: `panic`, `crash`, `report`, `curlPath` [SOURCE_CODE]
- `datetime.zig` - Comprehensive date/time types, parsing, formatting and arithmetic. Key: `Date`, `Time`, `DateTime`, `DateTime.initUTC`, `DateTime.parseRFC3339` [SOURCE_CODE]
- `id.zig` - UUID v4 generator helper. Key: `uuidv4` [SOURCE_CODE]
- `lightpanda.zig` - Top-level Lightpanda runtime exports and helper utilities (fetch flow, assertions, RC helper).. Key: `FetchOpts`, `fetch`, `dumpWPT`, `assert`, `assertionFailure` [SOURCE_CODE]
- `log.zig` - Central logging facility: formatted log emission, value serialization and tests.. Key: `Scope`, `Opts`, `opts`, `enabled`, `log` [SOURCE_CODE]
- `main.zig` - CLI entrypoint: parse args, initialize global app, and dispatch serve/fetch/mcp modes. Key: `panic`, `main`, `run`, `fetchThread`, `mcpThread` [CLI]
- `main_legacy_test.zig` - Legacy test harness: serves files and runs legacy browser tests. Key: `main`, `run`, `TestHTTPServer`, `panic` [TEST]
- `main_snapshot_creator.zig` - CLI tool to produce V8 snapshot binary [CLI]
- `mcp.zig` - Top-level MCP re-exports (protocol, router, server). Key: `protocol`, `router`, `Server` [SOURCE_CODE]
- `slab.zig` - Slab allocator implementation and slab allocator wrapper. Key: `Slab`, `SlabAllocator`, `alloc / free (allocator vtable)`, `getStats` [SOURCE_CODE]
- `string.zig` - Small-string-optimized string type with interning. Key: `String`, `wrap / init / deinit / dupe`, `concat`, `intern` [SOURCE_CODE]
- `test_runner.zig` - Custom Zig test runner with timing and allocation tracking. Key: `Runner`, `main`, `TrackingAllocator`, `SlowTracker`, `panic` [TEST]
- `testing.zig` - Test harness and helper utilities for Zig-implemented browser runtime unit and web-API tests. Key: `allocator`, `arena_instance`, `arena_allocator`, `reset`, `expectEqual` [TEST]

## src/browser/

- `Browser.zig` - Top-level Browser instance managing environment and session lifecycle. Key: `init`, `newSession / closeSession`, `runMicrotasks / runMacrotasks / hasBackgroundTasks` [SOURCE_CODE]
- `EventManager.zig` - DOM event registration and dispatch manager with phases. Key: `EventManager`, `register`, `dispatch`, `dispatchNode`, `dispatchPhase` [SOURCE_CODE]
- `EventManagerBase.zig` - Core event listener registration and direct dispatch engine. Key: `EventManagerBase (struct)`, `register / remove / removeListener`, `dispatchDirect`, `Listener / Function` [SOURCE_CODE]
- `Factory.zig` - Factory utilities to allocate DOM objects with correct prototype chains. Key: `PrototypeChain`, `node / element / document / blob / abstractRange`, `destroy / destroyChain` [SOURCE_CODE]
- `HttpClient.zig` - HTTP client used by the browser runtime to manage network transfers, caching, robots handling and request interception.. Key: `Client`, `CDPClient`, `init`, `deinit`, `tick` [SOURCE_CODE]
- `Mime.zig` - MIME content-type parsing, sniffing and charset utilities. Key: `Mime`, `parse`, `prescanCharset`, `sniff` [SOURCE_CODE]
- `Page.zig` - Represents a document/frame: DOM container, lifecycle, navigation, and ties to ScriptManager, StyleManager and HTTP requests.. Key: `Page`, `init`, `deinit`, `headersForRequest`, `isSameOrigin` [SOURCE_CODE]
- `Runner.zig` - Implements the page-runner/event-loop helpers for waiting, ticking and high-level waits. Key: `Runner`, `Opts`, `init`, `wait`, `waitCDP` [SOURCE_CODE]
- `ScriptManager.zig` - Manages downloading, queuing, and execution lifecycle of <script> tags and ES module imports for a Page. Key: `ScriptManager`, `init`, `deinit`, `reset`, `clearList` [SOURCE_CODE]
- `Session.zig` - Manages per-browser session state: page lifetimes, navigation queues, V8 globals/finalizers, and resource arenas. Key: `Session`, `init`, `deinit`, `createPage`, `removePage` [SOURCE_CODE]
- `StyleManager.zig` - Manages visibility- and pointer-events-related CSS rules, buckets them for fast selector matching, and evaluates element visibility/pointer-events.. Key: `VisibilityCache`, `PointerEventsCache`, `StyleManager`, `init`, `deinit` [SOURCE_CODE]
- `URL.zig` - URL resolution, parsing and percent-encoding utilities. Key: `resolve`, `ensureEncoded`, `percentEncodeSegment`, `isCompleteHTTPUrl`, `getOrigin` [SOURCE_CODE]
- `actions.zig` - Implements high-level DOM user-interaction actions (click, fill, hover, press, select, scroll, waitForSelector).. Key: `dispatchInputAndChangeEvents`, `click`, `hover`, `press`, `selectOption` [SOURCE_CODE]
- `color.zig` - Color utilities: parsing, named colors and formatting. Key: `isHexColor`, `RGBA`, `RGBA.Named`, `RGBA.parse`, `RGBA.format` [SOURCE_CODE]
- `dump.zig` - DOM dumping/serialization utilities (HTML and JSON). Key: `Opts`, `root`, `deep`, `toJSON`, `writeEscapedText` [SOURCE_CODE]
- `forms.zig` - Collects form structures from a DOM root, serializes them to JSON and provides tests for form edge cases. Key: `SelectOption`, `FormField`, `FormInfo`, `registerNodes`, `collectForms` [SOURCE_CODE]
- `interactive.zig` - Collects and classifies user-interactive DOM elements and exposes them as serializable InteractiveElement objects (with tests).. Key: `InteractivityType`, `InteractiveElement`, `registerNodes`, `collectInteractiveElements`, `ListenerTargetMap` [SOURCE_CODE]
- `links.zig` - Collects anchor hrefs under a DOM root for link extraction. Key: `collectLinks` [SOURCE_CODE]
- `markdown.zig` - Converts DOM tree to markdown text representation. Key: `dump`, `Context`, `analyzeContent`, `isStandaloneAnchor` [SOURCE_CODE]
- `reflect.zig` - Compile-time helper to get parent struct type for typed child pointers. Key: `Struct` [SOURCE_CODE]
- `structured_data.zig` - Collects structured metadata (JSON-LD, OG, Twitter, meta, links) from DOM. Key: `StructuredData`, `collectStructuredData`, `writeProperties`, `collectJsonLd/collectMeta/collectLink/collectTitle` [SOURCE_CODE]

## src/browser/css/

- `Parser.zig` - CSS tokenizer/parser for declarations and rules. Key: `DeclarationsIterator`, `parseDeclarationsList`, `RulesIterator`, `parseStylesheet`, `TokenStream` [SOURCE_CODE]
- `Tokenizer.zig` - CSS tokenizer implementing the CSS Syntax Module Level 3 algorithm. Key: `Token`, `consumeString`, `consumeName`, `consumeComment`, `Tokenizer.advance / nextByte / hasNewlineAt` [SOURCE_CODE]

## src/browser/js/

- `Array.zig` - Light wrapper around V8 Array handles for JS interop. Key: `len`, `get`, `set`, `toObject / toValue` [SOURCE_CODE]
- `BigInt.zig` - BigInt wrapper for v8 BigInt creation and extraction. Key: `init`, `getInt64`, `getUint64` [SOURCE_CODE]
- `Caller.zig` - Bridge for V8 callbacks: invoke Zig functions from JS and handle results. Key: `init / deinit`, `constructor`, `getIndex / getNamedIndex / setNamedIndex / deleteNamedIndex / getEnumerator`, `FunctionCallbackInfo / PropertyCallbackInfo / ReturnValue`, `handleError` [SOURCE_CODE]
- `Context.zig` - Represents a V8 execution context mapped to a browser Page, managing module loading, identity, and lifecycle.. Key: `Context`, `ModuleEntry`, `fromC`, `fromIsolate`, `deinit` [SOURCE_CODE]
- `Env.zig` - Manages a V8 Isolate: init/deinit, per-isolate templates, contexts and task pumping. Key: `initClassIds`, `Env`, `init`, `deinit`, `createContext` [SOURCE_CODE]
- `Function.zig` - V8-backed JS Function wrapper and invocation helpers. Key: `withThis`, `newInstance`, `call / callWithThis / tryCall`, `persist / temp / _persist`, `Temp / Global (G)` [SOURCE_CODE]
- `HandleScope.zig` - RAII wrapper for V8 HandleScope lifetime management. Key: `initWithIsolateHandle`, `deinit` [SOURCE_CODE]
- `Identity.zig` - Session-level identity map between Zig instances and V8 objects. Key: `identity_map`, `deinit` [SOURCE_CODE]
- `Inspector.zig` - V8 Inspector wrapper and session/channel integration for DevTools protocol. Key: `Inspector`, `Session`, `RemoteObject`, `v8_inspector__Client__IMPL__generateUniqueId`, `getTaggedOpaque` [SOURCE_CODE]
- `Integer.zig` - Wrapper for creating V8 Integer handles from Zig integers. Key: `Integer`, `init` [SOURCE_CODE]
- `Isolate.zig` - Thin V8 Isolate wrapper exposing basic isolate operations. Key: `init`, `deinit`, `memoryPressureNotification`, `createTypeError`, `initStringHandle` [SOURCE_CODE]
- `Local.zig` - Local execution context helpers for Zig->V8 interactions and conversions. Key: `mapZigInstanceToJs`, `zigValueToJs`, `compileAndRun / compileFunction`, `newCallback / newObject / newString` [SOURCE_CODE]
- `Module.zig` - V8 Module wrapper: instantiate, evaluate, and persist ES modules. Key: `Module`, `Status`, `instantiate`, `evaluate`, `Global` [SOURCE_CODE]
- `Number.zig` - Wrapper for creating V8 Number handles from Zig numbers. Key: `Number`, `init` [SOURCE_CODE]
- `Object.zig` - High-level wrapper for V8 Object operations and property access. Key: `Object`, `has`, `get`, `set`, `persist` [SOURCE_CODE]
- `Origin.zig` - Represents and manages V8 security token for a web origin. Key: `init`, `deinit`, `security_token` [SOURCE_CODE]
- `Platform.zig` - Initializes and tears down the global V8 platform and ICU. Key: `Platform`, `init`, `deinit` [SOURCE_CODE]
- `Private.zig` - Creates and manages V8 Private symbols stored as Global handles. Key: `Private`, `init`, `deinit` [SOURCE_CODE]
- `Promise.zig` - V8 Promise wrapper and persistence helpers. Key: `thenAndCatch`, `toObject / toValue`, `persist / temp / _persist`, `Temp / Global (G)` [SOURCE_CODE]
- `PromiseRejection.zig` - Wrapper to inspect V8 promise rejection messages and reasons. Key: `PromiseRejection`, `promise`, `reason` [SOURCE_CODE]
- `PromiseResolver.zig` - Thin wrapper around V8 PromiseResolver for Zig code. Key: `init`, `resolve / reject / rejectError`, `persist / Global` [SOURCE_CODE]
- `Scheduler.zig` - Priority task scheduler for timed and repeatable callbacks. Key: `Scheduler`, `init`, `add`, `run`, `Task` [SOURCE_CODE]
- `Snapshot.zig` - Create, load and manage V8 startup snapshots and external references. Key: `load`, `create`, `collectExternalReferences`, `countExternalReferences`, `generateConstructor` [SOURCE_CODE]
- `String.zig` - Utilities to convert V8 strings to Zig buffers and SSO. Key: `toSlice`, `toSliceZ`, `toSSO`, `format` [SOURCE_CODE]
- `TaggedOpaque.zig` - Tagged opaque wrapper to map JS objects back to Zig instances safely. Key: `TaggedOpaque`, `PrototypeChainEntry`, `fromJS` [SOURCE_CODE]
- `TryCatch.zig` - Thin RAII wrapper for V8 TryCatch and exception extraction. Key: `TryCatch`, `init`, `hasCaught`, `caught`, `Caught` [SOURCE_CODE]
- `Value.zig` - JS Value wrapper and helpers for V8 interop. Key: `Value`, `toString`, `structuredClone`, `persist`, `Temp` [SOURCE_CODE]
- `bridge.zig` - Zig-to-V8 runtime bridge that defines how native Zig types/functions/properties are exposed to JS. Key: `Builder`, `Constructor`, `Function`, `Accessor`, `Indexed` [SOURCE_CODE]
- `js.zig` - High-level JS/V8 bindings, type mapping and bridge utilities. Key: `Bridge`, `simpleZigValueToJs`, `ArrayBufferRef`, `v8_inspector__Client__IMPL__valueSubtype`, `Env` [SOURCE_CODE]

## src/browser/parser/

- `Parser.zig` - HTML/XML parser bridge that builds DOM nodes via html5ever callbacks. Key: `Parser`, `parse / parseXML / parseFragment`, `Streaming`, `createElementCallback / appendCallback / popCallback`, `ParsedNode` [SOURCE_CODE]
- `html5ever.zig` - C FFI declarations for the html5ever parser and related types. Key: `html5ever_parse_document`, `html5ever_streaming_parser_create / feed / finish / destroy`, `AttributeIterator / NodeOrText / QualName`, `html5ever_get_memory_usage` [SOURCE_CODE]

## src/browser/tests/

- `mcp_actions.html` - HTML fixture page with elements and listeners to exercise MCP action tools in tests.. Key: `btn`, `inp`, `sel` [TEST]
- `testing.js` - Client-side test helper utilities for browser tests. Key: `testing.assertOk`, `expectEqual`, `async`, `_equal` [TEST]

## src/browser/tests/legacy/

- `testing.js` - Legacy browser-side test utilities for old test suite. Key: `testing.assertOk`, `expectEqual`, `eventually` [TEST]

## src/browser/tests/net/

- `xhr.html` - Browser-side test suite for XMLHttpRequest behaviors (readyState, response types, errors, abort, timeout, blob url). Key: `xhr`, `xhr6`, `xhr_abort`, `xhr_timeout` [TEST]

## src/browser/tests/page/modules/

- `circular-a.js` - Test module A illustrating circular ES module import. Key: `aValue`, `getFromB` [TEST]
- `circular-b.js` - Test module B for circular ES module import tests. Key: `bValue`, `getBValue`, `getFromA` [TEST]

## src/browser/webapi/

- `AbortController.zig` - Web API AbortController implementation and JS bridge. Key: `AbortController`, `init`, `abort`, `JsApi` [SOURCE_CODE]
- `AbortSignal.zig` - AbortSignal implementation with event dispatch and timeout helpers. Key: `AbortSignal`, `abort`, `createAborted`, `createTimeout`, `throwIfAborted` [SOURCE_CODE]
- `AbstractRange.zig` - DOM AbstractRange implementation and range maintenance. Key: `compareBoundaryPoints`, `updateForCharacterDataReplace`, `updateForSplitText`, `updateForNodeInsertion`, `updateForNodeRemoval` [SOURCE_CODE]
- `Blob.zig` - Blob implementation with slicing, streams and arrayBuffer support. Key: `init`, `arrayBuffer`, `slice`, `stream`, `writeBlobParts` [SOURCE_CODE]
- `CData.zig` - Character data (text/comment/CDATA) manipulation utilities and JS bindings. Key: `CData`, `utf16Len`, `utf16OffsetToUtf8`, `utf16RangeToUtf8`, `replaceData / insertData / deleteData / appendData` [SOURCE_CODE]
- `CSS.zig` - CSS web API helpers: parse dimensions and escape identifiers. Key: `parseDimension`, `escape`, `supports`, `JsApi` [SOURCE_CODE]
- `Console.zig` - Implementation of the Window.Console web API and logging helpers. Key: `trace`, `count`, `time`, `JsApi` [SOURCE_CODE]
- `Crypto.zig` - Crypto web API: random values, UUIDs and SubtleCrypto access. Key: `getRandomValues`, `randomUUID`, `getSubtle`, `JsApi` [SOURCE_CODE]
- `CryptoKey.zig` - Representation of Web Crypto CryptoKey and usages. Key: `Type`, `Usages`, `canSign`, `getDigest` [SOURCE_CODE]
- `CustomElementDefinition.zig` - Representation of a custom element definition and helpers. Key: `CustomElementDefinition`, `isAttributeObserved`, `isAutonomous`, `isCustomizedBuiltIn` [SOURCE_CODE]
- `CustomElementRegistry.zig` - Manage registration, upgrade and whenDefined lifecycle for custom elements. Key: `define`, `upgradeCustomElement`, `whenDefined`, `validateName` [SOURCE_CODE]
- `DOMException.zig` - DOMException wrapper mapping errors to legacy codes and messages. Key: `init`, `fromError`, `getName`, `getMessage`, `Code` [SOURCE_CODE]
- `DOMImplementation.zig` - DOMImplementation API for creating documents and doctypes. Key: `createDocumentType`, `createHTMLDocument`, `createDocument`, `JsApi` [SOURCE_CODE]
- `DOMNodeIterator.zig` - NodeIterator implementation for traversing DOM nodes. Key: `init`, `nextNode`, `previousNode`, `filterNode` [SOURCE_CODE]
- `DOMParser.zig` - DOMParser implementation to parse HTML/XML into Document objects. Key: `parseFromString`, `init`, `JsApi` [SOURCE_CODE]
- `DOMRect.zig` - DOMRect object representing rectangle geometry with accessors. Key: `init`, `getTop`, `getRight`, `JsApi` [SOURCE_CODE]
- `DOMTreeWalker.zig` - TreeWalker implementation for DOM subtree traversal with filters. Key: `init`, `nextNode`, `previousNode`, `acceptNode` [SOURCE_CODE]
- `Document.zig` - DOM Document implementation exposing web API helpers for creating/querying/managing nodes. Key: `Type`, `is`, `as`, `asNode`, `getURL` [SOURCE_CODE]
- `DocumentFragment.zig` - DocumentFragment implementation and DOM subtree utilities. Key: `getElementById`, `querySelector`, `getInnerHTML`, `setInnerHTML`, `cloneFragment` [SOURCE_CODE]
- `DocumentType.zig` - DocumentType node representation and operations (<!DOCTYPE>). Key: `init`, `getName`, `clone`, `remove` [SOURCE_CODE]
- `Element.zig` - Core Element implementation: DOM element API and utilities. Key: `Type`, `Namespace`, `getTagNameLower`, `getTagNameSpec`, `isEqualNode` [SOURCE_CODE]
- `Event.zig` - DOM Event type implementation and JS bindings. Key: `Event`, `init`, `composedPath`, `acquireRef`, `JsApi` [SOURCE_CODE]
- `EventTarget.zig` - Generic EventTarget implementation for DOM objects and event dispatch. Key: `addEventListener`, `removeEventListener`, `dispatchEvent`, `Type` [SOURCE_CODE]
- `File.zig` - File type (File extends Blob) placeholder and constructor. Key: `init` [SOURCE_CODE]
- `FileList.zig` - Placeholder FileList web API stub. Key: `getLength`, `item`, `JsApi` [SOURCE_CODE]
- `FileReader.zig` - FileReader implementation with event dispatch and read methods. Key: `init`, `readAsArrayBuffer`, `readAsText`, `readInternal`, `encodeDataURL` [SOURCE_CODE]
- `HTMLDocument.zig` - HTMLDocument API: accessors and helpers for head/body/title, cookies and location. Key: `getTitle`, `setTitle`, `getCookie`, `setCookie`, `getHead/getBody` [SOURCE_CODE]
- `History.zig` - Window History API: push/replace state and navigation controls. Key: `getLength`, `getState`, `pushState`, `back` [SOURCE_CODE]
- `IdleDeadline.zig` - IdleDeadline stub used for requestIdleCallback timeRemaining. Key: `init`, `timeRemaining`, `JsApi` [SOURCE_CODE]
- `ImageData.zig` - ImageData constructor and RGBA pixel storage binding. Key: `init`, `getData`, `ConstructorSettings` [SOURCE_CODE]
- `IntersectionObserver.zig` - Implementation of the IntersectionObserver Web API and its Entry objects for the headless DOM.. Key: `IntersectionObserver`, `IntersectionObserverEntry`, `ObserverInit`, `init`, `deinit` [SOURCE_CODE]
- `KeyValueList.zig` - Generic ordered key/value list with encoding and iteration support. Key: `KeyValueList`, `fromJsObject`, `urlEncode`, `Iterator` [SOURCE_CODE]
- `Location.zig` - Location object wrapping URL and scheduling navigations. Key: `init`, `setHash`, `assign`, `reload` [SOURCE_CODE]
- `MessageChannel.zig` - Implements the MessageChannel Web API and entangles two MessagePort objects. Key: `init`, `getPort1`, `getPort2`, `JsApi` [SOURCE_CODE]
- `MessagePort.zig` - MessagePort implementation with entanglement and delivery. Key: `entangle`, `postMessage`, `PostMessageCallback`, `start`, `close` [SOURCE_CODE]
- `MutationObserver.zig` - DOM MutationObserver implementation and MutationRecord wrapper. Key: `MutationObserver`, `MutationRecord`, `notifyAttributeChange`, `notifyCharacterDataChange`, `notifyChildListChange` [SOURCE_CODE]
- `Navigator.zig` - Navigator API implementation exposing browser properties. Key: `Navigator`, `getUserAgent`, `registerProtocolHandler`, `validateProtocolHandlerScheme` [SOURCE_CODE]
- `Node.zig` - Core DOM Node implementation and tree-manipulation utilities. Key: `Node (Type union and fields)`, `appendChild`, `findAdjacentNodes`, `getTextContent / setTextContent` [SOURCE_CODE]
- `NodeFilter.zig` - NodeFilter implementation supporting function & object-based filters. Key: `FilterOpts`, `init`, `acceptNode`, `shouldShow`, `FILTER_ACCEPT` [SOURCE_CODE]
- `Performance.zig` - Implements the Performance API: high-res timing, marks, measures and entries. Key: `Performance`, `highResTimestamp`, `mark`, `measure`, `Entry` [SOURCE_CODE]
- `PerformanceObserver.zig` - PerformanceObserver implementation to observe PerformanceEntry delivery. Key: `init`, `observe`, `takeRecords`, `dispatch`, `EntryList` [SOURCE_CODE]
- `Permissions.zig` - Minimal Permissions API implementation returning safe defaults. Key: `query`, `PermissionStatus`, `JsApi (Permissions.JsApi)` [SOURCE_CODE]
- `PluginArray.zig` - Stubbed PluginArray API exposing empty plugin list. Key: `getAtIndex`, `getByName`, `JsApi` [SOURCE_CODE]
- `Range.zig` - DOM Range implementation supporting selection and content manipulation. Key: `setStart/setEnd`, `compareBoundaryPoints`, `insertNode`, `deleteContents`, `cloneContents` [SOURCE_CODE]
- `ResizeObserver.zig` - Lightweight JS binding for ResizeObserver (stubbed implementation). Key: `ResizeObserver`, `init`, `observe`, `JsApi` [SOURCE_CODE]
- `Screen.zig` - Screen and ScreenOrientation Web API exposing device display info. Key: `getOrientation`, `Screen`, `Orientation.init` [SOURCE_CODE]
- `Selection.zig` - Selection API implementation for managing document ranges. Key: `Selection (struct)`, `addRange / removeRange / removeAllRanges`, `modify / modifyByCharacter / modifyByWord` [SOURCE_CODE]
- `ShadowRoot.zig` - ShadowRoot implementation and JS bridge with element lookup and stylesheet handling. Key: `ShadowRoot`, `Mode`, `init`, `getElementById`, `JsApi` [SOURCE_CODE]
- `StorageManager.zig` - StorageManager Web API exposing storage quota estimate. Key: `estimate`, `StorageEstimate`, `registerTypes` [SOURCE_CODE]
- `SubtleCrypto.zig` - Partial SubtleCrypto Web Crypto API: key gen, sign, verify, derive, digest. Key: `generateKey`, `exportKey`, `digest`, `deriveBits` [SOURCE_CODE]
- `TreeWalker.zig` - Generic TreeWalker implementation for DOM traversal with modes. Key: `TreeWalker(comptime mode: Mode)`, `next`, `skipChildren`, `Elements` [SOURCE_CODE]
- `URL.zig` - JS URL wrapper: parse/manipulate URL components and blob URL management. Key: `init`, `getSearchParams`, `setHref`, `createObjectURL/revokeObjectURL` [SOURCE_CODE]
- `VisualViewport.zig` - VisualViewport bindings exposing static viewport properties and page scroll offsets. Key: `VisualViewport`, `getPageLeft`, `getPageTop`, `JsApi` [SOURCE_CODE]
- `Window.zig` - Implementation of the global Window web API bridge: DOM access, timers, events, navigation and cross-origin handling. Key: `registerTypes`, `Window`, `asEventTarget`, `setLocation`, `fetch` [SOURCE_CODE]
- `XMLDocument.zig` - XMLDocument wrapper delegating to Document for XML DOM handling. Key: `asDocument`, `asNode`, `JsApi` [SOURCE_CODE]
- `XMLSerializer.zig` - Serializes DOM nodes/documents to XML strings. Key: `serializeToString`, `init`, `JsApi` [SOURCE_CODE]
- `children.zig` - Efficient Children representation (single-child fast-path or linked list). Key: `Children`, `first`, `last`, `len` [SOURCE_CODE]
- `collections.zig` - Central re-export and registration of DOM collection types. Key: `registerTypes`, `HTMLCollection`, `DOMTokenList` [SOURCE_CODE]
- `global_event_handlers.zig` - Mapping and lookup utilities for global event handler names. Key: `Handler`, `Key`, `Lookup`, `fromEventType` [SOURCE_CODE]

## src/browser/webapi/animation/

- `Animation.zig` - Implements a simplified Animation API with scheduling and promises. Key: `init`, `play`, `getFinished`, `update`, `JsApi` [SOURCE_CODE]

## src/browser/webapi/canvas/

- `CanvasRenderingContext2D.zig` - Partial CanvasRenderingContext2D implementation with ImageData support. Key: `CanvasRenderingContext2D`, `getFillStyle / setFillStyle`, `createImageData`, `getImageData` [SOURCE_CODE]
- `OffscreenCanvas.zig` - OffscreenCanvas API shim with context creation and blob export. Key: `constructor`, `getContext`, `convertToBlob`, `transferToImageBitmap`, `JsApi` [SOURCE_CODE]
- `OffscreenCanvasRenderingContext2D.zig` - 2D offscreen canvas rendering context with ImageData support. Key: `getFillStyle / setFillStyle`, `createImageData`, `getImageData`, `putImageData`, `JsApi` [SOURCE_CODE]
- `WebGLRenderingContext.zig` - WebGLRenderingContext shim exposing extension handling. Key: `Extension`, `find`, `getExtension`, `getSupportedExtensions`, `JsApi` [SOURCE_CODE]

## src/browser/webapi/cdata/

- `CDATASection.zig` - CDATASection DOM node JS binding. Key: `CDATASection`, `JsApi` [SOURCE_CODE]
- `Comment.zig` - Comment node implementation and constructor. Key: `init`, `JsApi` [SOURCE_CODE]
- `ProcessingInstruction.zig` - ProcessingInstruction node with target accessor. Key: `getTarget`, `JsApi` [SOURCE_CODE]
- `Text.zig` - Text node implementation with splitText supporting live range updates. Key: `init`, `getWholeText`, `splitText`, `JsApi` [SOURCE_CODE]

## src/browser/webapi/collections/

- `ChildNodes.zig` - Live childNodes collection implementation and iterators. Key: `ChildNodes`, `init`, `getAtIndex`, `runtimeGenericWrap`, `Iterator` [SOURCE_CODE]
- `DOMTokenList.zig` - Live DOMTokenList implementation for tokenized attributes. Key: `DOMTokenList`, `add / remove / toggle / replace`, `contains / item / length`, `forEach`, `JsApi` [SOURCE_CODE]
- `HTMLAllCollection.zig` - HTMLAllCollection providing live all-elements access and callable behavior. Key: `init`, `length / getAtIndex / getByName`, `callable`, `iterator` [SOURCE_CODE]
- `HTMLCollection.zig` - Typed HTMLCollection implementations backed by TreeWalker modes. Key: `Mode`, `length / getAtIndex / getByName`, `iterator`, `Iterator` [SOURCE_CODE]
- `HTMLFormControlsCollection.zig` - Form controls collection with named-item and radio-group handling. Key: `NamedItemResult`, `namedItem`, `iterator`, `Iterator` [SOURCE_CODE]
- `HTMLOptionsCollection.zig` - Options collection API for <select> elements (add/remove/select). Key: `getSelectedIndex / setSelectedIndex`, `add`, `remove`, `JsApi` [SOURCE_CODE]
- `NodeList.zig` - NodeList collection implementation with multiple backing strategies and JS iteration APIs. Key: `NodeList`, `length`, `getAtIndex`, `forEach`, `JsApi` [SOURCE_CODE]
- `RadioNodeList.zig` - Representation of a radio group as a NodeList with value semantics. Key: `getLength`, `getAtIndex`, `getValue / setValue`, `matches` [SOURCE_CODE]
- `iterator.zig` - Generic iterator wrapper generator producing JS-friendly iterator objects. Key: `Entry`, `reflect`, `ValueType` [SOURCE_CODE]
- `node_live.zig` - Generic live DOM collections optimized with TreeWalker and caching. Key: `NodeLive(comptime mode)`, `Filters`, `getAtIndex`, `getByName`, `runtimeGenericWrap` [SOURCE_CODE]

## src/browser/webapi/crypto/

- `HMAC.zig` - WebCrypto-style HMAC key handling, sign and verify using libcrypto. Key: `init`, `sign`, `verify` [SOURCE_CODE]
- `X25519.zig` - X25519 key generation and shared-secret derivation for WebCrypto. Key: `init`, `deriveBits` [SOURCE_CODE]
- `algorithm.zig` - Types for Web Crypto algorithm/init parameter handling. Key: `Init`, `Init.RsaHashedKeyGen`, `Init.HmacKeyGen`, `Derive`, `Sign` [SOURCE_CODE]

## src/browser/webapi/css/

- `CSSRule.zig` - Base CSSRule representation and JS bindings. Key: `Type`, `init`, `getType`, `getCssText`, `JsApi` [SOURCE_CODE]
- `CSSRuleList.zig` - In-memory list container for CSSRule objects with JS bindings. Key: `CSSRuleList`, `init`, `length`, `item`, `JsApi` [SOURCE_CODE]
- `CSSStyleDeclaration.zig` - CSSStyleDeclaration implementation: parse, normalize, serialize and sync inline styles. Key: `CSSStyleDeclaration`, `init`, `setProperty`, `normalizePropertyValue`, `syncStyleAttribute` [SOURCE_CODE]
- `CSSStyleProperties.zig` - Indexed property access wrapper mapping camelCase style names to CSS properties. Key: `CSSStyleProperties`, `init`, `getNamed`, `setNamed`, `camelCaseToDashCase` [SOURCE_CODE]
- `CSSStyleRule.zig` - Represents a CSS style rule (selector + declaration) with JS bindings. Key: `CSSStyleRule`, `init`, `setSelectorText`, `getStyle`, `getCssText` [SOURCE_CODE]
- `CSSStyleSheet.zig` - CSSStyleSheet implementation with rule parsing and mutation. Key: `CSSStyleSheet`, `CSSError`, `insertRule`, `replaceSync`, `getCssRules` [SOURCE_CODE]
- `FontFace.zig` - Headless FontFace object with JS bindings. Key: `FontFace`, `init`, `load`, `JsApi` [SOURCE_CODE]
- `FontFaceSet.zig` - FontFaceSet implementation with event dispatch and JS bridge. Key: `FontFaceSet`, `init`, `load`, `JsApi` [SOURCE_CODE]
- `MediaQueryList.zig` - Lightweight MediaQueryList implementation exposing media and matches. Key: `MediaQueryList`, `getMedia`, `addListener`, `removeListener` [SOURCE_CODE]
- `StyleSheetList.zig` - List container for CSSStyleSheet objects with JS accessors. Key: `StyleSheetList`, `init`, `length`, `item` [SOURCE_CODE]

## src/browser/webapi/element/

- `Attribute.zig` - Attribute representation and attribute list (NamedNodeMap) handling. Key: `Attribute`, `List`, `NamedNodeMap`, `validateAttributeName`, `normalizeNameForLookup` [SOURCE_CODE]
- `DOMStringMap.zig` - Implements element.dataset mapping between camelCase and data- attributes. Key: `DOMStringMap`, `getProperty`, `setProperty`, `camelToKebab`, `kebabToCamel` [SOURCE_CODE]
- `Html.zig` - HTML element implementations and attribute/event bindings. Key: `Type`, `construct`, `getInnerText`, `insertAdjacentHTML`, `setAttributeListener` [SOURCE_CODE]
- `Svg.zig` - SVG element wrapper with type-dispatch and preserved tag casing. Key: `Svg`, `Type`, `is`, `asElement` [SOURCE_CODE]

## src/browser/webapi/element/html/

- `Anchor.zig` - HTMLAnchorElement implementation and URL property helpers. Key: `Anchor`, `getHref / setHref / getResolvedHref`, `getOrigin / getHost / getPathname / getSearch / getHash / set*`, `JsApi` [SOURCE_CODE]
- `Area.zig` - HTMLAreaElement wrapper and JS registration. Key: `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Audio.zig` - HTMLAudioElement construction and default attribute handling. Key: `constructor`, `asMedia`, `JsApi` [SOURCE_CODE]
- `BR.zig` - HTMLBRElement wrapper and JS prototype metadata. Key: `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Base.zig` - HTMLBaseElement wrapper and JS registration. Key: `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Body.zig` - HTMLBodyElement wrapper with special window.onload alias handling. Key: `setOnLoad`, `getOnLoad`, `Build.complete` [SOURCE_CODE]
- `Button.zig` - HTMLButtonElement attributes and form owner resolution. Key: `getDisabled`, `setDisabled`, `getForm`, `JsApi` [SOURCE_CODE]
- `Canvas.zig` - HTMLCanvasElement implementation and context management. Key: `getWidth`, `setWidth`, `getContext`, `transferControlToOffscreen`, `DrawingContext` [SOURCE_CODE]
- `Custom.zig` - Custom element lifecycle, upgrade and callback invocation. Key: `invokeConnectedCallbackOnElement`, `checkAndAttachBuiltIn`, `invokeAttributeChangedCallbackOnElement`, `invokeCallback` [SOURCE_CODE]
- `DList.zig` - HTMLDListElement wrapper and JS prototype binding. Key: `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Data.zig` - HTML <data> element bindings and value accessor for JS bridge. Key: `asElement`, `getValue`, `setValue`, `JsApi` [SOURCE_CODE]
- `DataList.zig` - HTML <datalist> element JS bridge and type bindings. Key: `asElement`, `JsApi` [SOURCE_CODE]
- `Details.zig` - HTML <details> element: open/name accessors and JS bridge. Key: `getOpen`, `setOpen`, `getName`, `setName`, `JsApi` [SOURCE_CODE]
- `Dialog.zig` - HTML <dialog> element bindings with open/returnValue accessors. Key: `getOpen`, `setOpen`, `getReturnValue`, `setReturnValue`, `JsApi` [SOURCE_CODE]
- `Directory.zig` - HTML <dir> (directory) element JS binding. Key: `asElement`, `JsApi` [SOURCE_CODE]
- `Div.zig` - HTML <div> element wrapper and JS bridge registration. Key: `asElement`, `JsApi` [SOURCE_CODE]
- `Embed.zig` - HTML <embed> element JS binding and DOM integration. Key: `asElement`, `JsApi` [SOURCE_CODE]
- `FieldSet.zig` - HTML <fieldset> element: disabled/name accessors and JS bridge. Key: `getDisabled`, `setDisabled`, `getName`, `setName`, `JsApi` [SOURCE_CODE]
- `Font.zig` - HTML <font> element JS wrapper (legacy) and bridge metadata. Key: `asElement`, `JsApi` [SOURCE_CODE]
- `Form.zig` - HTMLFormElement API: attributes, elements and submission. Key: `getAction`, `getMethod`, `getElements`, `submit`, `requestSubmit` [SOURCE_CODE]
- `Generic.zig` - Generic HTML element wrapper for arbitrary tag names and JS exposure. Key: `_tag_name`, `_tag`, `asElement`, `JsApi` [SOURCE_CODE]
- `HR.zig` - HTML <hr> element binding and JS bridge metadata. Key: `asElement`, `JsApi` [SOURCE_CODE]
- `Head.zig` - HTML <head> element wrapper and JS bridge registration. Key: `asElement`, `JsApi` [SOURCE_CODE]
- `Heading.zig` - HTML heading element wrapper (h1..h6) with tag info and JS bridge. Key: `_tag_name`, `_tag`, `asElement`, `JsApi` [SOURCE_CODE]
- `Html.zig` - HTML <html> element wrapper and JS bridge metadata. Key: `asElement`, `JsApi` [SOURCE_CODE]
- `IFrame.zig` - HTMLIFrameElement implementation: src/name and content accessors. Key: `getContentWindow`, `getContentDocument`, `getSrc / setSrc`, `JsApi` [SOURCE_CODE]
- `Image.zig` - HTMLImageElement/Image constructor, src handling and load semantics. Key: `constructor`, `getSrc / setSrc`, `imageAddedCallback`, `JsApi` [SOURCE_CODE]
- `Input.zig` - HTMLInputElement implementation: types, value/checked, selection and form behaviors. Key: `Type`, `setValue / getValue`, `setChecked / getChecked`, `setSelectionRange / select / innerInsert`, `JsApi` [SOURCE_CODE]
- `LI.zig` - HTML <li> element wrapper with numeric value accessor and tests. Key: `getValue`, `setValue`, `JsApi` [SOURCE_CODE]
- `Label.zig` - HTMLLabelElement implementation with attribute access and control lookup. Key: `Label.asElement`, `Label.getHtmlFor`, `Label.setHtmlFor`, `Label.getControl`, `Label.JsApi` [SOURCE_CODE]
- `Legend.zig` - HTMLLegendElement JS binding and lightweight wrapper. Key: `Legend.asElement`, `Legend.asNode`, `Legend.JsApi` [SOURCE_CODE]
- `Link.zig` - HTMLLinkElement implementation with resource loading hooks. Key: `Link`, `getHref / setHref`, `linkAddedCallback`, `getCrossOrigin / setCrossOrigin`, `JsApi` [SOURCE_CODE]
- `Map.zig` - HTMLMapElement JS binding wrapper. Key: `Map.asElement`, `Map.asNode`, `Map.JsApi` [SOURCE_CODE]
- `Media.zig` - HTMLMediaElement implementation handling media state and attributes. Key: `ReadyState`, `NetworkState`, `Type`, `canPlayType`, `play / pause / load` [SOURCE_CODE]
- `Meta.zig` - HTMLMetaElement with accessors for name, http-equiv, content, media. Key: `Meta.asElement`, `Meta.getName`, `Meta.setName`, `Meta.getHttpEquiv`, `Meta.getContent` [SOURCE_CODE]
- `Meter.zig` - HTMLMeterElement JS binding stub. Key: `Meter.asElement`, `Meter.asNode`, `Meter.JsApi` [SOURCE_CODE]
- `Mod.zig` - HTMLModElement wrapper and JS registration. Key: `Mod._tag_name`, `Mod._tag`, `Mod.asElement`, `Mod.JsApi` [SOURCE_CODE]
- `OL.zig` - HTMLOListElement with start/reversed/type attribute accessors. Key: `OL.getStart`, `OL.setStart`, `OL.getReversed`, `OL.setReversed`, `OL.getType` [SOURCE_CODE]
- `Object.zig` - HTMLObjectElement JS bridge wrapper. Key: `Object.asElement`, `Object.asNode`, `Object.JsApi` [SOURCE_CODE]
- `OptGroup.zig` - HTMLOptGroupElement with disabled and label accessors. Key: `OptGroup.getDisabled`, `OptGroup.setDisabled`, `OptGroup.getLabel`, `OptGroup.setLabel`, `OptGroup.JsApi` [SOURCE_CODE]
- `Option.zig` - HTMLOptionElement with value/text/selected/disabled handling and build hooks. Key: `Option.getValue`, `Option.setValue`, `Option.getText`, `Option.setText`, `Option.setSelected` [SOURCE_CODE]
- `Output.zig` - HTMLOutputElement JS binding stub. Key: `Output.asElement`, `Output.asNode`, `Output.JsApi` [SOURCE_CODE]
- `Paragraph.zig` - HTMLParagraphElement wrapper and JS registration. Key: `Paragraph.asElement`, `Paragraph.asNode`, `Paragraph.JsApi` [SOURCE_CODE]
- `Param.zig` - HTMLParamElement JS bridge wrapper. Key: `Param.asElement`, `Param.asNode`, `Param.JsApi` [SOURCE_CODE]
- `Picture.zig` - HTMLPictureElement wrapper and JS registration. Key: `Picture.asElement`, `Picture.asNode`, `Picture.JsApi` [SOURCE_CODE]
- `Pre.zig` - HTMLPreElement wrapper and JS binding. Key: `Pre.asElement`, `Pre.asNode`, `Pre.JsApi` [SOURCE_CODE]
- `Progress.zig` - HTMLProgressElement wrapper and JS binding metadata. Key: `Progress`, `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Quote.zig` - HTMLQuoteElement implementation with cite accessor and test. Key: `Quote`, `getCite`, `setCite`, `JsApi` [SOURCE_CODE]
- `Script.zig` - HTMLScriptElement behavior and JS bindings. Key: `getSrc / setSrc`, `getAsync / setAsync`, `setInnerText / _text / _innerText`, `Build.complete`, `JsApi` [SOURCE_CODE]
- `Select.zig` - HTMLSelectElement implementation with options management. Key: `Select`, `getValue`, `setValue`, `getSelectedIndex`, `getOptions` [SOURCE_CODE]
- `Slot.zig` - HTMLSlotElement implementation with assignment semantics. Key: `Slot`, `assignedNodes`, `assignedElements`, `collectAssignedNodes`, `findShadowRoot` [SOURCE_CODE]
- `Source.zig` - HTMLSourceElement wrapper and JS binding metadata. Key: `Source`, `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Span.zig` - HTMLSpanElement wrapper and JS binding metadata. Key: `Span`, `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Style.zig` - HTMLStyleElement implementation with stylesheet parsing and sheet access. Key: `getSheet`, `styleAddedCallback`, `JsApi` [SOURCE_CODE]
- `Table.zig` - HTMLTableElement wrapper and JS binding metadata. Key: `Table`, `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `TableCaption.zig` - HTMLTableCaptionElement wrapper and JS binding metadata. Key: `TableCaption`, `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `TableCell.zig` - HTMLTableCellElement with colSpan/rowSpan accessors and test. Key: `TableCell`, `getColSpan`, `setColSpan`, `getRowSpan`, `setRowSpan` [SOURCE_CODE]
- `TableCol.zig` - HTMLTableColElement wrapper and JS binding metadata. Key: `TableCol`, `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `TableRow.zig` - HTMLTableRowElement wrapper and JS binding metadata. Key: `TableRow`, `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `TableSection.zig` - HTMLTableSectionElement wrapper and JS binding metadata. Key: `TableSection`, `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Template.zig` - HTMLTemplateElement implementation with content DocumentFragment. Key: `Template`, `created`, `getContent`, `setInnerHTML`, `getOuterHTML` [SOURCE_CODE]
- `TextArea.zig` - HTMLTextAreaElement implementation with value, selection and form integration. Key: `getValue / setValue`, `setSelectionRange / getSelectionStart / getSelectionEnd`, `innerInsert`, `getForm` [SOURCE_CODE]
- `Time.zig` - HTMLTimeElement with datetime accessor and test. Key: `Time`, `getDateTime`, `setDateTime`, `JsApi` [SOURCE_CODE]
- `Title.zig` - HTMLTitleElement wrapper and JS binding metadata. Key: `Title`, `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Track.zig` - Implementation and JS bridge for HTMLTrackElement. Key: `ReadyState`, `setKind`, `getKind`, `JsApi` [SOURCE_CODE]
- `UL.zig` - HTMLUListElement JS binding and thin element wrapper. Key: `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Unknown.zig` - Represents unknown/custom HTML elements and JS binding. Key: `_tag_name`, `asElement`, `JsApi` [SOURCE_CODE]
- `Video.zig` - HTMLVideoElement wrapper with poster URL resolution and JS bindings. Key: `getPoster`, `setPoster`, `getVideoWidth`, `JsApi` [SOURCE_CODE]

## src/browser/webapi/element/svg/

- `Generic.zig` - Generic SVG element wrapper and JS metadata. Key: `asElement`, `asNode`, `JsApi` [SOURCE_CODE]
- `Rect.zig` - SVGRectElement wrapper and JS binding. Key: `asElement`, `asNode`, `JsApi` [SOURCE_CODE]

## src/browser/webapi/encoding/

- `TextDecoder.zig` - Simplified TextDecoder implementation with streaming support. Key: `TextDecoder`, `init`, `decode`, `JsApi` [SOURCE_CODE]
- `TextDecoderStream.zig` - Transform stream decoding Uint8Array chunks into UTF-8 strings. Key: `TextDecoderStream`, `init`, `decodeTransform`, `getReadable` [SOURCE_CODE]
- `TextEncoder.zig` - Simple TextEncoder that encodes strings to UTF-8 Uint8Array. Key: `TextEncoder`, `init`, `encode` [SOURCE_CODE]
- `TextEncoderStream.zig` - Transform stream encoding JS strings into Uint8Array chunks. Key: `TextEncoderStream`, `init`, `encodeTransform`, `getReadable` [SOURCE_CODE]

## src/browser/webapi/event/

- `CloseEvent.zig` - CloseEvent implementation for connection-close semantics. Key: `CloseEvent`, `init`, `getCode`, `JsApi` [SOURCE_CODE]
- `CompositionEvent.zig` - CompositionEvent DOM implementation and JS bridge with data payload. Key: `CompositionEvent`, `init`, `getData`, `JsApi` [SOURCE_CODE]
- `CustomEvent.zig` - CustomEvent implementation with detail storage and init method. Key: `CustomEvent`, `init`, `initCustomEvent`, `getDetail` [SOURCE_CODE]
- `ErrorEvent.zig` - ErrorEvent implementation carrying diagnostics and exception value. Key: `ErrorEvent`, `init`, `getError`, `JsApi` [SOURCE_CODE]
- `FocusEvent.zig` - FocusEvent implementation referencing a related target. Key: `FocusEvent`, `init`, `getRelatedTarget` [SOURCE_CODE]
- `FormDataEvent.zig` - Implementation of the FormDataEvent web API wrapper. Key: `FormDataEvent`, `init`, `initTrusted`, `getFormData`, `JsApi` [SOURCE_CODE]
- `InputEvent.zig` - InputEvent implementation with trusted/untrusted constructors and properties. Key: `InputEvent`, `init`, `initTrusted`, `getData`, `JsApi` [SOURCE_CODE]
- `KeyboardEvent.zig` - Implementation of DOM KeyboardEvent with key parsing and JS binding. Key: `Key`, `Location`, `KeyboardEventOptions`, `initWithTrusted`, `JsApi` [SOURCE_CODE]
- `MessageEvent.zig` - MessageEvent wrapper and JS bindings for postMessage events. Key: `MessageEvent`, `Data`, `init`, `deinit`, `JsApi` [SOURCE_CODE]
- `MouseEvent.zig` - Mouse/Pointer event implementation and JS bindings. Key: `MouseButton`, `Type`, `MouseEventOptions`, `initWithTrusted`, `JsApi` [SOURCE_CODE]
- `NavigationCurrentEntryChangeEvent.zig` - Event signaling navigation current-entry changes with type metadata. Key: `NavigationCurrentEntryChangeEvent`, `init`, `getFrom` [SOURCE_CODE]
- `PageTransitionEvent.zig` - PageTransitionEvent implementation with persisted flag. Key: `PageTransitionEvent`, `init`, `getPersisted` [SOURCE_CODE]
- `PointerEvent.zig` - PointerEvent implementation building on MouseEvent with pointer specifics. Key: `PointerEvent`, `PointerType`, `init`, `getPointerId` [SOURCE_CODE]
- `PopStateEvent.zig` - Implementation of the PopStateEvent Web API. Key: `PopStateEvent`, `init / initTrusted / initWithTrusted`, `getState`, `JsApi` [SOURCE_CODE]
- `ProgressEvent.zig` - ProgressEvent implementation for progress reporting. Key: `ProgressEvent`, `init / initTrusted / initWithTrusted`, `getTotal / getLoaded / getLengthComputable`, `JsApi` [SOURCE_CODE]
- `PromiseRejectionEvent.zig` - PromiseRejectionEvent wrapper exposing promise rejection details. Key: `PromiseRejectionEventOptions`, `init`, `deinit`, `JsApi` [SOURCE_CODE]
- `SubmitEvent.zig` - SubmitEvent implementation and JS binding. Key: `SubmitEvent`, `Options`, `init`, `getSubmitter`, `JsApi` [SOURCE_CODE]
- `TextEvent.zig` - TextEvent implementation and initializer for text input events. Key: `TextEvent`, `init`, `initTextEvent`, `getData`, `JsApi` [SOURCE_CODE]
- `UIEvent.zig` - Base UIEvent implementation shared by input/mouse/keyboard events. Key: `Type`, `UIEventOptions`, `init`, `getView`, `JsApi` [SOURCE_CODE]
- `WheelEvent.zig` - WheelEvent implementation for mouse wheel interactions. Key: `WheelEvent`, `DOM_DELTA_PIXEL / DOM_DELTA_LINE / DOM_DELTA_PAGE`, `init`, `getDeltaX / getDeltaY / getDeltaZ / getDeltaMode`, `JsApi` [SOURCE_CODE]

## src/browser/webapi/media/

- `MediaError.zig` - MediaError object with standard error codes and message. Key: `MediaError`, `init`, `getCode`, `getMessage`, `JsApi` [SOURCE_CODE]
- `TextTrackCue.zig` - Base TextTrackCue object with timing and event callback support. Key: `TextTrackCue`, `Type`, `getStartTime`, `setOnEnter`, `JsApi` [SOURCE_CODE]
- `VTTCue.zig` - Concrete VTTCue implementation for WebVTT cues. Key: `VTTCue`, `constructor`, `getText`, `getCueAsHTML` [SOURCE_CODE]

## src/browser/webapi/navigation/

- `Navigation.zig` - Implementation of the Navigation API and history management. Key: `Navigation`, `navigate / navigateInner`, `pushEntry / replaceEntry / updateEntries / commitNavigation`, `back / forward / reload / traverseTo`, `JsApi` [SOURCE_CODE]
- `NavigationActivation.zig` - Represents a navigation activation event with history references. Key: `NavigationActivation`, `getEntry`, `getFrom`, `getNavigationType` [SOURCE_CODE]
- `NavigationHistoryEntry.zig` - Representation of a history entry for the Navigation API. Key: `NavigationHistoryEntry`, `id / key / url / index`, `getState`, `JsApi` [SOURCE_CODE]
- `root.zig` - Shared navigation enums and structs (types, kinds, state, transition). Key: `NavigationType`, `NavigationKind`, `NavigationState`, `NavigationTransition` [SOURCE_CODE]

## src/browser/webapi/net/

- `Fetch.zig` - Implements the Web Fetch() WebAPI: builds Request, drives HttpClient, and resolves JS Promise.. Key: `Fetch`, `Input`, `InitOpts`, `init`, `handleBlobUrl` [SOURCE_CODE]
- `FormData.zig` - FormData implementation and utilities for form serialization. Key: `FormData`, `init`, `collectForm`, `get/set/append/delete`, `JsApi` [SOURCE_CODE]
- `Headers.zig` - Headers object implementation for HTTP headers management. Key: `Headers`, `init / InitOpts`, `append / delete / get / set / has`, `populateHttpHeader`, `JsApi` [SOURCE_CODE]
- `Request.zig` - Fetch Request object and JS-exposed body helpers. Key: `Request`, `Input`, `InitOpts`, `init`, `parseMethod` [SOURCE_CODE]
- `Response.zig` - Fetch Response object implementation and stream helpers. Key: `Response`, `init`, `getBody`, `getText/getJson/arrayBuffer/blob/bytes`, `clone` [SOURCE_CODE]
- `URLSearchParams.zig` - URLSearchParams implementation and utilities. Key: `URLSearchParams`, `init / InitOpts`, `paramsFromString / unescape / escape`, `get / getAll / append / set / delete / toString`, `JsApi` [SOURCE_CODE]
- `WebSocket.zig` - Browser WebSocket web‑API implementation and event dispatch. Key: `init`, `send`, `close`, `dispatchMessageEvent / dispatchOpenEvent / dispatchCloseEvent / dispatchErrorEvent`, `ReadyState / BinaryType` [SOURCE_CODE]
- `XMLHttpRequest.zig` - Implementation of the browser-side XMLHttpRequest API and its network lifecycle. Key: `init`, `send`, `open`, `getResponse`, `handleBlobUrl` [SOURCE_CODE]
- `XMLHttpRequestEventTarget.zig` - EventTarget mixin handling XMLHttpRequest progress and lifecycle callbacks. Key: `XMLHttpRequestEventTarget`, `dispatch`, `DispatchType`, `setOnTimeout` [SOURCE_CODE]

## src/browser/webapi/selector/

- `List.zig` - CSS selector matching and optimized node collection for query APIs. Key: `collect`, `initOne`, `optimizeSelector`, `matches`, `findIdSelector` [SOURCE_CODE]
- `Parser.zig` - CSS selector parser (tokenizer and AST builder). Key: `preprocessInput`, `parseList`, `parse`, `parsePart / pseudoClass / parseNthPattern` [SOURCE_CODE]
- `Selector.zig` - Selector structures and query helper functions. Key: `Selector / Compound / Part / PseudoClass`, `parseLeaky`, `querySelector / querySelectorAll / matches`, `Parsed.query` [SOURCE_CODE]

## src/browser/webapi/storage/

- `Cookie.zig` - Cookie parsing, normalization, storage and retrieval (cookie jar). Key: `parse`, `parseDomain`, `parsePath`, `appliesTo`, `Jar` [SOURCE_CODE]
- `storage.zig` - In-memory implementation of per-origin storage (local/session) and JS bindings. Key: `Shed`, `Bucket`, `Lookup`, `Lookup.JsApi` [SOURCE_CODE]

## src/browser/webapi/streams/

- `ReadableStream.zig` - ReadableStream implementation (streams API). Key: `ReadableStream`, `init / initWithData`, `getReader / cancel / pipeTo / pipeThrough`, `callPullIfNeeded / shouldCallPull`, `AsyncIterator / PipeState` [SOURCE_CODE]
- `ReadableStreamDefaultController.zig` - Controller for ReadableStream handling queueing and pending reads. Key: `enqueue`, `enqueueValue`, `close`, `doError`, `getDesiredSize` [SOURCE_CODE]
- `ReadableStreamDefaultReader.zig` - Default reader for ReadableStream (read/release/cancel). Key: `ReadableStreamDefaultReader`, `init`, `read`, `releaseLock / cancel`, `ReadResult` [SOURCE_CODE]
- `TransformStream.zig` - TransformStream implementation bridging readable and writable streams. Key: `TransformStream`, `init`, `initWithZigTransform`, `transformWrite`, `TransformStreamDefaultController` [SOURCE_CODE]
- `WritableStream.zig` - WritableStream implementation and writer locking semantics. Key: `WritableStream`, `State`, `init`, `getWriter`, `writeChunk` [SOURCE_CODE]
- `WritableStreamDefaultController.zig` - Controller for WritableStream to report errors. Key: `WritableStreamDefaultController`, `init`, `doError` [SOURCE_CODE]
- `WritableStreamDefaultWriter.zig` - Default writer for WritableStream (write/close/release). Key: `WritableStreamDefaultWriter`, `init`, `write / close`, `releaseLock / getClosed / getReady / getDesiredSize` [SOURCE_CODE]

## src/cdp/

- `AXNode.zig` - Accessibility (AX) node serialization for CDP. Key: `Writer`, `writeNode / writeNodeChildren`, `writeAXProperties / writeAXProperty / writeAXValue`, `AXValue / AXProperty` [SOURCE_CODE]
- `CDP.zig` - CDP (Chrome DevTools Protocol) message router and BrowserContext lifecycle manager. Key: `URL_BASE`, `init`, `deinit`, `handleMessage`, `processMessage` [SOURCE_CODE]
- `Node.zig` - CDP node registry, search management, and serialization to DevTools JSON. Key: `Registry`, `Search.List`, `Writer`, `register` [SOURCE_CODE]
- `id.zig` - Utilities to format/parse prefixed CDP identifiers and generate incrementing IDs. Key: `toFrameId / toLoaderId / toRequestId / toInterceptId`, `toPageId`, `Incrementing` [SOURCE_CODE]
- `testing.zig` - CDP test harness: socketpair-based Client + WebSocket frame reader and message expectation helpers. Key: `TestContext`, `context`, `cdp`, `loadBrowserContext`, `processMessage` [TEST]

## src/cdp/domains/

- `accessibility.zig` - CDP Accessibility domain implementation (enable/disable/getFullAXTree). Key: `processMessage`, `getFullAXTree`, `enable` [SOURCE_CODE]
- `browser.zig` - CDP Browser domain handlers: version and window info for DevTools clients. Key: `processMessage`, `getVersion`, `getWindowForTarget`, `CDP_USER_AGENT` [SOURCE_CODE]
- `css.zig` - CDP CSS domain stub that handles enable command. Key: `processMessage` [SOURCE_CODE]
- `dom.zig` - CDP DOM domain implementation: expose and query DOM nodes over DevTools protocol. Key: `processMessage`, `getDocument`, `performSearch`, `dispatchSetChildNodes`, `getContentQuads/getBoxModel` [SOURCE_CODE]
- `emulation.zig` - CDP Emulation domain handlers (mostly no-op) for client compatibility. Key: `processMessage`, `setUserAgentOverride` [SOURCE_CODE]
- `fetch.zig` - CDP Fetch domain: enable request interception and control intercepted requests. Key: `InterceptState`, `requestIntercept`, `continueRequest`, `fulfillRequest`, `continueWithAuth` [SOURCE_CODE]
- `input.zig` - CDP Input domain: simulate keyboard and mouse events via CDP. Key: `dispatchKeyEvent`, `dispatchMouseEvent`, `insertText` [SOURCE_CODE]
- `inspector.zig` - CDP Inspector domain stub (enable/disable). Key: `processMessage` [SOURCE_CODE]
- `log.zig` - CDP Log domain minimal handler (enable/disable). Key: `processMessage` [SOURCE_CODE]
- `lp.zig` - CDP/LP domain handlers: expose Lightpanda page analysis and action RPCs for CDP/MCP.. Key: `processMessage`, `getSemanticTree`, `getMarkdown`, `getInteractiveElements`, `getNodeDetails` [SOURCE_CODE]
- `network.zig` - CDP 'Network' domain implementation: maps CDP network methods/events to internal browser/network state and emits CDP events.. Key: `processMessage`, `setExtraHTTPHeaders`, `cookieMatches`, `deleteCookies`, `getCookies` [SOURCE_CODE]
- `page.zig` - Implements the CDP Page domain: command dispatch, navigation, lifecycle events, and page-scoped CDP events.. Key: `processMessage`, `Frame`, `getFrameTree`, `setLifecycleEventsEnabled`, `addScriptToEvaluateOnNewDocument` [SOURCE_CODE]
- `performance.zig` - CDP Performance domain stub implementing enable/disable. Key: `processMessage` [SOURCE_CODE]
- `runtime.zig` - CDP Runtime domain router forwarding inspector calls and optional debug logging. Key: `processMessage`, `sendInspector`, `logInspector` [SOURCE_CODE]
- `security.zig` - CDP Security domain: toggle certificate verification and basic security calls. Key: `processMessage`, `setIgnoreCertificateErrors` [SOURCE_CODE]
- `storage.zig` - CDP 'Storage' domain: cookie management and CDP serialization for cookie lists.. Key: `processMessage`, `clearCookies`, `getCookies`, `setCookies`, `CdpCookie` [SOURCE_CODE]
- `target.zig` - CDP Target domain implementation and browser context management. Key: `processMessage`, `createTarget`, `attachToTarget / attachToBrowserTarget / doAttachtoTarget`, `disposeBrowserContext / createBrowserContext / getBrowserContexts`, `TargetInfo / AttachToTarget` [SOURCE_CODE]

## src/data/

- `public_suffix_list.zig` - Compile-time public suffix list used for domain parsing [DATA]

## src/html5ever/

- `lib.rs` - Rust FFI entry points wrapping html5ever/html parser for Zig. Key: `html5ever_parse_document`, `html5ever_parse_fragment`, `html5ever_streaming_parser_create/html5ever_streaming_parser_feed/html5ever_streaming_parser_finish/html5ever_streaming_parser_destroy`, `xml5ever_parse_document` [SOURCE_CODE]
- `sink.rs` - html5ever TreeSink implementation that forwards parser events to Zig. Key: `ElementData`, `Sink`, `impl TreeSink for Sink` [SOURCE_CODE]
- `types.rs` - C-compatible types and callback signatures for html5ever-Zig bridge. Key: `CreateElementCallback / other callback type aliases`, `CQualName`, `CAttribute / CAttributeIterator`, `CNodeOrText` [SOURCE_CODE]

## src/mcp/

- `Server.zig` - MCP JSON-RPC server harness for processing requests. Key: `Server`, `init`, `sendResponse`, `sendError` [SOURCE_CODE]
- `protocol.zig` - MCP protocol type definitions, JSON (de)serialization helpers, and unit tests for message formats. Key: `Version`, `Request`, `Response`, `Error`, `ErrorCode` [SOURCE_CODE]
- `resources.zig` - MCP resource registry and page resource streaming (HTML/markdown). Key: `resource_list`, `handleList`, `handleRead`, `ResourceStreamingResult.StreamingText.jsonStringify` [SOURCE_CODE]
- `router.zig` - MCP message reader and dispatcher: parse JSON-RPC lines, route to handlers, and send results/errors. Key: `processRequests`, `handleMessage`, `handleInitialize`, `handlePing`, `Method` [SOURCE_CODE]
- `tools.zig` - MCP tools registry and handlers: tool definitions, argument parsing and tool-call implementations.. Key: `tool_list`, `tool_map`, `ToolStreamingText`, `handleCall`, `handleMarkdown` [SOURCE_CODE]

## src/network/

- `Network.zig` - Network runtime: libcurl-backed HTTP connection pool, websocket pool, poll loop and request submission. Key: `Listener`, `PSEUDO_POLLFDS`, `MAX_TICK_CALLBACKS`, `TickCallback`, `ZigToCurlAllocator` [SOURCE_CODE]
- `Robots.zig` - Robots.txt parsing, compilation and allow/disallow evaluation. Key: `CompiledPattern`, `Rule`, `RobotStore`, `parseRulesWithUserAgent / fromBytes`, `matchPattern / matchInnerPattern / isAllowed` [SOURCE_CODE]
- `WebBotAuth.zig` - Sign HTTP requests using a Web-Bot Auth Ed25519 signing scheme. Key: `parsePemPrivateKey`, `signEd25519`, `signRequest` [SOURCE_CODE]
- `http.zig` - Libcurl-backed connection and HTTP header helpers used by the browser network stack. Key: `curl_version`, `Blob`, `Method`, `Header`, `Headers` [SOURCE_CODE]
- `websocket.zig` - Low-level WebSocket protocol handling and server connection logic. Key: `Reader`, `WsConnection`, `Message`, `processMessages` [SOURCE_CODE]

## src/network/cache/

- `Cache.zig` - Abstract cache API and metadata/parsing helpers for network response caching. Key: `Cache`, `Cache.deinit`, `Cache.get`, `Cache.put`, `CacheControl` [SOURCE_CODE]
- `FsCache.zig` - Filesystem-backed cache implementation: atomic writes, JSON metadata, SHA-256 keys, and striped locking. Key: `FsCache`, `init`, `deinit`, `get`, `put` [SOURCE_CODE]

## src/sys/

- `libcrypto.zig` - C FFI bindings and helpers for libcrypto/OpenSSL primitives. Key: `RAND_bytes`, `EVP_sha256 / EVP_sha384 / EVP_sha512 / EVP_sha1`, `findDigest`, `X25519_keypair / EVP_PKEY_*` [SOURCE_CODE]
- `libcurl.zig` - Zig FFI wrapper and typed bindings for libcurl. Key: `Curl`, `CurlGlobalFlags`, `CurlOption`, `errorFromCode`, `curl_global_init` [SOURCE_CODE]

## src/telemetry/

- `lightpanda.zig` - Telemetry batching and delivery module that batches events, serializes to JSON, and posts to telemetry endpoint.. Key: `URL`, `BUFFER_SIZE`, `MAX_BODY_SIZE`, `init`, `deinit` [SOURCE_CODE]
- `telemetry.zig` - Telemetry initialization and lightweight event recording. Key: `isDisabled`, `TelemetryT`, `getOrCreateId`, `Event` [SOURCE_CODE]


---
*This knowledge base was extracted by [Codeset](https://codeset.ai) and is available via `python .claude/docs/get_context.py <file_or_folder>`*
