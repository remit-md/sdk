import type { BountyStatus } from "./common.js";

export interface BountySubmission {
  submitter: string;
  evidenceUri: string;
  submittedAt: number;
  accepted?: boolean;
}

export interface Bounty {
  id: string;
  poster: string;
  amount: number;
  task: string;
  chain: string;
  status: BountyStatus;
  validation: "poster" | "oracle" | "multisig";
  maxAttempts: number;
  submissions: BountySubmission[];
  winner?: string;
  createdAt: number;
  deadline: number;
}
