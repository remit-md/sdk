// Core classes
export { RemitClient } from "./client.js";
export { Wallet } from "./wallet.js";
export type {
  WalletOptions,
  OpenTabOptions,
  OpenStreamOptions,
  PostBountyOptions,
  PlaceDepositOptions,
} from "./wallet.js";

// Signers
export { PrivateKeySigner } from "./signer.js";
export type { Signer, TypedDataDomain, TypedDataTypes } from "./signer.js";

// Errors
export {
  RemitError,
  fromErrorCode,
  InvalidSignatureError,
  NonceReusedError,
  TimestampExpiredError,
  UnauthorizedError,
  InsufficientBalanceError,
  BelowMinimumError,
  EscrowNotFoundError,
  EscrowAlreadyFundedError,
  EscrowExpiredError,
  InvalidInvoiceError,
  DuplicateInvoiceError,
  SelfPaymentError,
  InvalidPaymentTypeError,
  TabDepletedError,
  TabExpiredError,
  TabNotFoundError,
  StreamNotFoundError,
  RateExceedsCapError,
  BountyExpiredError,
  BountyClaimedError,
  BountyMaxAttemptsError,
  BountyNotFoundError,
  ChainMismatchError,
  ChainUnsupportedError,
  RateLimitedError,
  CancelBlockedClaimStartError,
  CancelBlockedEvidenceError,
  VersionMismatchError,
  NetworkError,
} from "./errors.js";

// Models
export * from "./models/index.js";

// Testing utilities
export { MockRemit, MockWallet } from "./testing/mock.js";
export { LocalChain } from "./testing/local.js";

// x402 client middleware
export { X402Client, AllowanceExceededError } from "./x402.js";
export type { X402ClientOptions } from "./x402.js";

// Integrations
export { remitTools } from "./integrations/vercel-ai.js";
export type { RemitToolDescriptor } from "./integrations/vercel-ai.js";
