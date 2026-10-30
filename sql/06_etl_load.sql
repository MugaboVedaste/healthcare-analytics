-- =====================================================================
-- etl_load.sql : initial FULL load of the star schema (dw) from the
-- normalized OLTP database (healthcare_analytics).
--
-- Target: MySQL 8.0+ (tested on MySQL 8.0.46, default strict sql_mode,
--         ONLY_FULL_GROUP_BY, sql_safe_updates = 1 as in MySQL Workbench).
-- Prerequisites:
--   1. healthcare_analytics contains the 10 OLTP tables with data
--   2. star_schema.sql has been run (creates database dw and its tables)
-- Safe to re-run: step 0 empties the warehouse tables first.
--
-- MySQL Workbench: long statements can exceed the default 30 s read
-- timeout on large data. Raise it under Edit > Preferences > SQL Editor >
-- "DBMS connection read timeout" (e.g. 600), then reconnect.
--
-- To use a different source schema, find/replace "healthcare_analytics."
-- =====================================================================
USE healthcare_analytics_dw;

SET @old_safe_updates = @@SESSION.sql_safe_updates;
SET SESSION sql_safe_updates        = 0;      -- Workbench default (1) blocks the multi-table UPDATEs below
SET SESSION foreign_key_checks      = 0;      -- bulk load; integrity verified in step 9
SET SESSION cte_max_recursion_depth = 10000;  -- dim_date needs ~7,700 recursion steps (default 1000)

-- ---------------------------------------------------------------
-- 0. Reset: empty warehouse tables so the full load can be re-run
--    (TRUNCATE also resets AUTO_INCREMENT surrogate keys)
-- ---------------------------------------------------------------
TRUNCATE TABLE agg_dx_px_pairs_monthly;
TRUNCATE TABLE bridge_encounter_procedures;
TRUNCATE TABLE bridge_encounter_diagnoses;
TRUNCATE TABLE fact_encounters;
TRUNCATE TABLE dim_procedure;
TRUNCATE TABLE dim_diagnosis;
TRUNCATE TABLE dim_encounter_type;
TRUNCATE TABLE dim_provider;
TRUNCATE TABLE dim_department;
TRUNCATE TABLE dim_specialty;
TRUNCATE TABLE dim_patient;
TRUNCATE TABLE dim_date;

-- temp tables live as long as the connection (e.g. a Workbench tab)
DROP TEMPORARY TABLE IF EXISTS stg_dx, stg_px, stg_bill, stg_ip, stg_ip2, stg_readmit;

INSERT INTO etl_batch_log (started_at) VALUES (NOW());
SET @batch := LAST_INSERT_ID();

-- ---------------------------------------------------------------
-- 1. dim_date (one-time): every day 2015-01-01 .. 2035-12-31
-- ---------------------------------------------------------------
INSERT INTO dim_date
WITH RECURSIVE d AS (
    SELECT DATE('2015-01-01') AS dt
    UNION ALL
    SELECT dt + INTERVAL 1 DAY FROM d WHERE dt < '2035-12-31'
)
SELECT CAST(DATE_FORMAT(dt,'%Y%m%d') AS UNSIGNED), dt,
       YEAR(dt), QUARTER(dt), MONTH(dt), MONTHNAME(dt),
       DATE_FORMAT(dt,'%Y-%m'), YEAR(dt)*100+MONTH(dt),
       DAY(dt), DAYOFWEEK(dt), DAYNAME(dt), WEEK(dt,3),
       DAYOFWEEK(dt) IN (1,7),
       YEAR(dt) + (MONTH(dt) >= 7),                    -- FY starts July 1
       ((MONTH(dt) + 5) MOD 12) DIV 3 + 1
FROM d;
INSERT INTO dim_date VALUES (-1, NULL, 0, 0, 0, 'Unknown', 'Unknown', -1, 0, 0, 'Unknown', 0, FALSE, 0, 0);

-- ---------------------------------------------------------------
-- 2. Unknown members (key -1) so fact FKs are never NULL
-- ---------------------------------------------------------------
INSERT INTO dim_patient (patient_key, patient_id, full_name) VALUES (-1, -1, 'Unknown');
INSERT INTO dim_specialty (specialty_key, specialty_id, specialty_code, specialty_name) VALUES (-1, -1, 'UNK', 'Unknown');
INSERT INTO dim_department (department_key, department_id, department_name) VALUES (-1, -1, 'Unknown');
INSERT INTO dim_provider (provider_key, provider_id, full_name) VALUES (-1, -1, 'Unknown');
INSERT INTO dim_encounter_type (encounter_type_key, encounter_type_name, encounter_type_code) VALUES (-1, 'Unknown', 'UNK');
INSERT INTO dim_diagnosis (diagnosis_key, diagnosis_id, icd10_code, icd10_description) VALUES (-1, -1, 'UNK', 'No diagnosis recorded');
INSERT INTO dim_procedure (procedure_key, procedure_id, cpt_code, cpt_description) VALUES (-1, -1, 'UNK', 'Unknown');

-- ---------------------------------------------------------------
-- 3. Conformed dimensions from OLTP
-- ---------------------------------------------------------------
INSERT INTO dim_specialty (specialty_id, specialty_code, specialty_name)
SELECT specialty_id, specialty_code, COALESCE(specialty_name,'Unknown') FROM healthcare_analytics.specialties;

INSERT INTO dim_department (department_id, department_name, floor, capacity)
SELECT department_id, COALESCE(department_name,'Unknown'), floor, capacity FROM healthcare_analytics.departments;

INSERT INTO dim_encounter_type (encounter_type_name, encounter_type_code, is_inpatient, is_emergency)
SELECT DISTINCT encounter_type,
       CASE encounter_type WHEN 'Inpatient' THEN 'IP' WHEN 'Outpatient' THEN 'OP' WHEN 'ER' THEN 'ER' ELSE 'OTH' END,
       encounter_type = 'Inpatient', encounter_type = 'ER'
FROM healthcare_analytics.encounters WHERE encounter_type IS NOT NULL;

INSERT INTO dim_patient (patient_id, mrn, first_name, last_name, full_name, date_of_birth, birth_year,
                         gender, gender_desc, current_age_group, row_hash)
SELECT p.patient_id, p.mrn, p.first_name, p.last_name, CONCAT_WS(' ', p.first_name, p.last_name),
       p.date_of_birth, YEAR(p.date_of_birth), p.gender,
       CASE p.gender WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female' ELSE 'Unknown' END,
       CASE WHEN p.date_of_birth IS NULL THEN 'Unknown'
            WHEN TIMESTAMPDIFF(YEAR, p.date_of_birth, CURDATE()) < 18 THEN '0-17'
            WHEN TIMESTAMPDIFF(YEAR, p.date_of_birth, CURDATE()) < 40 THEN '18-39'
            WHEN TIMESTAMPDIFF(YEAR, p.date_of_birth, CURDATE()) < 65 THEN '40-64'
            WHEN TIMESTAMPDIFF(YEAR, p.date_of_birth, CURDATE()) < 80 THEN '65-79'
            ELSE '80+' END,
       MD5(CONCAT_WS('|', p.mrn, p.first_name, p.last_name, p.date_of_birth, p.gender))
FROM healthcare_analytics.patients p;

-- Provider SCD2: initial load = one current version per provider, valid from the beginning of time
INSERT INTO dim_provider (provider_id, first_name, last_name, full_name, credential,
                          specialty_id, specialty_name, department_id, department_name, row_hash,
                          effective_from, effective_to, is_current)
SELECT pr.provider_id, pr.first_name, pr.last_name, CONCAT_WS(' ', pr.first_name, pr.last_name), pr.credential,
       pr.specialty_id, s.specialty_name, pr.department_id, d.department_name,
       MD5(CONCAT_WS('|', pr.first_name, pr.last_name, pr.credential, pr.specialty_id, pr.department_id)),
       '1900-01-01', '9999-12-31', TRUE
FROM healthcare_analytics.providers pr
LEFT JOIN healthcare_analytics.specialties s ON s.specialty_id  = pr.specialty_id
LEFT JOIN healthcare_analytics.departments d ON d.department_id = pr.department_id;

INSERT INTO dim_diagnosis (diagnosis_id, icd10_code, icd10_description, icd10_chapter, icd10_category)
SELECT diagnosis_id, icd10_code, icd10_description, LEFT(icd10_code,1), LEFT(icd10_code,3) FROM healthcare_analytics.diagnoses;

INSERT INTO dim_procedure (procedure_id, cpt_code, cpt_description)
SELECT procedure_id, cpt_code, cpt_description FROM healthcare_analytics.procedures;

-- ---------------------------------------------------------------
-- 4. Staging: per-encounter metrics. Each child table is aggregated
--    SEPARATELY to one row per encounter before joining, which avoids
--    the diagnosis x procedure x billing fan-out.
-- ---------------------------------------------------------------
CREATE TEMPORARY TABLE stg_dx (PRIMARY KEY (encounter_id)) AS
SELECT ed.encounter_id,
       COUNT(*) AS diagnosis_count,
       MIN(CASE WHEN ed.diagnosis_sequence = 1 THEN ed.diagnosis_id END) AS primary_diagnosis_id
FROM healthcare_analytics.encounter_diagnoses ed
WHERE ed.encounter_id IS NOT NULL
GROUP BY ed.encounter_id;

CREATE TEMPORARY TABLE stg_px (PRIMARY KEY (encounter_id)) AS
SELECT encounter_id, COUNT(*) AS procedure_count
FROM healthcare_analytics.encounter_procedures
WHERE encounter_id IS NOT NULL
GROUP BY encounter_id;

CREATE TEMPORARY TABLE stg_bill (PRIMARY KEY (encounter_id)) AS
SELECT encounter_id, COUNT(*) AS claim_count,
       SUM(COALESCE(claim_amount,0)) AS total_claim, SUM(COALESCE(allowed_amount,0)) AS total_allowed
FROM healthcare_analytics.billing
WHERE encounter_id IS NOT NULL
GROUP BY encounter_id;

-- ---------------------------------------------------------------
-- 5. Fact load: look up every surrogate key, default to -1
-- ---------------------------------------------------------------
INSERT INTO fact_encounters (
    encounter_id, encounter_date_key, discharge_date_key, patient_key, provider_key, specialty_key,
    department_key, encounter_type_key, primary_diagnosis_key, encounter_datetime, discharge_datetime,
    diagnosis_count, procedure_count, claim_count, total_claim_amount, total_allowed_amount,
    length_of_stay_hours, length_of_stay_days, patient_age_at_encounter, is_index_admission, etl_batch_id)
SELECT e.encounter_id,
       COALESCE(dd.date_key, -1),
       COALESCE(dc.date_key, -1),
       COALESCE(dp.patient_key, -1),
       COALESCE(dpr.provider_key, -1),
       COALESCE(ds.specialty_key, -1),
       COALESCE(dep.department_key, -1),
       COALESCE(et.encounter_type_key, -1),
       COALESCE(ddx.diagnosis_key, -1),
       e.encounter_date,
       e.discharge_date,
       COALESCE(x.diagnosis_count, 0),
       COALESCE(px.procedure_count, 0),
       COALESCE(b.claim_count, 0),
       COALESCE(b.total_claim, 0),
       COALESCE(b.total_allowed, 0),
       CASE WHEN e.discharge_date >= e.encounter_date
            THEN ROUND(TIMESTAMPDIFF(MINUTE, e.encounter_date, e.discharge_date) / 60, 2) END,
       CASE WHEN e.discharge_date >= e.encounter_date
            THEN DATEDIFF(e.discharge_date, e.encounter_date) END,
       CASE WHEN TIMESTAMPDIFF(YEAR, dp.date_of_birth, e.encounter_date) BETWEEN 0 AND 130
            THEN TIMESTAMPDIFF(YEAR, dp.date_of_birth, e.encounter_date) END,   -- bad DOB -> NULL, not a strict-mode error
       (e.encounter_type = 'Inpatient' AND e.discharge_date IS NOT NULL),
       @batch
FROM healthcare_analytics.encounters e
LEFT JOIN dim_date dd           ON dd.calendar_date = DATE(e.encounter_date)
LEFT JOIN dim_date dc           ON dc.calendar_date = DATE(e.discharge_date)
LEFT JOIN dim_patient dp        ON dp.patient_id    = e.patient_id
LEFT JOIN dim_provider dpr      ON dpr.provider_id  = e.provider_id
                               AND DATE(e.encounter_date) BETWEEN dpr.effective_from AND dpr.effective_to
LEFT JOIN dim_specialty ds      ON ds.specialty_id  = dpr.specialty_id          -- specialty AS OF the encounter
LEFT JOIN dim_department dep    ON dep.department_id = e.department_id
LEFT JOIN dim_encounter_type et ON et.encounter_type_name = e.encounter_type
LEFT JOIN stg_dx x              ON x.encounter_id  = e.encounter_id
LEFT JOIN dim_diagnosis ddx     ON ddx.diagnosis_id = x.primary_diagnosis_id
LEFT JOIN stg_px px             ON px.encounter_id = e.encounter_id
LEFT JOIN stg_bill b            ON b.encounter_id  = e.encounter_id;

-- ---------------------------------------------------------------
-- 6. Readmission flags: the self-join runs ONCE here instead of in
--    every report. For each index admission find the first later
--    inpatient admission for the same patient after discharge.
-- ---------------------------------------------------------------
CREATE TEMPORARY TABLE stg_ip (PRIMARY KEY (encounter_key), KEY (patient_key, encounter_datetime)) AS
SELECT f.encounter_key, f.patient_key, f.encounter_datetime, f.discharge_datetime, f.is_index_admission
FROM fact_encounters f
JOIN dim_encounter_type t ON t.encounter_type_key = f.encounter_type_key AND t.is_inpatient;

CREATE TEMPORARY TABLE stg_ip2 LIKE stg_ip;          -- MySQL cannot reopen a temp table in one query
INSERT INTO stg_ip2 SELECT * FROM stg_ip;

CREATE TEMPORARY TABLE stg_readmit (PRIMARY KEY (encounter_key)) AS
SELECT a.encounter_key,
       MIN(n.encounter_datetime) AS next_admit
FROM stg_ip a
JOIN stg_ip2 n ON n.patient_key = a.patient_key
              AND n.encounter_datetime >  a.discharge_datetime
              AND n.encounter_datetime <= a.discharge_datetime + INTERVAL 30 DAY
WHERE a.is_index_admission
GROUP BY a.encounter_key;

UPDATE fact_encounters f
JOIN stg_readmit r ON r.encounter_key = f.encounter_key
SET f.is_readmitted_30d     = TRUE,
    f.days_to_next_admission = DATEDIFF(r.next_admit, f.discharge_datetime);

-- mark the admission that IS the readmission (useful for "readmissions by admitting specialty")
UPDATE fact_encounters f
JOIN (SELECT DISTINCT n.encounter_key
      FROM stg_ip a
      JOIN stg_ip2 n ON n.patient_key = a.patient_key
                    AND n.encounter_datetime >  a.discharge_datetime
                    AND n.encounter_datetime <= a.discharge_datetime + INTERVAL 30 DAY
      WHERE a.is_index_admission) r ON r.encounter_key = f.encounter_key
SET f.is_readmission = TRUE;

-- ---------------------------------------------------------------
-- 7. Bridge tables
-- ---------------------------------------------------------------
INSERT INTO bridge_encounter_diagnoses (encounter_key, diagnosis_sequence, diagnosis_key, is_primary)
SELECT f.encounter_key,
       ROW_NUMBER() OVER (PARTITION BY ed.encounter_id ORDER BY ed.diagnosis_sequence, ed.encounter_diagnosis_id),
       COALESCE(d.diagnosis_key, -1),
       ed.diagnosis_sequence = 1
FROM healthcare_analytics.encounter_diagnoses ed
JOIN fact_encounters f     ON f.encounter_id = ed.encounter_id
LEFT JOIN dim_diagnosis d  ON d.diagnosis_id = ed.diagnosis_id;

INSERT INTO bridge_encounter_procedures (encounter_key, procedure_seq, procedure_key, procedure_date_key)
SELECT f.encounter_key,
       ROW_NUMBER() OVER (PARTITION BY ep.encounter_id ORDER BY ep.procedure_date, ep.encounter_procedure_id),
       COALESCE(p.procedure_key, -1),
       COALESCE(CAST(DATE_FORMAT(ep.procedure_date,'%Y%m%d') AS SIGNED), f.encounter_date_key)
FROM healthcare_analytics.encounter_procedures ep
JOIN fact_encounters f     ON f.encounter_id = ep.encounter_id
LEFT JOIN dim_procedure p  ON p.procedure_id = ep.procedure_id;

-- ---------------------------------------------------------------
-- 8. Aggregate: diagnosis-procedure pairs per month
-- ---------------------------------------------------------------
INSERT INTO agg_dx_px_pairs_monthly (year_month_key, diagnosis_key, procedure_key, encounter_count)
SELECT f.encounter_date_key DIV 100, bd.diagnosis_key, bp.procedure_key, COUNT(DISTINCT f.encounter_key)
FROM fact_encounters f
JOIN bridge_encounter_diagnoses  bd ON bd.encounter_key = f.encounter_key
JOIN bridge_encounter_procedures bp ON bp.encounter_key = f.encounter_key
GROUP BY f.encounter_date_key DIV 100, bd.diagnosis_key, bp.procedure_key;

-- ---------------------------------------------------------------
-- 9. Reconciliation checks (should all return 0) and batch close
-- ---------------------------------------------------------------
SET SESSION foreign_key_checks = 1;
SELECT 'encounters missing from fact' AS chk,
       (SELECT COUNT(*) FROM healthcare_analytics.encounters) - (SELECT COUNT(*) FROM fact_encounters) AS diff
UNION ALL SELECT 'allowed amount difference',
       (SELECT SUM(allowed_amount) FROM healthcare_analytics.billing) - (SELECT SUM(total_allowed_amount) FROM fact_encounters)
UNION ALL SELECT 'diagnosis rows difference',
       (SELECT COUNT(*) FROM healthcare_analytics.encounter_diagnoses) - (SELECT COUNT(*) FROM bridge_encounter_diagnoses)
UNION ALL SELECT 'procedure rows difference',
       (SELECT COUNT(*) FROM healthcare_analytics.encounter_procedures) - (SELECT COUNT(*) FROM bridge_encounter_procedures);

UPDATE etl_batch_log
SET finished_at = NOW(), status = 'SUCCESS',
    rows_inserted = (SELECT COUNT(*) FROM fact_encounters),
    high_watermark = (SELECT MAX(encounter_date) FROM healthcare_analytics.encounters)
WHERE etl_batch_id = @batch;

SET SESSION sql_safe_updates = @old_safe_updates;   -- restore Workbench setting