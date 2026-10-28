
USE healthcare_analytics_dw;

EXPLAIN ANALYZE
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