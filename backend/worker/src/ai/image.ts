/** JPEG checks and base64 helpers for the photo the phone sends. */

export const MAX_SIDE = 768;
export const MAX_IMAGE_BYTES = 2 * 1024 * 1024;

const SOF = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);

/** Width/height from the first SOF marker, or null if this is not a readable JPEG. */
export function jpegSize(bytes: Uint8Array): { width: number; height: number } | null {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let i = 2;
  while (i + 3 < bytes.length) {
    if (bytes[i] !== 0xff) return null;
    let marker = bytes[i + 1]!;
    while (marker === 0xff && i + 2 < bytes.length) {
      i++;
      marker = bytes[i + 1]!;
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      i += 2;
      continue;
    }
    const length = (bytes[i + 2]! << 8) | bytes[i + 3]!;
    if (SOF.has(marker)) {
      if (i + 8 >= bytes.length) return null;
      const height = (bytes[i + 5]! << 8) | bytes[i + 6]!;
      const width = (bytes[i + 7]! << 8) | bytes[i + 8]!;
      return width > 0 && height > 0 ? { width, height } : null;
    }
    if (length < 2) return null;
    i += 2 + length;
  }
  return null;
}

export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

/** Decodes plain base64 or a `data:image/jpeg;base64,` URL; null when malformed. */
export function fromBase64(input: string): Uint8Array | null {
  const comma = input.startsWith("data:") ? input.indexOf(",") : -1;
  const body = (comma >= 0 ? input.slice(comma + 1) : input).replace(/\s+/g, "");
  try {
    const binary = atob(body);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}
