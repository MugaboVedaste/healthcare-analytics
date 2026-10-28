
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
