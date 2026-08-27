# deBridge submission draft - High

## Title

Permissionless high-bit `flags` in `deBridgeGate.sendMessage` pins vulnerable validator scanners and freezes subsequent source-chain transfers

## Severity and impact

**Suggested severity:** High - temporary freezing of funds (more than one day), subject to confirmation that the affected validator fleet runs the vulnerable implementation and that the resulting source-chain freeze persists beyond one day.

The attack does not demonstrate unauthorized claims, signature bypass, protocol insolvency, or theft. It prevents later source-chain events from being persisted, signed, and finalized. For canonical-to-secondary transfers, the victim's canonical/native/ERC-20 principal is already held by the source Gate while destination deAssets are not minted. For secondary-to-canonical transfers, the victim's deAssets are burned while the canonical/native/ERC-20 release is not completed.

## Affected in-scope target and assets

The smart-contract entry point is the source-chain **deBridgeGate Proxy**. The Polygon/MATIC reproduction uses:

`0x43dE2d77BF8027e25dBD179B491e8d64f38398aA`

The current Immunefi scope page also lists deBridgeGate Proxy targets for ETH, BSC, HECO, and Arbitrum. The poison `sendMessage` itself bridges zero principal; the affected assets are users' subsequent transfer principal handled by the source Gate.

## Root cause

The public five-argument `sendMessage` accepts an arbitrary `uint256 _flags` value. Unknown high bits are not rejected and the complete flags word is included in the submission hash.

The validator implementation shipped in the publicly verifiable `debridge-node` images builds the same submission ID through `@debridge-finance/solana-utils` 4.5.5. In `getShortcutFromAutoParams`, that SDK evaluates the flags using a JavaScript number conversion:

```js
const flags = BigInt(new BN(params.autoParams?.flags || 0).toNumber());
```

For a permissionless flags value such as `1 << 64` (`18446744073709551616`), this throws:

```text
Number can only safely store up to 53 bits
```

This is still the code bundled in the `debridge-node:2.8.4` and `debridge-node:2.8.5` images checked on 2026-08-27. A newer standalone `@debridge-finance/solana-utils` release, 6.2.3, now uses an arbitrary-precision conversion in this line, but no public validator image or mainnet launcher update checked here includes that release. The production validator fleet may also use a private override; that deployment fact must be confirmed before describing the freeze as a proven production-wide effect.

## Attack steps

1. The attacker calls the public `deBridgeGate.sendMessage` with nonempty target and calldata, a valid native fee, and `_flags = 18446744073709551616`.
2. The source Gate accepts the transaction and emits a valid `Sent` event.
3. The attacker or a victim creates a normal transfer after that event on the same source chain.
4. A vulnerable validator scans the page. Submission-ID validation throws on the poison event.
5. `SubmissionIdValidationService` catches the exception and returns `status: false` without increasing the retry counter.
6. `SubmissionProcessingService` returns `ERROR_SUBMISSION_VALIDATION`; `AddNewEventsAction` breaks before the normal event and does not advance `latestBlock`.
7. Every retry re-reads the same poison event. Provider failover does not help because the event and exception are deterministic.

## Reproduction evidence

The attached local replay (`debridge_scanner_replay.js`) uses the exact SDK exception and node control flow. Four ticks select providers `A, B, A, A`; every tick reports the same validation error, `latestBlock` remains `100`, no submission is saved, and the normal event is never reached.

The focused Foundry test `testHighReservedFlagIsAcceptedBySourceHashPath` passes, confirming that the source Gate accepts the high reserved bit and includes it in the valid on-chain hash path.

The old `4.5.5` runtime was also executed directly with `flags = 18446744073709551616`; it raised `Number can only safely store up to 53 bits`. The same input passed through the standalone `6.2.3` runtime and produced a submission ID, confirming that 6.2.3 appears to repair this particular precision failure.

## 27 August 2026 deployment and known-issue recheck

### Live Polygon Gate

The active Polygon Gate proxy `0x43dE2d77BF8027e25dBD179B491e8d64f38398aA` returned `421` from `version()` on public Polygon RPC endpoints. A read-only call to the five-argument `sendMessage` overload with a supported destination, non-empty target and calldata, the required `0.5` ETH native fee, and `_flags = 18446744073709551616` returned the normal submission ID:

```text
0x0647a798081e52790a0df936c22cce9db353195d9d3b61e3619944b0cc7c5c8c
```

This confirms live on-chain acceptance of the poison value. It was an `eth_call`; no mainnet transaction was sent and no state changed.

### Public validator images

The newer Docker tag `debridgefinance/debridge-node:2.8.5` was published on 2026-08-19 with digest `sha256:03e8828815778a60972413f55cfe8b972b650dd9f29a330f0a65f59004037844`. Direct inspection of its image layers showed:

- `/app/package.json` reports node version `2.8.5` but pins `@debridge-finance/solana-utils` to `4.5.5`.
- `/app/node_modules/@debridge-finance/solana-utils/dist/cjs/crypto.js` still contains the unsafe `BN.toNumber()` conversion.
- The compiled validation/processing services still catch the exception, return `ERROR_SUBMISSION_VALIDATION`, leave the cursor unchanged, and break page processing; there is no high-bit quarantine or skip path.

The official [mainnet launcher compose](https://github.com/debridge-finance/debridge-launcher/blob/mainnet/docker-compose.yml) still pins `debridge-node:2.8.4@sha256:39a50346d4603713c404807b55da036aa5c27867409c6f601e2b410cda8d10a1`. The Docker tag listing is available at [debridge-node tags](https://hub.docker.com/r/debridgefinance/debridge-node/tags).

### Standalone SDK status

The newest npm release is `@debridge-finance/solana-utils@6.2.3`, published on 2026-08-27. Its `crypto.js` changes the conversion to `BigInt(toBN(flags).toString())`, and the same `2^64` test completes successfully. This is an apparent library-level fix for the precision crash, not evidence that the validator fleet has been upgraded. The validator images checked above still carry 4.5.5.

### Public tracking review

No public issue or pull request was found for high-bit flags, reserved-flag poisoning, `BN.toNumber()`, or this submission-ID crash. The open [debridge-node issue list](https://github.com/debridge-finance/debridge-node/issues) contains an unrelated archive-RPC scanner issue (#89); the open [PR #90](https://github.com/debridge-finance/debridge-node/pull/90) addresses provider failover and does not fix this arithmetic or cursor path.

### Updated disposition

The issue remains live at the Gate boundary and in the official public node images. The standalone SDK now appears to contain a fix, so the precise submission wording should be: **unfixed in the public validator deployment path; likely fixed in the latest standalone SDK; production-fleet exposure requires operator confirmation**. Keep the impact as a conditional High temporary freeze, not Critical theft, unauthorized claim, or insolvency. Before submission, request the active validator image digests or confirmation that no private SDK override has been deployed.

## Why this is a fund-freezing impact

The poison transaction itself carries zero bridged principal, but it blocks later `Sent` events from the same source scanner. Those later users have already transferred canonical assets into the Gate or burned source deAssets. They cannot receive the destination-side asset until validator processing is restored.

The outage can continue indefinitely while all relevant validators retain the vulnerable binary. It is nevertheless recoverable by deploying an arbitrary-precision SDK fix or by quarantining the poison event and repairing scanner progress; therefore this draft does not claim Critical permanent freezing, unauthorized claim, or insolvency.

## Current mitigations and limitations

- RPC-provider failover does not mitigate the deterministic SDK exception.
- `maxAttemptsSubmissionIdCalculation` does not auto-pause this path because the caught exception leaves the attempt counter at zero.
- JWT-protected validator pause/start/rescan controls permit operator intervention, but there is no automatic event quarantine or skip.
- The Gate's privileged emergency pause can stop new poison events but does not itself repair scanner progress.

## Recommended fix

1. Update every validator image to a release that includes the arbitrary-precision conversion (the standalone SDK 6.2.3 change is the minimum code-level repair), and replace all other unsafe numeric conversions of `uint256` fields.
2. Reject or explicitly handle unknown flag bits at the source/validator boundary.
3. After a bounded retry count, quarantine one invalid event and advance processing safely instead of pinning the entire source page.
4. Add regression tests for values above `Number.MAX_SAFE_INTEGER`, including `1 << 64` and `2^256 - 1` where applicable.

## Scope evidence

- Immunefi scope lists High temporary freezing of funds for more than one day and the deBridgeGate Proxy targets: https://immunefi.com/bug-bounty/debridge/scope/
- Program information focuses on user principal locked by freezing: https://immunefi.com/bug-bounty/debridge/information/
- Preserve the supplied deBridge support-chat screenshot/transcript stating that validator and block-processing vulnerabilities fall under the bounty program.

## Information to attach before submission

- Exact source chain and Gate proxy address used in the final PoC.
- The replay script and unmodified console output.
- Foundry test output and source-hash assertion.
- Official validator image digest/configuration, or a clear statement that production deployment confirmation is pending.
- The exact active validator image digests and whether they include the standalone `solana-utils` 6.2.3 precision fix.
- Screenshot/transcript metadata (date, support identity/channel, and full conversation context).
- A concrete example showing the victim's source principal locked or deAsset burned after the poison event.
