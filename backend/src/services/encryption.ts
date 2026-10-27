import { createCipheriv, createDecipheriv, randomBytes } from "crypto";

const ALGORITHM = "aes-256-gcm";
function getKey(): Buffer {
  const hex = process.env.ENCRYPTION_KEY;
  if (!hex) throw new Error("ENCRYPTION_KEY env var is not set");
  return Buffer.from(hex, "hex");
}

export interface Encrypted {
  ciphertext: string;
  iv: string;
  authTag: string;
}

export function encrypt(plaintext: string): Encrypted {
  const iv = randomBytes(12);
  const cipher = createCipheriv(ALGORITHM, getKey(), iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return {
    ciphertext: encrypted.toString("base64"),
    iv: iv.toString("base64"),
    authTag: cipher.getAuthTag().toString("base64"),
  };
}

export function decrypt(enc: Encrypted): string {
  const decipher = createDecipheriv(ALGORITHM, getKey(), Buffer.from(enc.iv, "base64"));
  decipher.setAuthTag(Buffer.from(enc.authTag, "base64"));
  return Buffer.concat([
    decipher.update(Buffer.from(enc.ciphertext, "base64")),
    decipher.final(),
  ]).toString("utf8");
}

export function encryptToken(plaintext: string): { enc: string; iv: string } {
  const result = encrypt(plaintext);
  // Store authTag appended to ciphertext for compactness in the DB
  const combined = Buffer.from(result.authTag, "base64").toString("hex") +
    ":" +
    result.ciphertext;
  return { enc: combined, iv: result.iv };
}

export function decryptToken(enc: string, iv: string): string {
  const [authTagHex, ciphertext] = enc.split(":");
  return decrypt({
    ciphertext,
    iv,
    authTag: Buffer.from(authTagHex, "hex").toString("base64"),
  });
}
