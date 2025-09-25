[README.md](https://github.com/user-attachments/files/22549273/README.md)
# PikiPiki — Mini Prediction Market (Clarity)

A minimal STX-collateralized prediction market written in Clarity. Users can:
- Create markets with an end block.
- Buy YES/NO shares by depositing STX 1:1.
- Settle resolved markets to YES or NO.
- Redeem winnings pro-rata from the total pool.

This is a simple, educational contract and omits many production features (oracle integrations, access control, AMM pricing, fees, etc.).


## Contents
- Overview and Mechanics
- Data Model
- Constants and Limits
- Public Functions
- Read-only Functions
- Error Codes
- Example Workflow (Clarinet)
- Deployment and Development
- Security Notes and Limitations
- Known Issues and Suggested Fix


## Overview and Mechanics

- Market lifecycle:
  1) create(duration): Opens a new market with end = current block + duration.
  2) buy-yes / buy-no: Users deposit STX; shares of the selected side increase by the deposited amount.
  3) settle(id, outcome): After the market end, set the final outcome (true = YES won, false = NO won).
  4) redeem(id): Winning side holders redeem a pro-rata share of the total pool.

- Pricing: The contract does not enforce a bonding curve; it simply tracks pooled STX on each side. A read-only helper get-market-price returns a percentage estimate = yes / (yes+no) * 100 (or 50% if no trades).


## Data Model

- Data variable:
  - market-id: uint — monotonically increasing market identifier.

- Maps:
  - markets: {id} -> {end: uint, settled: bool, outcome: bool}
    - end: block height when trading stops and settlement becomes possible.
    - settled: whether settled has been called.
    - outcome: final outcome (true = YES, false = NO) once settled.
  - pool: {id} -> {yes: uint, no: uint}
    - yes/no: total STX deposited in each side.
  - yes-shares: {id, who} -> {amt: uint}
  - no-shares: {id, who} -> {amt: uint}
    - amt: user’s shares on that side (1 share per STX deposited).


## Constants and Limits

- MAX-DURATION = 144000 blocks (~100 days)
- MIN-DURATION = 144 blocks (~1 day)
- MAX-MARKET-ID = 1,000,000

- Error constants:
  - ERR-MARKET-EXPIRED = 100
  - ERR-MARKET-ALREADY-SETTLED = 101
  - ERR-MARKET-NOT-SETTLED = 102
  - ERR-NO-SHARES = 103
  - ERR-MARKET-NOT-FOUND = 104
  - ERR-TRANSFER-FAILED = 105
  - ERR-INVALID-AMOUNT = 106
  - ERR-MARKET-NOT-EXPIRED = 107
  - ERR-INVALID-DURATION = 108
  - ERR-INVALID-MARKET-ID = 109


## Public Functions

All public entrypoints return a Response type `(ok ...)` or `(err uXXX)` with the error codes above.

- create(duration: uint) -> (ok id: uint)
  - Validates MIN_DUR ≤ duration ≤ MAX_DUR.
  - Increments market-id, initializes market and empty pools.
  - Errors: ERR-INVALID-DURATION, ERR-INVALID-MARKET-ID (if overflow).

- buy-yes(id: uint, amt: uint) -> (ok true)
- buy-no(id: uint, amt: uint) -> (ok true)
  - Validates id, amt > 0, market exists, and not expired.
  - Transfers amt STX from caller to contract and mints equivalent shares.
  - Errors: ERR-INVALID-MARKET-ID, ERR-INVALID-AMOUNT, ERR-MARKET-EXPIRED, ERR-MARKET-NOT-FOUND, ERR-TRANSFER-FAILED.

- settle(id: uint, outcome: bool) -> (ok true)
  - Validates id, market exists, not already settled, and end block has passed.
  - Sets settled=true and outcome.
  - Errors: ERR-INVALID-MARKET-ID, ERR-MARKET-NOT-FOUND, ERR-MARKET-ALREADY-SETTLED, ERR-MARKET-NOT-EXPIRED.

- redeem(id: uint) -> (ok payout: uint)
  - Requires market settled.
  - If YES won: user must hold yes-shares; if NO won: user must hold no-shares.
  - Payout = user-shares * (yes+no) / winning-side-pool.
  - Burns the user’s shares for that side.
  - Errors: ERR-INVALID-MARKET-ID, ERR-MARKET-NOT-FOUND, ERR-MARKET-NOT-SETTLED, ERR-NO-SHARES, ERR-TRANSFER-FAILED.


## Read-only Functions

- get-market(id: uint) -> (optional {end, settled, outcome})
- get-pool(id: uint) -> (optional {yes, no})
- get-yes-shares(id: uint, who: principal) -> (optional {amt})
- get-no-shares(id: uint, who: principal) -> (optional {amt})
- get-current-market-id() -> uint
- get-market-price(id: uint) -> (optional uint)
  - Returns a percentage 0–100 (u0–u100) representing YES probability based on pool ratio.
  - If no liquidity, returns 50 (u50).
  - Returns none if invalid id.


## Error Codes

- 100: Market already expired (cannot buy).
- 101: Market already settled.
- 102: Market not settled (cannot redeem).
- 103: No shares owned on required side.
- 104: Market or pool not found.
- 105: STX transfer failed.
- 106: Invalid amount (must be > 0).
- 107: Market not expired (cannot settle yet).
- 108: Invalid duration.
- 109: Invalid market id.


## Example Workflow (Clarinet)

Assumptions:
- Contract name: PikiPiki
- Deployer: STX address `deployer`
- User A: `wallet_1`
- User B: `wallet_2`

1) Create a market (duration 1 day ~ 144 blocks)
- clarinet console:
  - contract-call? .PikiPiki create u144 sender=deployer
  - => (ok u1)

2) Users buy shares
- User A buys YES 100 STX:
  - contract-call? .PikiPiki buy-yes u1 u100 sender=wallet_1
- User B buys NO 60 STX:
  - contract-call? .PikiPiki buy-no u1 u60 sender=wallet_2

3) Check pool and price
- contract-call? (read-only) .PikiPiki get-pool u1
  - => (some {yes: u100, no: u60})
- contract-call? (read-only) .PikiPiki get-market-price u1
  - => (some u62)  // floor(100 / 160 * 100) = 62

4) Fast-forward blocks until end (in tests, mine empty blocks)
- chain.mine_empty_blocks(144)

5) Settle the market outcome (YES wins)
- contract-call? .PikiPiki settle u1 true sender=anyone
  - => (ok true)

6) Redeem winnings
- User A redeems YES shares:
  - payout = 100 * (100+60) / 100 = 160
  - contract-call? .PikiPiki redeem u1 sender=wallet_1
  - => (ok u160)
- User B tries to redeem (NO lost):
  - => (err u103)  // no winning shares


## Deployment and Development

- Project setup (Clarinet):
  - Place `contracts/PikiPiki.clar` into your Clarinet project.
  - Add to Clarinet.toml under [contracts].
  - Run `clarinet check` to type-check.
  - Write tests in `tests/` using `@stacks/transactions` or Clarinet JS harness.
  - Use `clarinet console` for manual calls and read-only queries.

- Testnet/Mainnet:
  - Deploy via your preferred tool (Hiro wallet, Stacks.js, or custom scripts).
  - Ensure the contract has received STX via buy-yes/buy-no before attempting redeems.


## Security Notes and Limitations

- Anyone can call settle: There is no oracle/admin gating. In production, restrict settlement to a trusted oracle or use a decentralized attestation mechanism.
- No fees or incentives: No LP fees, protocol fees, or referral logic.
- Naive pricing: No slippage/bonding curve; prices are informational only; whales can skew odds without cost function constraints.
- Rounding/truncation: Integer arithmetic floors payouts; small dust may remain in the contract if some users do not redeem.
- Unclaimed funds: The contract has no sweep or secondary redemption mechanism for abandoned funds.
- Trust and correctness: Carefully vet the settlement process and validate the correctness of the outcome before settling.


## Known Issues and Suggested Fix

Issue: Redeem uses `as-contract` incorrectly for the transfer back to the user:
- Current code snippet:
  - `(match (as-contract (stx-transfer? payout tx-sender tx-sender)) ...)`
- Inside `as-contract`, `tx-sender` refers to the contract principal for both sender and recipient, which attempts to transfer from the contract to itself, likely failing or doing nothing. This prevents users from receiving payouts.

Suggested fix:
- Use `contract-caller` as the recipient inside `as-contract` so the contract (as sender) pays the original caller:

```clarity
;; Inside redeem, replace the transfer call with:
(match (as-contract (stx-transfer? payout tx-sender (contract-caller)))
  success (ok payout)
  error (err ERR-TRANSFER-FAILED))
