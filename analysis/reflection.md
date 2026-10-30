# Reflection: From OLTP to Star Schema

All figures come from MySQL 8.0 in two test phases. Phase 1 used the 4 sample encounters from the brief. Phase 2 used 100,004 encounters: the sample plus 100,000 synthetic ones. Times are MySQL Workbench medians. Where Workbench was too coarse to measure, I used `EXPLAIN ANALYZE` server times instead. In Phase 2, every star query returned the same results as its OLTP version.

## 1. Why Is the Star Schema Faster?

**Fewer joins, and the remaining joins are applied to small results.** In the normalized schema, the four questions needed 2, 4, 3 and 3 joins, and every join was applied to all 100,004 encounters. Specialty is stored only on the provider, so every encounter had to be routed `encounters → providers → specialties`. Q4 added `billing` as a fourth table. In the star schema, Q3 needs 1 join and Q2 needs 2. Q1 and Q4 need 2–3 joins, but only to small dimension tables, and only after the fact table has been grouped down to 171 or 168 rows. Joining 168 rows to a 3-row specialty table costs almost nothing. Joining 100,004 rows through two tables is what made the OLTP queries slow.

**Data pre-computed in the star schema.** The ETL does the expensive work once per load instead of once per report:

- **Specialty and department:** stored on each fact row, as they were on the date of the encounter.
- **Billing:** each encounter's claims are summed into `total_allowed_amount`, `total_claim_amount` and `claim_count`, so Q4 never reads the billing data.
- **Readmissions:** the 30-day check that the OLTP query performed as a self-join over 250,010 rows is evaluated once and stored as `is_readmitted_30d`.
- **Diagnosis–procedure pairs:** the 266,673-row pairing behind Q2 is counted once into `agg_dx_px_pairs_monthly`, which holds 449 rows.
- **Counts and lengths:** diagnosis count, procedure count, length of stay and age at the visit are stored on the fact row.

**Why denormalization helps analytical queries.** Analytical queries read many rows but only a few columns, and they group by attributes such as specialty and month. When those attributes and the measures sit in one table, a single composite index can hold every column a query needs. MySQL then answers the query from the index alone, without reading table rows. In the normalized schema the same columns are spread across three or four tables, so no single index can cover the query, and every row needs extra lookups. The integer date key helps in the same way: `encounter_date_key DIV 100` gives the month with integer arithmetic, instead of `YEAR()` and `MONTH()` being called on every DATETIME value.

## 2. Trade-offs: What Did I Gain? What Did I Lose?

**What I gave up:**

- **Storage.** The warehouse uses about 72 MB, the same as the OLTP database it copies, so the data is now stored twice. In the fact table, the indexes (33 MB) take three times the space of the data itself (11.5 MB). That is the price of the covering indexes.
- **ETL complexity.** I now own a load process that took about 24 seconds for 100,004 encounters. It has to look up surrogate keys, keep provider history, recompute readmissions, and pass four reconciliation checks. Building it surfaced real problems:
  - SQL that worked on MariaDB failed on MySQL.
  - A `DATE` column silently dropped the time from every encounter.
  - The synthetic data could not produce any readmissions.

  Every pre-computed column is another place where an error could go unnoticed, so the reconciliation checks are essential.
- **Freshness and flexibility.** Reports are only as current as the last load. If clinicians change the readmission definition (for example, counting any return visit instead of inpatient only), the stored flag must be recomputed for all history. In OLTP, that would just be a change to a `WHERE` clause.

**What I gained:**

- **Speed:** 4–46× on the large dataset, and more than 170× on Q2.
- **Simpler queries:** Q3 went from a self-join with date arithmetic and nested `COUNT(DISTINCT CASE ...)` expressions to `SUM(is_readmitted_30d) / COUNT(*)`.
- **Correct history:** providers keep their historical versions, so past revenue stays attributed to the specialty the provider had at the time.
- **Less load on production:** the analytical workload moves off the database that supports patient care.

**Was it worth it?** For repeated reporting on a growing database, yes. The 24-second load runs once a night, and the speedups apply to every report, every day. The two test phases also showed that this is not true at every scale. On the 4-encounter sample, the star schema was slower for three of the four queries (1.1–4.2×), because the fixed cost of joining dimension tables outweighed any saving. Dimensional modelling pays off with volume, not by default.

## 3. Bridge Tables: Worth It?

**Why keep diagnoses and procedures in bridges.** An encounter has 1–3 diagnoses and 0–2 procedures in this data, and more in real clinical coding. Putting them into the fact table would either break the one-row-per-encounter grain or require fixed columns such as `dx1`, `dx2`, `dx3`. Breaking the grain would make every `SUM(total_allowed_amount)` double- or triple-count revenue. Fixed columns limit how many codes an encounter can have, and they turn "find encounters with I50.9" into a three-way `OR`. Bridge tables keep the fact table clean for Q1, Q3 and Q4, while still storing every encounter–code link.

**The trade-off.** Bridges keep the detail, but they do not make the pairing question fast. In Phase 1, the star Q2 that joined the two bridge tables directly was 4.2× slower than OLTP. The large improvement came only from the pre-computed aggregate, which the ETL builds from the bridges. Bridges therefore add a layer of storage and ETL work, and the speed for this kind of question depends on the aggregate built on top of them.

**In production.** I would keep the bridge tables as the detailed record and the source for aggregates, because analysts will ask questions no aggregate anticipates (for example, the top pairs among patients over 65). I would add aggregates only for questions that reports repeat. I would also check their size against real code sets: with thousands of ICD-10 and CPT codes, a monthly pair table becomes far larger than the 449 rows here. A quarterly or yearly version, or a columnar database, might be the better choice.

## 4. Performance Quantification

Phase 2, 100,004 encounters:

| Query | Original (OLTP) | Optimized (star) | Improvement | Main reason for the speedup |
|---|---|---|---|---|
| Q1 Encounters by specialty | 0.40 s | 0.094 s | 0.40 / 0.094 = **4.3×** | Specialty key on the fact row removes the provider hop; covering index; integer month key |
| Q2 Diagnosis–procedure pairs | 2.75 s | < 0.016 s (0.27 ms server time) | 2.75 / 0.016 = **> 170×** | 266,673-row pairing computed once in the ETL; the report sums 449 aggregate rows |
| Q3 30-day readmissions | 0.73 s | ~0.016 s (18 ms server time) | **~28–46×** | Self-join replaced by a stored flag; filtered covering index reads only the 25,001 index admissions |
| Q4 Revenue by specialty | 0.89 s | 0.125 s | 0.89 / 0.125 = **7.1×** | Billing totals stored on the fact row; 4-table chain replaced by one index scan |

For comparison, Phase 1 (4 encounters): Q1 0.123 → 0.175 ms (1.4× slower), Q2 0.228 → 0.957 ms (4.2× slower), Q3 0.682 → 0.322 ms (2.1× faster), Q4 0.247 → 0.275 ms (1.1× slower).

**What the numbers show.** The gains fall into two groups:

- **Denormalized keys and covering indexes** gave 4–7× (Q1 and Q4).
- **Pre-computing expensive logic in the ETL** gave the largest gains: the self-join for Q3 and the row explosion for Q2.

Removing joins helps, but the biggest wins come from not repeating the same work on every report.

**Limitations.** The data is synthetic, with only 3 providers, 3 diagnoses and 3 procedures. In the current dataset no patient returns within 30 days, so Q3 returns 0% in both schemas. The timing is valid, but the result is not a clinical finding. The two phases used different timers, so the growth figures between them are approximate. Absolute times will differ on other hardware; the ratios and the reasons behind them are the main result.