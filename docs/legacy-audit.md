# Legacy content audit (Piece 1)

**Source actually read:** `index.html` + `data.js` in the repo root. `/docs/pharmalex-legacy.html` was **not** present (only the "drop file here" note was uploaded), and in this repo the data lives in a separate `data.js`, not inline. Confirm these are the same content as your legacy file.
Re-run any time: `node scripts/count-legacy.mjs [path]`. Question IDs below are `ARRAY[index]`, 0-based, as stored in legacy.

## 1. Counts per Act (script output)

| Act | Questions | Flashcards | Note sections (act+reg) | Note items | Warnings | Law-text entries |
|---|---|---|---|---|---|---|
| ROPA | 25 | 12 | 5 | 25 | 6 | 8 |
| POISON | 34 | 12 | 5 | 18 | 5 | 8 |
| SODA | 5 | 6 | 3 | 12 | 4 | 4 |
| MASA | 14 | 7 | 2 | 10 | 4 | 4 |
| DDA | 16 | 8 | 3 | 12 | 4 | 4 |
| ETHICS | 16 | 6 | 3 | 15 | 5 | 4 |
| GGM | 6 | 6 | 4 | 19 | 4 | 4 |
| DUNAS | 7 | 6 | 3 | 11 | 4 | 4 |
| TIPS | 0 | 0 | 3 | 14 | 4 | 0 |
| **Total** | **123** | **63** | **31** | **136** | **40** | **40** |

After moving the 5 GGM/DUNas-style items out of ETHICS_DATA: ETHICS 11, GGM 9, DUNAS 9.

## 2. Structural issues

| # | Issue | Detail | Handling in schema / import |
|---|---|---|---|
| 1 | Option letters baked in | All 123 questions have `"A. text"` | Strip on import; `options` stores plain text, UI adds letters |
| 2 | Act + section in one label | `'ROPA · s.17'`; also composite (`'ROPA · s.18A / PA · s.32'`, `'DDA · s.25 / PA · s.8'`) and unsplittable (`'Reg 4 PR 1952'`, `'DUNas'`) | Split into `instrument` + `section`; composites keep both in `citation`; unsplittable left null and flagged |
| 3 | ETHICS_DATA holds other Acts | ETHICS[10–12] are GGM, ETHICS[13–14] are DUNas | Re-map by label prefix on import |
| 4 | Question lives under the wrong Act | P(PS)R items sit in DDA_DATA (3, 5, 6, 15) and POISON_DATA (32, 33); Reg 2004 items in ROPA_DATA | Keep Act as legacy bucket; lecturers re-tag |
| 5 | SODA has 5 Qs vs quota 15 | Full mock silently under-fills | Quota is per `exam_group`; mock draws what is verified |
| 6 | "100-question" mock is not 100 | Quotas 20+35+15+10+10+10 = 100, but code also adds GGM and DUNAS at default 10 each (120), then caps by availability (~102 real) | New quota lives on `acts.exam_quota` per group (sums to 100) |
| 7 | Near-duplicates | ROPA[5]/[22] (similar stems); DDA[1]/[14] (same stem, different options); ETHICS[10] vs GGM[4]; ETHICS[13],[14] vs DUNAS[4],[6] overlap | Flagged, not deleted |
| 8 | Raw HTML in law text and note strings | rendered with `innerHTML` | `body_html` column; sanitise on import and render |

## 3. Flagged questions

### A. Hedged explanation (author was unsure)

| Question | Text (shortened) | Why flagged |
|---|---|---|
| POISON[24] | "TRUE regarding classification of poisons: i. Chloramphenicol eye drop – Group B … iv. Telithromycin Pulv. B.P – Group B" (key: D, None) | Explanation says "Verify current First Schedule… specific combinations listed may be incorrect" |
| DDA[12] | "TRUE regarding keeping of the register for morphine sulphate" (key: A, i and ii only) | Explanation: "(and iii if listed — verify answer key)". See B: no matching option |
| MASA[13] | "No person shall take part in publication of: i. heart-function medicine report … iii. skin disease treatment ad … iv. private clinic service" (key: C, all four) | "Skin disease — likely not on Schedule… Most sources indicate all four" |
| DDA[4] | "FALSE regarding person dispensing a DD prescription" (key: D, i and iii) | Explanation: "the stated amount may be incorrect"; statement iii says "two thousand dollars" (currency unit looks wrong) |
| POISON[22] | "Ten tablets of Glibenclamide dispensed by a pharmacy assistant without prescription, pharmacist in same room" (key: A, i only) | "may contravene s.22(b)"; scenario mixes supervised sale (s.22(a)) with missing prescription |
| DDA[8] | "Lomotil (diphenoxylate 2.5 mg) registered under CDCR 1984…" (key: C, Reg 11(2) DD Regs) | "may be an exempted Third Schedule preparation" |
| POISON[17] | "TRUE of Type A licence" (key: C, iii and iv) | Explanation calls statement i "partially correct" but marks it neither true nor false |
| MASA[5] | "Advertisement that may be approved by MAB" (key: B, i and iii) | Explanation: kidney herbal and traditional-practitioner items are "more restricted" with no rule cited |

### B. No matching option / key contradicts explanation / likely wrong premise

| Question | Text (shortened) | Why flagged |
|---|---|---|
| DDA[12] | Morphine sulphate register, i–iv | Explanation says i, ii **and iii** are true, iv false. Options: i+ii / i+ii+iv / iii+iv / all four. **No option = i, ii, iii.** Key A contradicts the explanation. Unanswerable as written |
| POISON[16] | "TRUE regarding Type D licence" (key: C, iii only) | Explanation marks i ✓ and iii ✓. Correct set is "i and iii"; **no such option** |
| DDA[3] | "Upho Berhad manufactures **pethidine** injection… Production Register for **Psychotropic** Substance" (P(PS)R r.19) | Pethidine is treated as a dangerous drug elsewhere in the same bank (DDA[14]). Register type looks wrong. I'm not certain; verify |
| POISON[0] | "Classified as a Poison: i. Paracetamol 500 mg tablet … ii. animal feeds with nitrofurans …" (key: A) | Explanation says ii is "classified as poison but exempted" and still counts it. Paracetamol 500 mg as a Group B poison looks doubtful. Verify |
| ROPA[17] | "Board may make regulations on following, EXCEPT… " (key: D, None of the above) | EXCEPT stem whose answer is "none": confusing double-negative |
| ETHICS[6] | "FALSE… patient information should be shared with all healthcare providers" (key: C) | Arguably true for providers involved in the patient's care; ambiguous |

### C. Numbers and facts to verify against gazetted text (not hedged, but easy to get wrong)

ROPA[4] (RM50 / RM100 fees), ROPA[18] (14 days), POISON[16] (RM20 fee), POISON[27] (all four fees), DDA[2] and DDA[11] (s.37(da) weight thresholds), MASA[12] (quorum of three), DUNAS[1] (Cabinet approval date), DUNAS[3] (target "50% reduction in inappropriate antibiotic prescribing by 2026"; I cannot confirm this target exists).

Every imported item starts as `needs_review`. None are marked verified.
