// Galaxy Fit3 SAP protocol – JavaScript port of Fit3Kit (same vectors, see fit3.test.mjs).
// Derived from yuriyurin/Fit3-App (GPL-3.0-only).

export const SERVICE = { OOBE: 1, NOTIFICATIONS: 7, HEALTH: 10, SETTINGS: 11 };
export const SERVICE_NAMES = { 1: "OOBE", 5: "WEATHER", 6: "FACE", 7: "NOTI", 9: "MEDIA", 10: "HEALTH", 11: "SETTINGS" };

export const GATT = {
  service: 0x1a1a,
  notify: "797ae4e9-2e58-4fe8-b48d-b5c79599fb9b",
  write: "63e30bad-4206-4596-839f-e47cbf7a4b5d",
};

export const watchInfoRequest = [0x01, 0x04, 0x02, 0, 0, 0, 0x05, 0, 0x0e];
export const deviceStatusRequest = [0x02, 0x01, 0x00];
export const userAgreementRequest = [0x84, 0x01, 0x01];
export const batteryRequest = [0x02];
export const iconCapabilityRequest = [0x0d];

export const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
export const fromHex = (s) => s.match(/../g).map((x) => parseInt(x, 16));

export function crc16(data) {
  let crc = 0;
  for (const byte of data) {
    crc ^= byte;
    for (let i = 0; i < 8; i++) crc = crc & 1 ? (crc >>> 1) ^ 0xa001 : crc >>> 1;
  }
  return crc & 0xffff;
}
const crcBytes = (d) => { const v = crc16(d); return [v >>> 8, v & 0xff]; };

export const isCapabilityRequest = (d) => d.length === 105 && d[1] === 0x14;
export const negotiatedTransportMtu = (r) => (r[0x2c] << 8) | r[0x2d];
export function capabilityResponse(r) {
  if (r.length !== 105 || r[0] !== 104 || r[1] !== 0x14) throw new Error("not a capability request");
  const out = Array.from(r); out[1] = 0x15; return out;
}

function encodeBody(body, mtu) {
  if (mtu < 256) return [body.length, body.length, ...body, ...crcBytes(body)];
  const len = [body.length >>> 8, body.length & 0xff];
  return [...len, ...crcBytes(len), ...body, ...crcBytes(body)];
}

export function encodeMessage(service, message, mtu, maxFrame = mtu) {
  const limit = Math.min(mtu, maxFrame);
  const single = encodeBody([0, 0x40, service, service, ...message], mtu);
  if (single.length <= limit) return [single];
  const prefix = mtu < 256 ? 2 : 4;
  const firstCap = limit - prefix - 2 - 4, contCap = limit - prefix - 2 - 2;
  const frames = [];
  let off = Math.min(firstCap, message.length), seq = 0;
  frames.push(encodeBody([2, seq, service, service, ...message.slice(0, off)], mtu));
  seq++;
  while (off < message.length) {
    if (seq > 15) throw new Error("too many fragments");
    const take = Math.min(contCap, message.length - off);
    const kind = off + take >= message.length ? 3 : 2;
    frames.push(encodeBody([kind << 1, seq, ...message.slice(off, off + take)], mtu));
    off += take; seq++;
  }
  return frames;
}

export function decodeFrame(f) {
  if (f.length < 8) throw new Error("short frame");
  const shortOk = f[0] === f[1] && f[0] + 4 === f.length;
  const longLen = (f[0] << 8) | f[1];
  const lc = crcBytes([f[0], f[1]]);
  const longOk = f.length >= 10 && longLen + 6 === f.length && f[2] === lc[0] && f[3] === lc[1];
  if (!shortOk && !longOk) throw new Error("bad prefix");
  const body = f.slice(shortOk ? 2 : 4, f.length - 2);
  const c = crcBytes(body);
  if (f[f.length - 2] !== c[0] || f[f.length - 1] !== c[1]) throw new Error("bad crc");
  const kind = (body[0] >>> 1) & 3, first = kind === 0 || kind === 1;
  if (body[0] >>> 6) throw new Error("control frame");
  return {
    kind, sequence: body[1] & 0x0f, stream: body[1] >>> 5,
    service: first ? body[2] : null, payload: body.slice(first ? 4 : 2),
  };
}

export class Reassembler {
  constructor() { this.reset(); }
  reset() { this.service = null; this.stream = -1; this.next = 0; this.data = []; }
  push(fr) {
    if (fr.kind === 0) { this.reset(); return { service: fr.service, message: fr.payload }; }
    if (fr.kind === 1) {
      this.reset();
      if (fr.sequence !== 0) return null;
      Object.assign(this, { service: fr.service, stream: fr.stream, next: 1, data: [...fr.payload] });
      return null;
    }
    if (this.service == null || fr.stream !== this.stream || fr.sequence !== this.next) { this.reset(); return null; }
    this.data.push(...fr.payload); this.next++;
    if (fr.kind !== 3) return null;
    const out = { service: this.service, message: this.data }; this.reset(); return out;
  }
}

export function initSettingsRequest(date, offsetSeconds, localeId, hour24 = true) {
  const epoch = Array.from(new TextEncoder().encode(String(Math.floor(date.getTime() / 1000))));
  const a = Math.abs(offsetSeconds);
  return [0x83, 1, localeId & 0xff, localeId >>> 8, 2, 0, 3, epoch.length, ...epoch,
    4, offsetSeconds < 0 ? 1 : 0, a & 0xff, (a >>> 8) & 0xff, 5, hour24 ? 1 : 0];
}

export const oobeResponseId = (m) => (m.length && m[0] >= 0x41 && m[0] <= 0x44 ? m[0] & 0x3f : null);

export function parseBattery(m) {
  if (!m.length || (m[0] & 0x40) === 0 || (m[0] & 0x3f) !== 2) return null;
  let level = null, charging = null;
  for (let i = 1; i + 1 < m.length; i += 2) {
    if (m[i] === 5 && m[i + 1] <= 100) level = m[i + 1];
    if (m[i] === 6 && m[i + 1] <= 3) charging = m[i + 1];
  }
  if (level == null || charging == null)
    for (let p = 1; p < m.length - 1; p++) {
      if (m[p] === 5 && m[p + 1] <= 100) level = m[p + 1];
      if (m[p] === 6 && m[p + 1] <= 3) charging = m[p + 1];
    }
  return level == null || charging == null ? null : { percent: level, charging: charging !== 0 };
}

function utf8Prefix(s, max) {
  const enc = new TextEncoder(); const out = [];
  for (const ch of s) { const b = enc.encode(ch); if (out.length + b.length > max) break; out.push(...b); }
  return out;
}
const le32 = (v) => [v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff];
function le64(n) { const out = []; let v = BigInt(n); for (let i = 0; i < 8; i++) { out.push(Number(v & 0xffn)); v >>= 8n; } return out; }
const shortText = (id, s) => { const b = utf8Prefix(s, 60); return [id, b.length, ...b]; };

export function newNotification({ sequence, title, text, appName, packageName, whenMillis, appId, popup = true, category }) {
  const body = utf8Prefix(text, 100);
  const out = [0x80 | (popup ? 0 : 5), 10 + (category ? 1 : 0),
    0, 1,
    1, ...le32(sequence),
    ...shortText(6, String(appId)),
    2, ...le64(whenMillis),
    ...shortText(3, title),
    4, body.length & 0xff, body.length >>> 8, ...body,
    ...shortText(14, appName),
    15, 1, 16, 0];
  if (category) out.push(...shortText(12, category));
  out.push(...shortText(18, packageName));
  return out;
}

export function parseAck(m) {
  if (m.length !== 8 || m[0] !== 0x40 || m[1] !== 1 || m[6] !== 11) return null;
  return { sequence: m[2] | (m[3] << 8) | (m[4] << 16) | (m[5] << 24), accepted: m[7] === 1 };
}

export function findSoftwareVersion(m) {
  const s = String.fromCharCode(...m.map((b) => (b < 128 ? b : 46)));
  const r = s.match(/R390[A-Z0-9]{7,12}/);
  return r ? r[0] : null;
}
