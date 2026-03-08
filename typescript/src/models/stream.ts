import type { StreamStatus } from "./common.js";

export interface Stream {
  id: string;
  payer: string;
  payee: string;
  ratePerSecond: number;
  maxDuration: number; // seconds
  maxTotal?: number;
  totalStreamed: number;
  chain: string;
  status: StreamStatus;
  startedAt: number;
  closedAt?: number;
}
