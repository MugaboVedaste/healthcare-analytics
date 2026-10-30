-- Synthetic load generator for the Healthcare Analytics project.
-- Creates 10,000 patients, 100,000 encounters, ~200,000 diagnoses,
-- up to ~100,000 procedure records, and 100,000 billing records.
-- Run ONLY against a development/test copy of healthcare_analytics.
-- It appends records; it does not delete existing data.

USE healthcare_analytics;

-- Generate integers 1..100000 using a set-based cross join.
DROP TEMPORARY TABLE IF EXISTS tmp_n;
CREATE TEMPORARY TABLE tmp_n (n INT PRIMARY KEY);
INSERT INTO tmp_n (n)
SELECT a.d + 10*b.d + 100*c.d + 1000*d.d + 10000*e.d + 1 AS n
FROM
 (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
CROSS JOIN
 (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b
CROSS JOIN
 (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c
CROSS JOIN
 (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d
CROSS JOIN
 (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) e;

-- Map existing lookup IDs safely, even if IDs are not contiguous.
DROP TEMPORARY TABLE IF EXISTS tmp_provider_ids;
CREATE TEMPORARY TABLE tmp_provider_ids AS
SELECT provider_id, department_id,
       ROW_NUMBER() OVER (ORDER BY provider_id) AS rn
FROM providers;
DROP TEMPORARY TABLE IF EXISTS tmp_diagnosis_ids;
CREATE TEMPORARY TABLE tmp_diagnosis_ids AS
SELECT diagnosis_id, ROW_NUMBER() OVER (ORDER BY diagnosis_id) AS rn
FROM diagnoses;
DROP TEMPORARY TABLE IF EXISTS tmp_procedure_ids;
CREATE TEMPORARY TABLE tmp_procedure_ids AS
SELECT procedure_id, ROW_NUMBER() OVER (ORDER BY procedure_id) AS rn
FROM procedures;

SELECT COUNT(*) INTO @provider_count FROM tmp_provider_ids;
SELECT COUNT(*) INTO @diagnosis_count FROM tmp_diagnosis_ids;
SELECT COUNT(*) INTO @procedure_count FROM tmp_procedure_ids;

-- These lookup tables must already contain at least one row.
-- Stop here and seed them first if any count is zero.
SELECT @provider_count AS available_providers,
       @diagnosis_count AS available_diagnoses,
       @procedure_count AS available_procedures;

SET @patient_base = (SELECT COALESCE(MAX(patient_id), 0) FROM patients);
SET @encounter_base = (SELECT COALESCE(MAX(encounter_id), 0) FROM encounters);
SET @diagnosis_link_base = (SELECT COALESCE(MAX(encounter_diagnosis_id), 0) FROM encounter_diagnoses);
SET @procedure_link_base = (SELECT COALESCE(MAX(encounter_procedure_id), 0) FROM encounter_procedures);
SET @billing_base = (SELECT COALESCE(MAX(billing_id), 0) FROM billing);

-- Add 10,000 synthetic patients.
INSERT INTO patients (patient_id, first_name, last_name, date_of_birth, gender, mrn)
SELECT @patient_base + n,
       CONCAT('Synthetic', n),
       'Patient',
       DATE_ADD('1950-01-01', INTERVAL MOD(n * 17, 20000) DAY),
       CASE MOD(n, 3) WHEN 0 THEN 'F' WHEN 1 THEN 'M' ELSE 'X' END,
       CONCAT('SYN', LPAD(@patient_base + n, 12, '0'))
FROM tmp_n
WHERE n <= 10000;

-- Prepare 100,000 encounters once, so child records can reference the same IDs.
DROP TEMPORARY TABLE IF EXISTS tmp_new_encounters;
CREATE TEMPORARY TABLE tmp_new_encounters AS
SELECT n.n AS seq_num,
       @encounter_base + n.n AS encounter_id,
       @patient_base + MOD(n.n - 1, 10000) + 1 AS patient_id,
       p.provider_id,
       p.department_id,
       CASE MOD(n.n, 3)
           WHEN 0 THEN 'Outpatient'
           WHEN 1 THEN 'Inpatient'
           ELSE 'ER'
       END AS encounter_type,
       TIMESTAMP(
           DATE_ADD('2022-01-01', INTERVAL MOD(n.n * 7, 1700) DAY),
           MAKETIME(MOD(n.n, 24), MOD(n.n * 11, 60), 0)
       ) AS encounter_dt
FROM tmp_n n
JOIN tmp_provider_ids p
  ON p.rn = MOD(n.n - 1, @provider_count) + 1;

ALTER TABLE tmp_new_encounters ADD PRIMARY KEY (encounter_id);
ALTER TABLE tmp_new_encounters ADD INDEX idx_tmp_seq (seq_num);

INSERT INTO encounters
    (encounter_id, patient_id, provider_id, encounter_type,
     encounter_date, discharge_date, department_id)
SELECT encounter_id,
       patient_id,
       provider_id,
       encounter_type,
       encounter_dt,
       CASE WHEN MOD(seq_num, 4) = 0 THEN NULL
            ELSE DATE_ADD(encounter_dt, INTERVAL (1 + MOD(seq_num, 72)) HOUR)
       END,
       department_id
FROM tmp_new_encounters;

-- Add 1-3 diagnosis links per encounter (~200,000 rows).
DROP TEMPORARY TABLE IF EXISTS tmp_k3;
CREATE TEMPORARY TABLE tmp_k3 (k INT PRIMARY KEY);
INSERT INTO tmp_k3 VALUES (1), (2), (3);

INSERT INTO encounter_diagnoses
    (encounter_diagnosis_id, encounter_id, diagnosis_id, diagnosis_sequence)
SELECT @diagnosis_link_base + ((e.seq_num - 1) * 3) + k.k,
       e.encounter_id,
       d.diagnosis_id,
       k.k
FROM tmp_new_encounters e
JOIN tmp_k3 k ON k.k <= 1 + MOD(e.seq_num, 3)
JOIN tmp_diagnosis_ids d
  ON d.rn = MOD(e.seq_num + k.k - 2, @diagnosis_count) + 1;

-- Add 0-2 procedure links per encounter (up to ~100,000 rows).
DROP TEMPORARY TABLE IF EXISTS tmp_k2;
CREATE TEMPORARY TABLE tmp_k2 (k INT PRIMARY KEY);
INSERT INTO tmp_k2 VALUES (1), (2);

INSERT INTO encounter_procedures
    (encounter_procedure_id, encounter_id, procedure_id, procedure_date)
SELECT @procedure_link_base + ((e.seq_num - 1) * 2) + k.k,
       e.encounter_id,
       p.procedure_id,
       DATE(e.encounter_dt)
FROM tmp_new_encounters e
JOIN tmp_k2 k ON k.k <= MOD(e.seq_num, 3)
JOIN tmp_procedure_ids p
  ON p.rn = MOD(e.seq_num + k.k - 2, @procedure_count) + 1;

-- Add one billing record per synthetic encounter.
INSERT INTO billing
    (billing_id, encounter_id, claim_amount, allowed_amount, claim_date, claim_status)
SELECT @billing_base + e.seq_num,
       e.encounter_id,
       ROUND(100 + MOD(e.seq_num * 37, 50000) / 10, 2),
       ROUND((100 + MOD(e.seq_num * 37, 50000) / 10) * 0.80, 2),
       DATE(e.encounter_dt),
       CASE MOD(e.seq_num, 4)
           WHEN 0 THEN 'Pending'
           WHEN 1 THEN 'Approved'
           WHEN 2 THEN 'Denied'
           ELSE 'Paid'
       END
FROM tmp_new_encounters e;

-- Confirm the generated row counts.
SELECT 'patients' AS table_name, COUNT(*) AS total_rows FROM patients
UNION ALL SELECT 'encounters', COUNT(*) FROM encounters
UNION ALL SELECT 'encounter_diagnoses', COUNT(*) FROM encounter_diagnoses
UNION ALL SELECT 'encounter_procedures', COUNT(*) FROM encounter_procedures
UNION ALL SELECT 'billing', COUNT(*) FROM billing;

-- After this script completes:
-- 1. Run your existing ETL script to load the new rows into healthcare_analytics_dw.
-- 2. Run ANALYZE TABLE on the source and warehouse tables before benchmarking.
-- 3. Compare equivalent OLTP and star-schema queries using EXPLAIN ANALYZE.
