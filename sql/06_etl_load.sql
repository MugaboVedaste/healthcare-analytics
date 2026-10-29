
-- ============================================================
-- ETL: Transfer OLTP sample data into the star schema
-- ============================================================

USE healthcare_analytics_dw;

-- STEP 1: Load dimensions

INSERT INTO dim_patient
    (patient_id, first_name, last_name, date_of_birth, gender, mrn)
SELECT
    patient_id, first_name, last_name, date_of_birth, gender, mrn
FROM healthcare_analytics.patients
ON DUPLICATE KEY UPDATE
    first_name = VALUES(first_name),
    last_name = VALUES(last_name),
    date_of_birth = VALUES(date_of_birth),
    gender = VALUES(gender),
    mrn = VALUES(mrn);

INSERT INTO dim_specialty
    (specialty_id, specialty_name, specialty_code)
SELECT specialty_id, specialty_name, specialty_code
FROM healthcare_analytics.specialties
ON DUPLICATE KEY UPDATE
    specialty_name = VALUES(specialty_name),
    specialty_code = VALUES(specialty_code);

INSERT INTO dim_department
    (department_id, department_name, floor, capacity)
SELECT department_id, department_name, floor, capacity
FROM healthcare_analytics.departments
ON DUPLICATE KEY UPDATE
    department_name = VALUES(department_name),
    floor = VALUES(floor),
    capacity = VALUES(capacity);

INSERT INTO dim_provider
    (provider_id, first_name, last_name, credential)
SELECT provider_id, first_name, last_name, credential
FROM healthcare_analytics.providers
ON DUPLICATE KEY UPDATE
    first_name = VALUES(first_name),
    last_name = VALUES(last_name),
    credential = VALUES(credential);

INSERT INTO dim_encounter_type (encounter_type_name)
SELECT DISTINCT encounter_type
FROM healthcare_analytics.encounters
WHERE encounter_type IS NOT NULL
ON DUPLICATE KEY UPDATE
    encounter_type_name = VALUES(encounter_type_name);

INSERT INTO dim_diagnosis
    (diagnosis_id, icd10_code, icd10_description)
SELECT diagnosis_id, icd10_code, icd10_description
FROM healthcare_analytics.diagnoses
ON DUPLICATE KEY UPDATE
    icd10_code = VALUES(icd10_code),
    icd10_description = VALUES(icd10_description);

INSERT INTO dim_procedure
    (procedure_id, cpt_code, cpt_description)
SELECT procedure_id, cpt_code, cpt_description
FROM healthcare_analytics.procedures
ON DUPLICATE KEY UPDATE
    cpt_code = VALUES(cpt_code),
    cpt_description = VALUES(cpt_description);


-- STEP 2: Load dates from all relevant source tables.
-- The source timestamps are converted to calendar dates
-- only for dim_date; original timestamps remain in the fact.

INSERT IGNORE INTO dim_date (
    date_key, calendar_date, day_number, month_number,
    month_name, quarter_number, year_number,
    day_of_week_number, day_name
)
SELECT
    CAST(DATE_FORMAT(d.calendar_date, '%Y%m%d') AS UNSIGNED),
    d.calendar_date,
    DAY(d.calendar_date),
    MONTH(d.calendar_date),
    MONTHNAME(d.calendar_date),
    QUARTER(d.calendar_date),
    YEAR(d.calendar_date),
    DAYOFWEEK(d.calendar_date),
    DAYNAME(d.calendar_date)
FROM (
    SELECT DATE(encounter_date) AS calendar_date
    FROM healthcare_analytics.encounters

    UNION

    SELECT DATE(discharge_date)
    FROM healthcare_analytics.encounters
    WHERE discharge_date IS NOT NULL

    UNION

    SELECT procedure_date
    FROM healthcare_analytics.encounter_procedures
    WHERE procedure_date IS NOT NULL

    UNION

    SELECT claim_date
    FROM healthcare_analytics.billing
    WHERE claim_date IS NOT NULL
) AS d
WHERE d.calendar_date IS NOT NULL;


-- STEP 3: Load encounter facts.
-- Each row represents one encounter.

INSERT INTO fact_encounters (
    encounter_id, patient_key, provider_key, specialty_key,
    department_key, encounter_type_key,
    encounter_date_key, discharge_date_key,
    encounter_datetime, discharge_datetime,
    diagnosis_count, procedure_count
)
SELECT
    e.encounter_id,
    dp.patient_key,
    dpr.provider_key,
    ds.specialty_key,
    dd.department_key,
    det.encounter_type_key,
    CAST(DATE_FORMAT(e.encounter_date, '%Y%m%d') AS UNSIGNED),
    CASE
        WHEN e.discharge_date IS NOT NULL
        THEN CAST(DATE_FORMAT(e.discharge_date, '%Y%m%d') AS UNSIGNED)
        ELSE NULL
    END,
    e.encounter_date,
    e.discharge_date,
    (
        SELECT COUNT(*)
        FROM healthcare_analytics.encounter_diagnoses ed
        WHERE ed.encounter_id = e.encounter_id
    ),
    (
        SELECT COUNT(*)
        FROM healthcare_analytics.encounter_procedures ep
        WHERE ep.encounter_id = e.encounter_id
    )
FROM healthcare_analytics.encounters e
JOIN dim_patient dp
    ON dp.patient_id = e.patient_id
JOIN healthcare_analytics.providers sp
    ON sp.provider_id = e.provider_id
JOIN dim_provider dpr
    ON dpr.provider_id = sp.provider_id
JOIN dim_specialty ds
    ON ds.specialty_id = sp.specialty_id
JOIN dim_department dd
    ON dd.department_id = e.department_id
JOIN dim_encounter_type det
    ON det.encounter_type_name = e.encounter_type
ON DUPLICATE KEY UPDATE
    patient_key = VALUES(patient_key),
    provider_key = VALUES(provider_key),
    specialty_key = VALUES(specialty_key),
    department_key = VALUES(department_key),
    encounter_type_key = VALUES(encounter_type_key),
    encounter_date_key = VALUES(encounter_date_key),
    discharge_date_key = VALUES(discharge_date_key),
    encounter_datetime = VALUES(encounter_datetime),
    discharge_datetime = VALUES(discharge_datetime),
    diagnosis_count = VALUES(diagnosis_count),
    procedure_count = VALUES(procedure_count);


-- STEP 4: Load encounter-diagnosis bridge.

INSERT IGNORE INTO bridge_encounter_diagnoses (
    encounter_key, diagnosis_key, diagnosis_sequence
)
SELECT
    fe.encounter_key,
    dgn.diagnosis_key,
    ed.diagnosis_sequence
FROM healthcare_analytics.encounter_diagnoses ed
JOIN fact_encounters fe
    ON fe.encounter_id = ed.encounter_id
JOIN dim_diagnosis dgn
    ON dgn.diagnosis_id = ed.diagnosis_id;


-- STEP 5: Load encounter-procedure bridge
INSERT INTO bridge_encounter_procedures (
    encounter_procedure_id,
    encounter_key,
    procedure_key,
    procedure_date_key
)
SELECT
    ep.encounter_procedure_id,
    fe.encounter_key,
    pr.procedure_key,
    CASE
        WHEN ep.procedure_date IS NOT NULL
        THEN CAST(DATE_FORMAT(ep.procedure_date, '%Y%m%d') AS UNSIGNED)
        ELSE NULL
    END
FROM healthcare_analytics.encounter_procedures ep
JOIN fact_encounters fe
    ON fe.encounter_id = ep.encounter_id
JOIN dim_procedure pr
    ON pr.procedure_id = ep.procedure_id
ON DUPLICATE KEY UPDATE
    encounter_key = VALUES(encounter_key),
    procedure_key = VALUES(procedure_key),
    procedure_date_key = VALUES(procedure_date_key);

-- STEP 6: Load billing fact.

INSERT INTO fact_billing (
    billing_id, encounter_key, claim_date_key,
    claim_amount, allowed_amount, claim_status
)
SELECT
    b.billing_id,
    fe.encounter_key,
    CAST(DATE_FORMAT(b.claim_date, '%Y%m%d') AS UNSIGNED),
    b.claim_amount,
    b.allowed_amount,
    b.claim_status
FROM healthcare_analytics.billing b
JOIN fact_encounters fe
    ON fe.encounter_id = b.encounter_id
ON DUPLICATE KEY UPDATE
    encounter_key = VALUES(encounter_key),
    claim_date_key = VALUES(claim_date_key),
    claim_amount = VALUES(claim_amount),
    allowed_amount = VALUES(allowed_amount),
    claim_status = VALUES(claim_status);
