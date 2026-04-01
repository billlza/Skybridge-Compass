import { clsx, ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function generateNebulaId() {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  let rawId = 0n;

  for (const byte of bytes) {
    rawId = (rawId << 8n) | BigInt(byte);
  }

  const year = new Date().getUTCFullYear();
  const suffix = rawId.toString(36).toUpperCase().padStart(12, '0').slice(-12);

  return `NEBULA-${year}-${suffix}`;
}
