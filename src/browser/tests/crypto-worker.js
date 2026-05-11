// Exercises crypto APIs inside a worker. Posts 'ready' once the message
// handler is wired so the page knows it can send a command without racing
// worker startup. Receives the command, runs the crypto operation, and
// posts the result back.
self.onmessage = async function(e) {
  const cmd = e.data;
  try {
    if (cmd.kind === 'getRandomValues') {
      const ta = new Uint8Array(32);
      const same = crypto.getRandomValues(ta) === ta;
      const uniq = new Set(Array.from(ta));
      postMessage({ ok: true, same, looks_random: uniq.size > 8 });
      return;
    }

    if (cmd.kind === 'randomUUID') {
      const uuid = crypto.randomUUID();
      const regex = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
      postMessage({ ok: true, type: typeof uuid, length: uuid.length, valid: regex.test(uuid) });
      return;
    }

    if (cmd.kind === 'digest') {
      const buffer = await crypto.subtle.digest('sha-256', new TextEncoder().encode('over 9000'));
      const hex = [...new Uint8Array(buffer)].map(x => x.toString(16).padStart(2, '0')).join('');
      postMessage({ ok: true, hex });
      return;
    }

    if (cmd.kind === 'hmac') {
      const key = await crypto.subtle.generateKey(
        { name: 'HMAC', hash: { name: 'SHA-512' } },
        true,
        ['sign', 'verify'],
      );
      const raw = await crypto.subtle.exportKey('raw', key);
      const encoder = new TextEncoder();
      const signature = await crypto.subtle.sign('HMAC', key, encoder.encode('Hello, world!'));
      const verified = await crypto.subtle.verify(
        { name: 'HMAC' },
        key,
        signature,
        encoder.encode('Hello, world!'),
      );
      postMessage({
        ok: true,
        key_type: typeof key,
        raw_byte_length: raw.byteLength,
        is_array_buffer: signature instanceof ArrayBuffer,
        verified,
      });
      return;
    }

    if (cmd.kind === 'x25519') {
      const { privateKey, publicKey } = await crypto.subtle.generateKey(
        { name: 'X25519' },
        true,
        ['deriveBits'],
      );
      const sharedKey = await crypto.subtle.deriveBits(
        { name: 'X25519', public: publicKey },
        privateKey,
        128,
      );
      postMessage({
        ok: true,
        private_key_type: typeof privateKey,
        public_key_type: typeof publicKey,
        shared_byte_length: sharedKey.byteLength,
      });
      return;
    }

    if (cmd.kind === 'generateKey-rejection') {
      let err_name = null;
      try {
        await crypto.subtle.generateKey({ name: 'AES-CBC', length: 128 }, true, ['sign']);
      } catch (err) {
        err_name = err.name;
      }
      postMessage({ ok: true, err_name });
      return;
    }

    postMessage({ ok: false, err: 'unknown command' });
  } catch (err) {
    postMessage({ ok: false, err: String(err), stack: err.stack });
  }
};

postMessage({ ready: true });
