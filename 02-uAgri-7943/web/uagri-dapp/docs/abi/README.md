# ABI Pipeline (Foundry out -> Frontend ABIs)

This frontend **must not** import Solidity/Foundry artifacts at runtime.

Runtime ABI source is only:

- `src/abis/**` (generated `.abi.json`)
- `src/abis/manifest.json`
- `src/abis/index.ts` (`abiByName`, `getAbi`)

## Generate ABIs

From workspace root:

```bash
forge build
cd web/uagri-dapp
npm run abi:export
```

Equivalent command:

```bash
node scripts/export-abis.mjs --out ../../contracts/out --dest ./src/abis
```

## Export Rules

- Input: `../../contracts/out/**`
- Output:
  - `src/abis/contracts/*.abi.json`
  - `src/abis/interfaces/*.abi.json`
  - `src/abis/standards/*.abi.json`
  - `src/abis/manifest.json`
  - `src/abis/index.ts`
- Excludes Foundry test/script/build-info noise (`*.t.sol`, `*.s.sol`, forge-std artifacts).
- Name normalization:
  - removes spaces
  - removes `.sol` suffixes
  - keeps only `[a-zA-Z0-9_]`
- Deduplication:
  - primary key: normalized contract/interface name
  - fallback on collision: `Name__FileHint`
  - if still colliding: `Name__FileHint_N`

Example:

- `IERC1271` + duplicate -> `IERC1271__YieldAccumulator`

## Why this avoids tuple/parseAbi breakage

Frontend pages consume full JSON ABI definitions from `src/abis/**`, so tuple/components are preserved exactly as emitted by Foundry.

This avoids runtime `parseAbi()` signature-loss issues in complex structs/tuples.

## After ABI changes

Run:

```bash
npm run abi:export
npm run abi:report
npm run abi:check
```

This refreshes ABI files + manifest/index + coverage metrics and enforces the gate:

- `Accessible` must remain `100%` (`functions.accessible === functions.total`)
- `Dedicated UI` is tracked numerically and should increase across PRs
- `needsDedicatedUI` remains prioritized for next iterations

Outputs:

- `docs/abi/abi-surface.json`
- `docs/abi/ui-coverage.json`
- `docs/abi/coverage-report.md`
