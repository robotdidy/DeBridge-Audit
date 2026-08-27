/*
 * Local replay of the validator failure path described in
 * debridge-node/src/modules/chain/scanning/services/{SubmissionIdValidationService,
 * SubmissionProcessingService,AddNewEventsAction}.ts.
 *
 * Run with DEBRIDGE_CRYPTO pointing at the exact 4.5.5 crypto.js bundle, e.g.
 *   $env:DEBRIDGE_CRYPTO='C:\\...\\solana-utils-455\\package\\dist\\cjs\\crypto.js'
 *   node .\debridge_scanner_replay.js
 */

const cryptoPath = process.env.DEBRIDGE_CRYPTO;
if (!cryptoPath) {
  throw new Error('Set DEBRIDGE_CRYPTO to @debridge-finance/solana-utils@4.5.5/dist/cjs/crypto.js');
}

const { hashSubmissionIdRaw } = require(cryptoPath);

const base = {
  receiver: '0x1111111111111111111111111111111111111111',
  debridgeId: '0x2222222222222222222222222222222222222222222222222222222222222222',
  sourceChainId: 1,
  targetChainId: 137,
  amount: '1',
  nonce: '1',
  autoParams: {
    executionFee: '0',
    fallbackAddress: '0x3333333333333333333333333333333333333333',
    nativeSender: '0x4444444444444444444444444444444444444444',
    data: '0x',
  },
};

const poison = { id: 'poison', block: 101, flags: '18446744073709551616' }; // 1 << 64
const normal = { id: 'normal', block: 102, flags: '0' };
const state = {
  latestBlock: 100,
  attemptsByChainId: 0,
  saved: [],
  providers: { A: true, B: true },
  trace: [],
};

function validate(event) {
  try {
    hashSubmissionIdRaw({ ...base, autoParams: { ...base.autoParams, flags: event.flags } });
    state.attemptsByChainId = 0;
    return { status: true };
  } catch (error) {
    // Exact service behavior: catch and return false without incrementing attempts.
    return { status: false, error: String(error.message || error) };
  }
}

function chooseProvider() {
  // Web3Service iterates active providers first and failed providers second.
  const order = [...Object.keys(state.providers).filter((p) => state.providers[p]), ...Object.keys(state.providers).filter((p) => !state.providers[p])];
  const provider = order[0];
  // A healthy eth_blockNumber check reactivates a previously failed provider.
  state.providers[provider] = true;
  return provider;
}

function processPage(provider, events) {
  for (const event of events) {
    const result = validate(event);
    state.trace.push({ provider, event: event.id, validation: result });
    if (!result.status) {
      // SubmissionProcessingService returns ERROR_SUBMISSION_VALIDATION;
      // AddNewEventsAction breaks before processing the next event/page.
      state.providers[provider] = false;
      return 'ERROR_SUBMISSION_VALIDATION';
    }
    state.saved.push(event.id);
  }
  state.latestBlock = 102;
  return 'SUCCESS';
}

for (let tick = 1; tick <= 4; tick += 1) {
  const provider = chooseProvider();
  const status = processPage(provider, [poison, normal]);
  state.trace.push({ tick, provider, status, latestBlock: state.latestBlock, saved: [...state.saved], attempts: state.attemptsByChainId });
}

if (state.latestBlock !== 100 || state.saved.length !== 0 || state.attemptsByChainId !== 0 || state.trace.some((x) => x.event === 'normal')) {
  throw new Error(`unexpected replay state: ${JSON.stringify(state)}`);
}

console.log(JSON.stringify({
  result: 'poison event pins the page; normal event is never reached',
  poisonFlags: poison.flags,
  trace: state.trace,
  final: {
    latestBlock: state.latestBlock,
    saved: state.saved,
    attemptsByChainId: state.attemptsByChainId,
    providers: state.providers,
  },
}, null, 2));
