USE healthcare_analytics_dw;

-- QUESTION 1: Monthly Encounters by Specialty
SELECT m.month_label                 AS encounter_month,
       s.specialty_name,
       t.encounter_type_name         AS encounter_type,
       a.total_encounters,
       a.unique_patients
FROM (
    SELECT f.encounter_date_key DIV 100     AS year_month_key,
           f.specialty_key,
           f.encounter_type_key,
           COUNT(*)                         AS total_encounters,
           COUNT(DISTINCT f.patient_key)    AS unique_patients
    FROM fact_encounters f
    GROUP BY f.encounter_date_key DIV 100, f.specialty_key, f.encounter_type_key
) a
JOIN (SELECT DISTINCT year_month_key, month_label FROM dim_date) m ON m.year_month_key = a.year_month_key
JOIN dim_specialty      s ON s.specialty_key      = a.specialty_key
JOIN dim_encounter_type t ON t.encounter_type_key = a.encounter_type_key
ORDER BY encounter_month, s.specialty_name, encounter_type;

-- QUESTION 2: Top Diagnosis-Procedure Pairs
SELECT dx.icd10_code, dx.icd10_description, px.cpt_code, px.cpt_description,
       a.encounter_count
FROM (SELECT diagnosis_key, procedure_key, SUM(encounter_count) AS encounter_count
      FROM agg_dx_px_pairs_monthly
      GROUP BY diagnosis_key, procedure_key
      ORDER BY encounter_count DESC
      LIMIT 20) a
JOIN dim_diagnosis dx ON dx.diagnosis_key = a.diagnosis_key
JOIN dim_procedure px ON px.procedure_key = a.procedure_key
ORDER BY a.encounter_count DESC;

-- QUESTION 3: 30-Day Readmission Rate
SELECT s.specialty_name,
       COUNT(*)                                              AS index_discharges,
       SUM(f.is_readmitted_30d)                              AS readmissions,
       ROUND(100.0 * SUM(f.is_readmitted_30d) / COUNT(*), 2) AS readmission_rate_pct
FROM fact_encounters f
JOIN dim_specialty s ON s.specialty_key = f.specialty_key
WHERE f.is_index_admission = TRUE
GROUP BY s.specialty_name
ORDER BY readmission_rate_pct DESC;

-- QUESTION 4: Revenue by Specialty and Month (service month)
SELECT s.specialty_name,
       m.month_label         AS service_month,
       a.total_allowed,
       a.total_claimed,
       a.billed_encounters
FROM (
    SELECT f.specialty_key,
           f.encounter_date_key DIV 100   AS year_month_key,
           SUM(f.total_allowed_amount)    AS total_allowed,
           SUM(f.total_claim_amount)      AS total_claimed,
           SUM(f.claim_count > 0)         AS billed_encounters
    FROM fact_encounters f
    GROUP BY f.specialty_key, f.encounter_date_key DIV 100
) a                                              -- CHANGED: alias "a" was missing
JOIN dim_specialty s ON s.specialty_key = a.specialty_key
JOIN (SELECT DISTINCT year_month_key, month_label FROM dim_date) m ON m.year_month_key = a.year_month_key
WHERE a.billed_encounters > 0
ORDER BY s.specialty_name, service_month;