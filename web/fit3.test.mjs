// node web/fit3.test.mjs
import * as P from "./fit3.js";
let ok = 0, bad = 0;
const check = (c, n) => (c ? ok++ : (bad++, console.log("FAIL", n)));
const eq = (a, b) => P.hex(a) === P.hex(b);

const wi = P.encodeMessage(1, P.watchInfoRequest, 500)[0];
check(P.hex(wi) === "000dc5c10040010101040200000005000e60ea", "watchInfo vector " + P.hex(wi));
const d = P.decodeFrame(wi);
check(d.service === 1 && eq(d.payload, P.watchInfoRequest), "decode");

const cap = new Array(105).fill(0); cap[0] = 104; cap[1] = 0x14; cap[0x2c] = 1; cap[0x2d] = 0xf4;
check(P.isCapabilityRequest(cap) && P.negotiatedTransportMtu(cap) === 500, "capability");
check(P.capabilityResponse(cap)[1] === 0x15, "capability response");

for (const mtu of [120, 180, 300, 500]) {
  const msg = Array.from({ length: 900 }, (_, i) => i & 0xff);
  const frames = P.encodeMessage(7, msg, mtu);
  const r = new P.Reassembler(); let out = null;
  for (const f of frames) out = r.push(P.decodeFrame(f)) || out;
  check(frames.every((f) => f.length <= mtu) && out && out.service === 7 && eq(out.message, msg), "fragments " + mtu);
}

const init = P.initSettingsRequest(new Date(1_700_000_000_000), 3 * 3600, 57);
check(P.hex(init) === "830139000200030a313730303030303030300400302a0501", "init settings " + P.hex(init));

const n = P.newNotification({ sequence: 42, title: "Hi", text: "Body", appName: "Fit3", packageName: "io.test", whenMillis: 1234, appId: 20 });
check(P.hex(n) === "800a0001012a0000000602323002d20400000000000003024869040400426f64790e04466974330f0110001207696f2e74657374", "notification " + P.hex(n));
check(P.parseBattery([0x42, 5, 58, 6, 0]).percent === 58 && P.parseBattery([0x41, 5, 58, 6, 0]) === null, "battery");
check(P.parseAck([0x40, 1, 42, 0, 0, 0, 11, 1]).sequence === 42, "ack");
check(P.findSoftwareVersion([...Buffer.from("xxR390XXU0AZA3\0")]) === "R390XXU0AZA3", "version");
console.log(`${ok} passed, ${bad} failed`);
process.exit(bad ? 1 : 0);
