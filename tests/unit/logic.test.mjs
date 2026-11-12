// Run: node --test tests/unit/   (Node 22.6+; no packages needed)
import test from 'node:test';
import assert from 'node:assert/strict';
import { endpointAllowed, classify, safeEqual, corsOrigin, identifierKind } from '../../supabase/functions/_shared/logic.ts';
import { crestSpec, square, parseSquare } from '../../public/crest.js';

test('push endpoints: only real push services over https', () => {
  for (const ok of ['https://fcm.googleapis.com/fcm/send/abc', 'https://updates.push.services.mozilla.com/wpush/v2/x',
    'https://web.push.apple.com/QGx', 'https://wns2-by3p.notify.windows.com/w/?token=1']) assert.equal(endpointAllowed(ok), true, ok);
  for (const bad of ['http://fcm.googleapis.com/x', 'https://fcm.googleapis.com.evil.example/x', 'https://evil.example/fcm.googleapis.com',
    'https://169.254.169.254/latest', 'https://user:pw@fcm.googleapis.com/x', 'https://fcm.googleapis.com:8443/x', 'file:///etc/passwd', '', null, 42])
    assert.equal(endpointAllowed(bad), false, String(bad));
});

test('delivery results: success, expired subscription, retry', () => {
  assert.equal(classify(201), 'ok'); assert.equal(classify(410), 'gone'); assert.equal(classify(404), 'gone');
  assert.equal(classify(429), 'retry'); assert.equal(classify(503), 'retry'); assert.equal(classify(undefined), 'retry');
});

test('cron secret comparison and CORS allow-list', () => {
  assert.equal(safeEqual('abc', 'abc'), true); assert.equal(safeEqual('abc', 'abd'), false); assert.equal(safeEqual('abc', 'abcd'), false);
  const list = 'https://turntactics.b-cdn.net, https://turntactics.vercel.app/';
  assert.equal(corsOrigin('https://turntactics.b-cdn.net', list), 'https://turntactics.b-cdn.net');
  assert.equal(corsOrigin('https://turntactics.vercel.app', list), 'https://turntactics.vercel.app');
  assert.equal(corsOrigin('https://evil.example', list), null); assert.equal(corsOrigin(null, list), null);
});

test('sign-in identifier: username or email', () => {
  assert.equal(identifierKind('Ada_99'), 'username'); assert.equal(identifierKind('ada@example.com'), 'email');
  assert.equal(identifierKind('a'), null); assert.equal(identifierKind("x' or 1=1"), null); assert.equal(identifierKind(undefined), null);
});

test('chess coordinates: a1 is lower-left and round-trips to server x/y', () => {
  assert.equal(square(0, 7, 8), 'a1'); assert.equal(square(7, 0, 8), 'h8'); assert.equal(square(14, 14, 15), 'o1'); assert.equal(square(4, 4, 8), 'e4');
  for (const size of [8, 11, 15]) for (let x = 0; x < size; x++) for (let y = 0; y < size; y++)
    assert.deepEqual(parseSquare(square(x, y, size), size), { x, y });
});

test('crests: stable per room and seat, distinct charge for all twenty seats, no account data needed', () => {
  for (const room of ['ABCDEF123456', 'ZZ99ZZ99ZZ99', '0123456789AB']) {
    const charges = new Set();
    for (let seat = 0; seat < 20; seat++) {
      const spec = crestSpec(room, seat);
      assert.deepEqual(spec, crestSpec(room, seat));
      assert.notEqual(spec.field, spec.division.color);
      charges.add(spec.charge.name);
    }
    assert.equal(charges.size, 20);
  }
  assert.notDeepEqual(crestSpec('ABCDEF123456', 0), crestSpec('ZZ99ZZ99ZZ99', 0));
});
