import Anthropic from "@anthropic-ai/sdk";

let client: Anthropic | null = null;

export function askConfigured(): boolean {
  return Boolean(process.env.ANTHROPIC_API_KEY);
}

export function getAnthropic(): Anthropic | null {
  if (!askConfigured()) return null;
  client ??= new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY, maxRetries: 1, timeout: 45_000 });
  return client;
}
