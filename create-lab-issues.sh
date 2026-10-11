#!/usr/bin/env bash
# Create the "lab" label, the LAB-1..LAB-14 issues and the summary issue for the noise presets
# (N1, already done; it is created and closed). Uses the GitHub CLI with YOUR login:
#   gh auth login            # once
#   bash tools/create-lab-issues.sh
# Safe to run twice: an issue whose title already exists is skipped.
set -u
REPO=${REPO:-rediramli/R-D-Testbed}
gh auth status >/dev/null 2>&1 || { echo "STOP: run 'gh auth login' first"; exit 1; }
gh label create lab --repo "$REPO" --color 1d76db --description "Lab experiment (OAIBOX-style)" 2>/dev/null || true
gh label create needs-hardware --repo "$REPO" --color d93f0b --description "Cannot be done fully in rfsim" 2>/dev/null || true
EXISTING=$(gh issue list --repo "$REPO" --state all --limit 200 --json title -q '.[].title')

mk(){  # mk TITLE LABELS BODY [close]
  if grep -qxF "$1" <<< "$EXISTING"; then echo "skip (exists): $1"; return; fi
  url=$(gh issue create --repo "$REPO" --title "$1" --label "$2" --body "$3")
  echo "created: $url"
  [ "${4:-}" = close ] && gh issue close "$url" --reason completed --comment "Done on main; see docs/labs/NOISE-presets.md." >/dev/null && echo "  closed"
}

body(){  # body GOAL REF FEASIBILITY PLAN HYPOTHESIS
cat <<EOF
## Goal
$1

## Reference
- OAIBOX 5G LAB Manual: $2

## Feasibility on our testbed
$3

## Plan
$4
- Script with preview / run / restore; the baseline is restored by \`lab0-run.sh\`.
- One setting at a time; record CQI, MCS, BLER, DL/UL MAC goodput and keep the logs.

## Pass criteria
- The experiment's own test prints PASS.
- Regression gates PASS: \`lab0-run.sh\` (T0.9 excepted while the X410 is off), \`d6-test.sh\`, \`iperf-regress.sh\`, \`uu-check.sh\`.

## Expected result (hypothesis)
$5
EOF
}

mk "N1: DL noise presets and dashboard control (done)" "lab" "$(cat <<'EOF'
Done on main (commits 6a37bdc..dba4729). Presets: Clean -11 dB (MCS 26), Moderate -6.5 dB (MCS 15), Poor -3 dB (MCS 6), Off -100 dB.
Dashboard v0.8.0 has DL channel buttons through the noise relay. All tests and regression gates PASS.
Details: docs/labs/NOISE-presets.md
EOF
)" close

mk "LAB-1: Changing the 5G NR bandwidth" "lab" "$(body \
 "Change the carrier bandwidth (30 kHz SCS: 20 MHz = 51 PRB, 40 MHz = 106 PRB (baseline), 60 MHz = 162 PRB, 100 MHz = 273 PRB) and measure the effect." \
 "chapter 1" "rfsim: yes. Point A, BWP (RIV) and SSB position must change together; UE arguments (-r) too." \
 "- Read the current gNB/UE configuration (read-only).
- Start with 20 MHz, then 60 MHz and 100 MHz." \
 "DL goodput roughly proportional to the PRB count; at 100 MHz the rfsim host CPU may limit it.")"

mk "LAB-2: Changing the 5G NR central frequency carrier" "lab" "$(body \
 "Move the carrier within n78 and confirm the cell and UE follow (SSB/point A/ARFCN consistency)." \
 "chapter 2" "rfsim: yes, as a configuration exercise (rfsim has no RF, so no propagation change is expected)." \
 "- Pick two ARFCNs inside n78 on the synchronization raster." \
 "Attach and throughput unchanged; logs show the new frequencies.")"

mk "LAB-3: Changing the 5G NR TDD slot configuration" "lab" "$(body \
 "Change the TDD pattern (baseline 7 DL / 3 UL per 5 ms) and measure the DL/UL split." \
 "chapter 3" "rfsim: yes." \
 "- Try a DL-heavy and a more balanced pattern." \
 "DL and UL goodput move with the number of DL and UL slots.")"

mk "LAB-4: Testing the FDD mode" "lab" "$(body \
 "Run the cell in an FDD band and compare with TDD." \
 "chapter 4" "rfsim: likely yes (OAI has FDD rfsim configurations); to be confirmed." \
 "- Use an OAI FDD reference configuration as the starting point." \
 "DL and UL can run at the same time; UL goodput higher than in TDD 7/3.")"

mk "LAB-5: Changing the 5G NR Modulation and Coding Scheme" "lab" "$(body \
 "Fix or cap the DL/UL MCS and observe throughput and BLER; relate to the noise presets." \
 "chapter 5" "rfsim: yes." \
 "- Use the scheduler MCS limits; combine with the DL channel presets." \
 "Throughput follows the MCS table (TS 38.214 Table 5.1.3.1-1); a fixed high MCS under Poor gives high BLER.")"

mk "LAB-6: Changing the 5G BWP configuration" "lab" "$(body \
 "Configure a dedicated BWP narrower than the carrier and observe what the UE uses." \
 "chapter 6" "rfsim: yes." \
 "- Change the initial/dedicated BWP (RIV) one parameter at a time." \
 "Goodput scales with the active BWP width, not the carrier width.")"

mk "LAB-7: Testing the 5G NR RACH" "lab" "$(body \
 "Observe and change the random-access procedure (Msg1-Msg4) and its parameters." \
 "chapter 7" "rfsim: yes. The dashboard already shows Msg1-Msg4 (uu-check.sh)." \
 "- Change PRACH configuration index / preamble settings; measure attach time." \
 "Msg1 to RRCSetupComplete time changes with the PRACH configuration.")"

mk "LAB-8: Testing 5G NR MIMO configurations" "lab" "$(body \
 "Run 2x2 and compare with 1x1." \
 "chapter 8" "rfsim: yes (OAI has 2x2 rfsim configurations), CPU-heavy." \
 "- Start with 2x2 at 40 MHz; check host CPU." \
 "Rank 2 appears in the statistics; DL goodput up to about twice 1x1 if the CPU keeps up.")"

mk "LAB-9: Testing the 5G NR LDPC in uplink" "lab" "$(body \
 "Look at uplink LDPC decoding: iterations, BLER and decoding time." \
 "chapter 9" "rfsim: yes." \
 "- Combine with UL load and noise; read the gNB LDPC statistics." \
 "Decoding iterations and time rise as the UL channel gets worse.")"

mk "LAB-10: Understanding 5G NR with Deep Packet Inspection" "lab" "$(body \
 "Capture and decode user-plane and control-plane traffic (N2/N3, GTP-U)." \
 "chapter 10" "rfsim: yes. N2 capture already exists (capture.py)." \
 "- Add N3/GTP-U capture on the UPF host; never store payloads with personal data." \
 "Flows per protocol visible and consistent with the speed tests.")"

mk "LAB-11: Understanding 5G NR Security" "lab" "$(body \
 "Show NAS and AS security (authentication, ciphering and integrity algorithms)." \
 "chapter 11" "rfsim: yes. Do not publish SIM K/OPc or decrypted keys." \
 "- Read the security mode messages; change the algorithm preference one at a time (approval needed for any core change)." \
 "Message flow shows the selected algorithms.")"

mk "LAB-12: Testing 5G network slicing using an xApp" "lab,needs-hardware" "$(body \
 "Two slices with different resources, controlled by an xApp." \
 "chapter 12" "Needs a near-RT RIC (FlexRIC) integrated with the OAI gNB; no radio hardware needed." \
 "- Plan the FlexRIC integration as a separate step before the lab." \
 "Slice throughput follows the xApp's resource split.")"

mk "LAB-13: PLMN configuration and 5G SIM card programming" "lab,needs-hardware" "$(body \
 "Change the PLMN consistently in core, gNB and UE; program SIM cards." \
 "chapter 13" "PLMN change: rfsim yes. SIM programming needs physical cards and a reader; keys never in the repo." \
 "- PLMN first (rfsim). SIM programming later, only with physical cards." \
 "Attach succeeds with the new PLMN in all three places.")"

mk "LAB-14: Understanding the 5G NR core" "lab" "$(body \
 "Walk through the Open5GS network functions and procedures (registration, PDU session) with logs and the message flow." \
 "chapter 14" "rfsim: yes. No core restarts without approval (restart order SMF then AMF)." \
 "- Use the dashboard message flow and NF logs; read-only." \
 "Each step of registration and PDU session setup maps to an NF and a 3GPP procedure.")"
echo "Done. Next: create a GitHub Project board (Backlog / In progress / Review / Done) and add these issues."
