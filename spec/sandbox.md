# Process sandbox

## Summary

Web pages run in processes that the operating system confines, so a page that exploits a bug in the engine still cannot read the person's files or reach the rest of the system.
Every build runs this way, so every feature is built and tested with the sandbox on.

## Behavior

- Every page is rendered in a separate helper process that macOS confines with its sandbox (seatbelt) from the moment it starts.
- No helper process is started with the sandbox turned off (`--no-sandbox`), with everything in one process (`--single-process`) or with the GPU sandbox turned off (`--disable-gpu-sandbox`).
- Pages load and behave the same with the sandbox on.
- The `sandbox` e2e test (part of every `make e2e` run, or alone with `make e2e E2E=sandbox`) loads a page, reads the app's helper processes and asks the system whether each one is sandboxed, then records four checks that count toward the `E2E: PASS n/n` total:
  - `PASS sandbox.renderers: sandboxed=<n>` when at least one renderer runs and every renderer was started with the sandbox and runs inside it.
  - `PASS sandbox.gpu: sandboxed=<n>` and `PASS sandbox.network: sandboxed=<n>`, the same for the GPU process and the network service.
  - `PASS sandbox.switches: helpers=<n>` when no helper carries one of the switches above.
  - Each failing check prints `FAIL sandbox.<check>: <reason>` naming the process, and the run exits with code 1.

## Edge cases

- A helper process the engine starts without the sandbox on purpose (one that needs wider access, such as the code signing clone cleanup service) still starts; only renderers, the GPU process and the network service are required to be sandboxed.
- If the sandbox cannot start in a helper, that helper exits at once instead of running unconfined, and the page fails to load.

## Acceptance checks

1. Run `make e2e E2E=sandbox`: it prints `PASS sandbox.renderers: sandboxed=<n>`, `PASS sandbox.gpu: sandboxed=1`, `PASS sandbox.network: sandboxed=1`, `PASS sandbox.switches: helpers=<n>` and `E2E: PASS 4/4`, and `echo $?` prints 0.
2. While Bow is open normally, list its renderers with `ps -axo command | grep '[B]ow Helper (Renderer)'`: every renderer command line contains `--seatbelt-client=` and none contains `--no-sandbox`.

## Out of scope

- Hardened runtime, notarization and per helper entitlements, which come with signed release builds.
- Site isolation policy (which sites share a renderer).
