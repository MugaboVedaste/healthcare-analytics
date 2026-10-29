-- ============================================================
-- Healthcare Analytics: Star Schema
-- Source: OLTP healthcare database
-- MySQL 8.0+
-- ============================================================

CREATE DATABASE IF NOT EXISTS healthcare_analytics_dw;
USE healthcare_analytics_dw;

-- 1. Date dimension
CREATE TABLE IF NOT EXISTS dim_date (
    date_key INT PRIMARY KEY COMMENT 'YYYYMMDD',
    calendar_date DATE NOT NULL UNIQUE,
    day_number TINYINT NOT NULL,
    month_number TINYINT NOT NULL,
    month_name VARCHAR(15) NOT NULL,
    quarter_number TINYINT NOT NULL,
    year_number SMALLINT NOT NULL,
    day_of_week_number TINYINT NOT NULL,
    day_name VARCHAR(15) NOT NULL
);

-- 2. Patient dimension
CREATE TABLE IF NOT EXISTS dim_patient (
    patient_key INT AUTO_INCREMENT PRIMARY KEY,
    patient_id INT NOT NULL UNIQUE COMMENT 'OLTP patient ID',
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    date_of_birth DATE,
    gender VARCHAR(30),
    mrn VARCHAR(50),
    INDEX idx_dim_patient_name (last_name, first_name)
);

-- 3. Specialty dimension
CREATE TABLE IF NOT EXISTS dim_specialty (
    specialty_key INT AUTO_INCREMENT PRIMARY KEY,
    specialty_id INT NOT NULL UNIQUE COMMENT 'OLTP specialty ID',
    specialty_name VARCHAR(100) NOT NULL,
    specialty_code VARCHAR(30)
);

-- 4. Department dimension
CREATE TABLE IF NOT EXISTS dim_department (
    department_key INT AUTO_INCREMENT PRIMARY KEY,
    department_id INT NOT NULL UNIQUE COMMENT 'OLTP department ID',
    department_name VARCHAR(100) NOT NULL,
    floor VARCHAR(30),
    capacity INT
);

-- 5. Provider dimension
CREATE TABLE IF NOT EXISTS dim_provider (
    provider_key INT AUTO_INCREMENT PRIMARY KEY,
    provider_id INT NOT NULL UNIQUE COMMENT 'OLTP provider ID',
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    credential VARCHAR(50),
    INDEX idx_dim_provider_name (last_name, first_name)
);

-- 6. Encounter type dimension
CREATE TABLE IF NOT EXISTS dim_encounter_type (
    encounter_type_key INT AUTO_INCREMENT PRIMARY KEY,
    encounter_type_name VARCHAR(50) NOT NULL UNIQUE
);

-- 7. Diagnosis dimension
CREATE TABLE IF NOT EXISTS dim_diagnosis (
    diagnosis_key INT AUTO_INCREMENT PRIMARY KEY,
    diagnosis_id INT NOT NULL UNIQUE COMMENT 'OLTP diagnosis ID',
    icd10_code VARCHAR(20) NOT NULL,
    icd10_description VARCHAR(255),
    INDEX idx_dim_diagnosis_code (icd10_code)
);

-- 8. Procedure dimension
CREATE TABLE IF NOT EXISTS dim_procedure (
    procedure_key INT AUTO_INCREMENT PRIMARY KEY,
    procedure_id INT NOT NULL UNIQUE COMMENT 'OLTP procedure ID',
    cpt_code VARCHAR(20) NOT NULL,
    cpt_description VARCHAR(255),
    INDEX idx_dim_procedure_code (cpt_code)
);

-- 9. Encounter fact
-- Grain: one row per source encounter.
CREATE TABLE IF NOT EXISTS fact_encounters (
    encounter_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    encounter_id INT NOT NULL UNIQUE COMMENT 'OLTP encounter ID',

    patient_key INT NOT NULL,
    provider_key INT NOT NULL,
    specialty_key INT NOT NULL,
    department_key INT NOT NULL,
    encounter_type_key INT NOT NULL,

    encounter_date_key INT NOT NULL,
    discharge_date_key INT NULL,

    -- Preserve source date/time values for time-based analysis.
    encounter_datetime DATETIME NOT NULL,
    discharge_datetime DATETIME NULL,

    diagnosis_count INT NOT NULL DEFAULT 0,
    procedure_count INT NOT NULL DEFAULT 0,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_fact_enc_patient
        FOREIGN KEY (patient_key)
        REFERENCES dim_patient(patient_key),

    CONSTRAINT fk_fact_enc_provider
        FOREIGN KEY (provider_key)
        REFERENCES dim_provider(provider_key),

    CONSTRAINT fk_fact_enc_specialty
        FOREIGN KEY (specialty_key)
        REFERENCES dim_specialty(specialty_key),

    CONSTRAINT fk_fact_enc_department
        FOREIGN KEY (department_key)
        REFERENCES dim_department(department_key),

    CONSTRAINT fk_fact_enc_type
        FOREIGN KEY (encounter_type_key)
        REFERENCES dim_encounter_type(encounter_type_key),

    CONSTRAINT fk_fact_enc_date
        FOREIGN KEY (encounter_date_key)
        REFERENCES dim_date(date_key),

    CONSTRAINT fk_fact_discharge_date
        FOREIGN KEY (discharge_date_key)
        REFERENCES dim_date(date_key),

    INDEX idx_fact_enc_date (encounter_date_key),
    INDEX idx_fact_enc_specialty_date
        (specialty_key, encounter_date_key),
    INDEX idx_fact_enc_patient_datetime
        (patient_key, encounter_datetime),
    INDEX idx_fact_enc_type_date
        (encounter_type_key, encounter_date_key)
);

-- 10. Bridge: diagnoses associated with encounters
CREATE TABLE IF NOT EXISTS bridge_encounter_diagnoses (
    encounter_key BIGINT NOT NULL,
    diagnosis_key INT NOT NULL,
    diagnosis_sequence INT NOT NULL DEFAULT 1,

    PRIMARY KEY (
        encounter_key,
        diagnosis_key,
        diagnosis_sequence
    ),

    CONSTRAINT fk_bridge_diag_encounter
        FOREIGN KEY (encounter_key)
        REFERENCES fact_encounters(encounter_key),

    CONSTRAINT fk_bridge_diag_diagnosis
        FOREIGN KEY (diagnosis_key)
        REFERENCES dim_diagnosis(diagnosis_key),

    INDEX idx_bridge_diag_diagnosis (diagnosis_key)
);

-- 11. Bridge: procedures associated with encounters
CREATE TABLE bridge_encounter_procedures (
    encounter_procedure_id INT NOT NULL,
    encounter_key BIGINT NOT NULL,
    procedure_key INT NOT NULL,
    procedure_date_key INT DEFAULT NULL,

    PRIMARY KEY (encounter_procedure_id),

    KEY idx_bridge_proc_encounter (encounter_key),
    KEY idx_bridge_proc_procedure (procedure_key),
    KEY idx_bridge_proc_date (procedure_date_key),

    CONSTRAINT fk_bridge_proc_encounter
        FOREIGN KEY (encounter_key)
        REFERENCES fact_encounters (encounter_key),

    CONSTRAINT fk_bridge_proc_procedure
        FOREIGN KEY (procedure_key)
        REFERENCES dim_procedure (procedure_key),

    CONSTRAINT fk_bridge_proc_date
        FOREIGN KEY (procedure_date_key)
        REFERENCES dim_date (date_key)
);

-- 12. Billing fact
-- Grain: one row per source billing record.
CREATE TABLE IF NOT EXISTS fact_billing (
    billing_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    billing_id INT NOT NULL UNIQUE COMMENT 'OLTP billing ID',
    encounter_key BIGINT NOT NULL,
    claim_date_key INT NOT NULL,

    claim_amount DECIMAL(12,2) NOT NULL DEFAULT 0,
    allowed_amount DECIMAL(12,2) NOT NULL DEFAULT 0,
    claim_status VARCHAR(50),

    CONSTRAINT fk_fact_billing_encounter
        FOREIGN KEY (encounter_key)
        REFERENCES fact_encounters(encounter_key),

    CONSTRAINT fk_fact_billing_date
        FOREIGN KEY (claim_date_key)
        REFERENCES dim_date(date_key),

    INDEX idx_fact_billing_date (claim_date_key),
    INDEX idx_fact_billing_encounter (encounter_key)
);
