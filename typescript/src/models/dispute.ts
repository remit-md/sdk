import type { DisputeStatus } from "./common.js";

export interface Dispute {
  id: string;
  invoiceId: string;
  filer: string;
  reason: string;
  details: string;
  evidenceUri: string;
  chain: string;
  status: DisputeStatus;
  resolution?: string;
  createdAt: number;
  resolvedAt?: number;
}
