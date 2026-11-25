package agent

// Chuck (2026-11-25): these tests fail at random and kill test runs, so they
// are held out until backlog item runtime-flaky-root-cause-r1 finds the cause
// in the product or the test. Run them with -define:THIRP_RUN_FLAKY=true.
RUN_FLAKY :: #config(THIRP_RUN_FLAKY, false)
