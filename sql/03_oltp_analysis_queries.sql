
USE healthcare_analytics;

-- Query 1: Monthly Encounters by Specialty
-- Purpose: Count encounters and unique patients
-- by month, specialty, and encounter type.

SELECT
    YEAR(e.encounter_date) AS encounter_year,
    MONTH(e.encounter_date) AS encounter_month,
    s.specialty_name,
    e.encounter_type,
    COUNT(DISTINCT e.encounter_id) AS total_encounters,
    COUNT(DISTINCT e.patient_id) AS unique_patients
FROM encounters AS e
JOIN providers AS p
    ON e.provider_id = p.provider_id
JOIN specialties AS s
    ON p.specialty_id = s.specialty_id
GROUP BY
    YEAR(e.encounter_date),
    MONTH(e.encounter_date),
    s.specialty_name,
    e.encounter_type
ORDER BY
    encounter_year,
    encounter_month,
    s.specialty_name,
    e.encounter_type;
    


-- Query 2: Top Diagnosis-Procedure Pairs
SELECT
    d.icd10_code,
    d.icd10_description,
    pr.cpt_code,
    pr.cpt_description,
    COUNT(DISTINCT e.encounter_id) AS encounter_count
FROM encounters AS e
JOIN encounter_diagnoses AS ed
    ON e.encounter_id = ed.encounter_id
JOIN diagnoses AS d
    ON ed.diagnosis_id = d.diagnosis_id
JOIN encounter_procedures AS ep
    ON e.encounter_id = ep.encounter_id
JOIN procedures AS pr
    ON ep.procedure_id = pr.procedure_id
GROUP BY
    d.icd10_code,
    d.icd10_description,
    pr.cpt_code,
    pr.cpt_description
ORDER BY
    encounter_count DESC,
    d.icd10_code,
    pr.cpt_code;

-- QUESTION 3: 30-Day Readmission Rate

SELECT
    s.specialty_name,
    COUNT(DISTINCT e.encounter_id) AS total_inpatient_discharges,
    COUNT(DISTINCT CASE
        WHEN r.encounter_id IS NOT NULL THEN e.encounter_id
    END) AS readmitted_encounters,
    ROUND(
        100.0 * COUNT(DISTINCT CASE
            WHEN r.encounter_id IS NOT NULL THEN e.encounter_id
        END) / NULLIF(COUNT(DISTINCT e.encounter_id), 0),
        2
    ) AS readmission_rate_percentage
FROM encounters AS e
JOIN providers AS p
    ON e.provider_id = p.provider_id
JOIN specialties AS s
    ON p.specialty_id = s.specialty_id
LEFT JOIN encounters AS r
    ON r.patient_id = e.patient_id
    AND r.encounter_date > e.discharge_date
    AND r.encounter_date <= DATE_ADD(
        e.discharge_date, INTERVAL 30 DAY
    )
WHERE e.encounter_type = 'Inpatient'
    AND e.discharge_date IS NOT NULL
GROUP BY s.specialty_id, s.specialty_name
ORDER BY readmission_rate_percentage DESC;


-- QUESTION 4: Revenue by Specialty and Month

SELECT
    YEAR(b.claim_date) AS claim_year,
    MONTH(b.claim_date) AS claim_month,
    s.specialty_name,
    SUM(b.allowed_amount) AS total_revenue,
    COUNT(DISTINCT b.billing_id) AS total_claims
FROM billing AS b
JOIN encounters AS e
    ON b.encounter_id = e.encounter_id
JOIN providers AS p
    ON e.provider_id = p.provider_id
JOIN specialties AS s
    ON p.specialty_id = s.specialty_id
GROUP BY
    YEAR(b.claim_date),
    MONTH(b.claim_date),
    s.specialty_id,
    s.specialty_name
ORDER BY
    claim_year,
    claim_month,
    s.specialty_name;
