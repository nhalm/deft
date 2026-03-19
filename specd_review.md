# Review

## evals

**Finding:** Compression eval pass rate threshold inconsistency between parent spec and component spec
**Code:** `test/eval/reflector/compression_test.exs` line 20 uses `@compression_pass_rate 0.80`
**Spec:** `specs/evals/README.md` section 1.5 table says "Compression quality: 80%"; `specs/evals/reflector.md` section 3.1 says "Pass rate: 90% over 20 iterations"
**Options:** (A) Update reflector.md to 80% to match the README table, (B) Update the README table to 90% to match reflector.md and fix the test
**Recommendation:** The component spec (reflector.md) is the detailed behavioral spec and should be authoritative — option B. 90% is a reasonable bar for compression hitting a 50% target.
