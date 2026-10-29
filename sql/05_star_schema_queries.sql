
USE healthcare_analytics_dw;


SELECT
    d.year_number AS encounter_year,
    d.month_number AS encounter_month,
    s.specialty_name,
    et.encounter_type_name,
    COUNT(DISTINCT fe.encounter_id) AS total_encounters,
    COUNT(DISTINCT fe.patient_key) AS unique_patients
FROM fact_encounters AS fe
JOIN dim_date AS d
    ON fe.encounter_date_key = d.date_key
JOIN dim_specialty AS s
    ON fe.specialty_key = s.specialty_key
JOIN dim_encounter_type AS et
    ON fe.encounter_type_key = et.encounter_type_key
GROUP BY
    d.year_number,
    d.month_number,
    s.specialty_key,
    s.specialty_name,
    et.encounter_type_key,
    et.encounter_type_name
ORDER BY
    encounter_year,
    encounter_month,
    s.specialty_name,
    et.encounter_type_name;
    
USE healthcare_analytics_dw;


SELECT
    d.icd10_code,
    d.icd10_description,
    p.cpt_code,
    p.cpt_description,
    COUNT(*) AS pair_count
FROM bridge_encounter_diagnoses AS ed
JOIN dim_diagnosis AS d
    ON ed.diagnosis_key = d.diagnosis_key
JOIN bridge_encounter_procedures AS ep
    ON ed.encounter_key = ep.encounter_key
JOIN dim_procedure AS p
    ON ep.procedure_key = p.procedure_key
GROUP BY
    d.diagnosis_key,
    d.icd10_code,
    d.icd10_description,
    p.procedure_key,
    p.cpt_code,
    p.cpt_description
ORDER BY
    pair_count DESC,
    d.icd10_code,
    p.cpt_code
LIMIT 5;