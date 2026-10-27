import { createRemoteJWKSet, jwtVerify } from "jose";

const APPLE_JWKS = createRemoteJWKSet(
  new URL("https://appleid.apple.com/auth/keys")
);

export interface AppleTokenClaims {
  sub: string;
  email?: string;
  email_verified?: boolean;
}

export async function verifyAppleIdentityToken(
  identityToken: string
): Promise<AppleTokenClaims> {
  const { payload } = await jwtVerify(identityToken, APPLE_JWKS, {
    issuer: "https://appleid.apple.com",
    audience: process.env.APPLE_BUNDLE_ID,
  });

  if (!payload.sub) throw new Error("Missing sub in Apple token");

  return {
    sub: payload.sub,
    email: payload.email as string | undefined,
    email_verified: payload.email_verified as boolean | undefined,
  };
}
