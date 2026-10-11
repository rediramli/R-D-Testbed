<!-- One experiment per PR. Open it as a Draft as soon as work starts; mark it
     "Ready for review" only when every check below is PASS. -->

## Objective
- LAB: <!-- e.g. LAB-1: Changing the 5G NR bandwidth (OAIBOX 5G LAB Manual, ch. 1) -->
- Closes #<!-- issue number -->
- 3GPP reference: <!-- e.g. TS 38.101-1 Table 5.3.2-1 -->

## Hypothesis
<!-- What we expect before running anything, and why. -->

## Changes
| File | What and why |
|---|---|
|  |  |

## Safety
- [ ] rfsim only: `--rfsim` checked by the script; no OTA, X410 untouched
- [ ] No secrets in the diff (SIM K/OPc, admin password, tokens, SSH keys)
- [ ] Open5GS network functions not restarted or reconfigured (or approved and noted here)
- [ ] Baseline restored after the experiment (how: )

## Evidence
<!-- Paste the PASS lines, not screenshots of them. Name the run folder. -->
```
```

## Results
| Setting | CQI | DL MCS | DL goodput (Mbit/s) | UL goodput (Mbit/s) | Notes |
|---|---|---|---|---|---|
|  |  |  |  |  |  |

Goodput is MAC goodput in simulated time (rfsim runs ~1.88x faster than real time).

## Regression gates
- [ ] `lab0-run.sh`: all PASS except T0.9 while the X410 is off
- [ ] `d6-test.sh`: RESULT: PASS
- [ ] `iperf-regress.sh`: HASIL: PASS
- [ ] `uu-check.sh`: RESULT: PASS
- [ ] Experiment's own test: PASS

## Documentation
- [ ] `docs/labs/LAB-xx-*.md` written (method, results, conclusion)
- [ ] `docs/labs/README.md` status row updated
- [ ] README updated if a tool or behaviour changed

## Conclusion and open questions
<!-- What the evidence shows. Anything not proven is a hypothesis. -->
