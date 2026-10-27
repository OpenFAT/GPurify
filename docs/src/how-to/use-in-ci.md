# Use GPurify in CI

Gate a merge on a clean check, and keep the report as a machine-readable file for the build log.

## Before you start

- GPurify installed on the CI runner ([Install GPurify](install.md)).
- The layout, the deck and any other inputs (reference netlist, design intent) in the repository
  or produced by an earlier step.
- [jq](https://jqlang.org/) on the runner, if you want to read the JSON report in a script.

## Steps

1. Run one command per check you want to gate on, with `--format json`, and keep each exit code:

   ```sh
   gpurify drc diffpair_bad.gds --deck sky130 --format json > drc.json
   echo $?
   ```

   ```text
   1
   ```

   Gate on the exit code. It is 0 only when every selected check ran, no rule was skipped or
   refused, and no error was found. Warnings do not fail the run. Every other outcome is 1.

2. Choose the command by the inputs you have. `all` runs DRC, ERC, LVS and PEX, and a check whose
   input is missing is skipped, which fails the run: `all` without `--reference` exits 1 even on a
   clean layout. To gate on DRC alone, run `drc`. To gate on LVS, run `lvs` with `--reference`.

3. Don't pipe GPurify into another command in the gating step. In most shells,
   `gpurify ... | tee report.json` returns `tee`'s exit code, which is 0. Redirect to a file, as
   above, or check `${PIPESTATUS[0]}` in Bash.

4. Tell a failed check from a failed run by the report file. GPurify writes the whole report only
   after the run finishes, so when it cannot run at all (a missing file, a deck it refuses) the
   report file is empty and the reason is on standard error:

   ```sh
   gpurify drc missing.gds --deck sky130 --format json > out.json
   echo $?
   wc -c < out.json
   ```

   ```text
   1
   0
   ```

5. List the violations for the build log:

   ```sh
   jq -r '.violations[] | "\(.rule) \(.severity) at (\(.at.x), \(.at.y)) nm"' drc.json
   ```

   ```text
   licon.15 error at (1250.000000, 2950.000000) nm
   licon.15 error at (2750.000000, 2950.000000) nm
   licon.18 error at (1250.000000, 2950.000000) nm
   licon.18 error at (2750.000000, 2950.000000) nm
   ```

6. List the rules that did not run, which fail the run without adding a violation:

   ```sh
   gpurify erc diffpair.gds --deck sky130 --format json > erc.json
   jq -r '.runs[] | select(.outcome != "ran") | "\(.rule): \(.outcome)"' erc.json
   ```

   ```text
   tie_high_low: skipped:no_design_intent
   ir_drop: skipped:no_design_intent
   multiple_drivers: skipped:no_design_intent
   ...
   ```

   Here ERC ran without design intent, so the rules that need it were skipped.
   [Give ERC its design intent](give-erc-design-intent.md) fixes that.

7. Keep the JSON files as build artefacts. The same inputs give the same bytes on any machine,
   thread count or backend, and the JSON header's `timestamp` is `null`, so two reports differ
   only where the results differ. A plain `diff` against the last accepted report shows what
   changed.

> [!WARNING]
> The JSON report has no summary section: it does not say that a whole check was skipped, as LVS
> is under `all` without a reference. Gate on the exit code, not on an empty `violations` list.

## Related

- [Report format](../reference/report.md)
- [Command line](../reference/cli.md)
- [How a run passes](../explanation/outcomes.md)
