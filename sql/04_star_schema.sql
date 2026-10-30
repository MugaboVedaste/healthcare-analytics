-- =====================================================================
-- star_schema.sql
-- HealthTech Analytics: dimensional model for encounter analytics
-- Target: MySQL 8.0+ (InnoDB). Tested on MySQL 8.0.46; also runs on MariaDB 10.6+.
--
-- Design summary (see design_decisions.txt for the reasoning):
--   * Fact grain: ONE ROW PER ENCOUNTER (fact_encounters)
--   * Specialty / department / encounter type are stamped directly on the
--     fact row as they were AT THE TIME of the encounter, so no query has
--     to walk fact -> provider -> specialty.
--   * Billing, diagnosis and procedure counts and the 30-day readmission
--     flag are pre-computed by the ETL and stored on the fact row.
--   * Diagnoses and procedures (many per encounter) live in two bridge
--     tables keyed by integer surrogate keys.
--   * agg_dx_px_pairs_monthly is a small aggregate fed by the bridges for
--     the diagnosis-procedure pair question (Q2).
--   * Every dimension has an "Unknown" member with key -1 so that fact
--     foreign keys are never NULL.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS healthcare_analytics_dw;
USE healthcare_analytics_dw;

-- ---------------------------------------------------------------------
-- dim_date: one row per calendar day. Static, loaded once (2015-2035).
-- date_key is a smart integer key YYYYMMDD so range filters on the fact
-- table can be written without joining the dimension at all.
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key          INT          NOT NULL COMMENT 'YYYYMMDD; -1 = unknown',
    calendar_date     DATE         NULL,
    year              SMALLINT     NOT NULL,
    quarter           TINYINT      NOT NULL,
    month             TINYINT      NOT NULL,
    month_name        VARCHAR(10)  NOT NULL,
    month_label       CHAR(7)      NOT NULL COMMENT 'e.g. 2024-05, ready for GROUP BY',
    year_month_key    INT          NOT NULL COMMENT 'YYYYMM',
    day_of_month      TINYINT      NOT NULL,
    day_of_week       TINYINT      NOT NULL COMMENT '1=Sunday ... 7=Saturday',
    day_name          VARCHAR(10)  NOT NULL,
    week_of_year      TINYINT      NOT NULL,
    is_weekend        BOOLEAN      NOT NULL,
    fiscal_year       SMALLINT     NOT NULL COMMENT 'FY starts July 1',
    fiscal_quarter    TINYINT      NOT NULL,
    PRIMARY KEY (date_key),
    UNIQUE KEY uq_dim_date_calendar (calendar_date),
    KEY idx_dim_date_ym (year_month_key)
) ENGINE=InnoDB COMMENT='Calendar dimension, one row per day';

-- ---------------------------------------------------------------------
-- dim_patient: one row per patient (SCD Type 1: overwrite on change).
-- Names and MRN are kept for drill-through; analytics use the banded
-- attributes. Age at the time of a visit is on the fact row, because a
-- band stored here can only describe the patient's age today.
-- ---------------------------------------------------------------------
CREATE TABLE dim_patient (
    patient_key       INT          NOT NULL AUTO_INCREMENT,
    patient_id        INT          NOT NULL COMMENT 'Natural key from OLTP patients',
    mrn               VARCHAR(20)  NULL,
    first_name        VARCHAR(100) NULL,
    last_name         VARCHAR(100) NULL,
    full_name         VARCHAR(201) NULL,
    date_of_birth     DATE         NULL,
    birth_year        SMALLINT     NULL,
    gender            CHAR(1)      NULL,
    gender_desc       VARCHAR(10)  NOT NULL DEFAULT 'Unknown',
    current_age_group VARCHAR(10)  NOT NULL DEFAULT 'Unknown' COMMENT 'Band as of last ETL run',
    row_hash          CHAR(32)     NULL COMMENT 'MD5 of tracked columns for change detection',
    etl_loaded_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    etl_updated_at    DATETIME     NULL,
    PRIMARY KEY (patient_key),
    UNIQUE KEY uq_dim_patient_nk (patient_id)
) ENGINE=InnoDB COMMENT='Patient dimension (SCD1)';

-- ---------------------------------------------------------------------
-- dim_specialty: clinical specialty. Small; changes rarely (SCD1).
-- ---------------------------------------------------------------------
CREATE TABLE dim_specialty (
    specialty_key     INT          NOT NULL AUTO_INCREMENT,
    specialty_id      INT          NOT NULL COMMENT 'Natural key',
    specialty_code    VARCHAR(10)  NULL,
    specialty_name    VARCHAR(100) NOT NULL,
    PRIMARY KEY (specialty_key),
    UNIQUE KEY uq_dim_specialty_nk (specialty_id)
) ENGINE=InnoDB COMMENT='Specialty dimension (SCD1)';

-- ---------------------------------------------------------------------
-- dim_department: hospital department / unit (SCD1).
-- ---------------------------------------------------------------------
CREATE TABLE dim_department (
    department_key    INT          NOT NULL AUTO_INCREMENT,
    department_id     INT          NOT NULL COMMENT 'Natural key',
    department_name   VARCHAR(100) NOT NULL,
    floor             INT          NULL,
    capacity          INT          NULL,
    PRIMARY KEY (department_key),
    UNIQUE KEY uq_dim_department_nk (department_id)
) ENGINE=InnoDB COMMENT='Department dimension (SCD1)';

-- ---------------------------------------------------------------------
-- dim_provider: SCD Type 2. When a provider changes specialty or
-- department a new version row is created, so history stays attributed
-- to the specialty the provider had at the time of the encounter.
-- Specialty and department names are copied in (a "snowflake avoided")
-- for provider-level reports.
-- ---------------------------------------------------------------------
CREATE TABLE dim_provider (
    provider_key      INT          NOT NULL AUTO_INCREMENT,
    provider_id       INT          NOT NULL COMMENT 'Natural key',
    first_name        VARCHAR(100) NULL,
    last_name         VARCHAR(100) NULL,
    full_name         VARCHAR(201) NULL,
    credential        VARCHAR(20)  NULL,
    specialty_id      INT          NULL,
    specialty_name    VARCHAR(100) NULL,
    department_id     INT          NULL,
    department_name   VARCHAR(100) NULL,
    row_hash          CHAR(32)     NULL,
    effective_from    DATE         NOT NULL DEFAULT '1900-01-01',
    effective_to      DATE         NOT NULL DEFAULT '9999-12-31',
    is_current        BOOLEAN      NOT NULL DEFAULT TRUE,
    PRIMARY KEY (provider_key),
    KEY idx_dim_provider_nk (provider_id, is_current),
    KEY idx_dim_provider_asof (provider_id, effective_from, effective_to)
) ENGINE=InnoDB COMMENT='Provider dimension (SCD2)';

-- ---------------------------------------------------------------------
-- dim_encounter_type: Outpatient / Inpatient / ER plus grouping flags.
-- ---------------------------------------------------------------------
CREATE TABLE dim_encounter_type (
    encounter_type_key  INT         NOT NULL AUTO_INCREMENT,
    encounter_type_name VARCHAR(50) NOT NULL,
    encounter_type_code VARCHAR(5)  NOT NULL,
    is_inpatient        BOOLEAN     NOT NULL DEFAULT FALSE,
    is_emergency        BOOLEAN     NOT NULL DEFAULT FALSE,
    PRIMARY KEY (encounter_type_key),
    UNIQUE KEY uq_dim_encounter_type_name (encounter_type_name)
) ENGINE=InnoDB COMMENT='Encounter type dimension';

-- ---------------------------------------------------------------------
-- dim_diagnosis: ICD-10 codes, with the chapter letter for roll-ups.
-- ---------------------------------------------------------------------
CREATE TABLE dim_diagnosis (
    diagnosis_key     INT          NOT NULL AUTO_INCREMENT,
    diagnosis_id      INT          NOT NULL COMMENT 'Natural key',
    icd10_code        VARCHAR(10)  NOT NULL,
    icd10_description VARCHAR(200) NULL,
    icd10_chapter     CHAR(1)      NULL COMMENT 'First character of code',
    icd10_category    VARCHAR(3)   NULL COMMENT 'First three characters, e.g. I50',
    PRIMARY KEY (diagnosis_key),
    UNIQUE KEY uq_dim_diagnosis_nk (diagnosis_id),
    KEY idx_dim_diagnosis_code (icd10_code)
) ENGINE=InnoDB COMMENT='Diagnosis dimension (ICD-10)';

-- ---------------------------------------------------------------------
-- dim_procedure: CPT codes.
-- ---------------------------------------------------------------------
CREATE TABLE dim_procedure (
    procedure_key     INT          NOT NULL AUTO_INCREMENT,
    procedure_id      INT          NOT NULL COMMENT 'Natural key',
    cpt_code          VARCHAR(10)  NOT NULL,
    cpt_description   VARCHAR(200) NULL,
    PRIMARY KEY (procedure_key),
    UNIQUE KEY uq_dim_procedure_nk (procedure_id),
    KEY idx_dim_procedure_code (cpt_code)
) ENGINE=InnoDB COMMENT='Procedure dimension (CPT)';

-- ---------------------------------------------------------------------
-- fact_encounters: grain = one row per encounter.
-- Holds every dimension key needed by the four business questions plus
-- the measures pre-computed by the ETL (counts, billing totals, length
-- of stay, readmission flags), so most questions need no bridge, no
-- billing table and no self-join.
-- ---------------------------------------------------------------------
CREATE TABLE fact_encounters (
    encounter_key            BIGINT        NOT NULL AUTO_INCREMENT,
    encounter_id             INT           NOT NULL COMMENT 'Degenerate dimension (OLTP id)',

    -- dimension foreign keys (never NULL; -1 = Unknown member)
    encounter_date_key       INT           NOT NULL,
    discharge_date_key       INT           NOT NULL,
    patient_key              INT           NOT NULL,
    provider_key             INT           NOT NULL,
    specialty_key            INT           NOT NULL COMMENT 'Provider specialty at time of encounter',
    department_key           INT           NOT NULL,
    encounter_type_key       INT           NOT NULL,
    primary_diagnosis_key    INT           NOT NULL COMMENT 'Diagnosis with sequence 1',

    -- timestamps kept for interval maths
    encounter_datetime       DATETIME      NOT NULL,
    discharge_datetime       DATETIME      NULL,

    -- pre-aggregated / derived measures
    diagnosis_count          SMALLINT      NOT NULL DEFAULT 0,
    procedure_count          SMALLINT      NOT NULL DEFAULT 0,
    claim_count              SMALLINT      NOT NULL DEFAULT 0,
    total_claim_amount       DECIMAL(14,2) NOT NULL DEFAULT 0,
    total_allowed_amount     DECIMAL(14,2) NOT NULL DEFAULT 0,
    length_of_stay_hours     DECIMAL(8,2)  NULL,
    length_of_stay_days      SMALLINT      NULL COMMENT 'Midnights crossed',
    patient_age_at_encounter TINYINT UNSIGNED NULL,

    -- readmission logic, pre-computed in ETL (CMS-style: inpatient -> inpatient)
    is_index_admission       BOOLEAN       NOT NULL DEFAULT FALSE COMMENT 'Inpatient with a discharge date',
    is_readmitted_30d        BOOLEAN       NOT NULL DEFAULT FALSE COMMENT 'Another inpatient admit within 30 days of this discharge',
    days_to_next_admission   SMALLINT      NULL,
    is_readmission           BOOLEAN       NOT NULL DEFAULT FALSE COMMENT 'This admission is itself a 30-day readmission',

    -- audit
    etl_batch_id             INT           NULL,
    etl_loaded_at            DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (encounter_key),
    UNIQUE KEY uq_fact_encounter_id (encounter_id),

    -- Q1: month x specialty x type with distinct patients -> covering index
    KEY idx_fact_q1 (encounter_date_key, specialty_key, encounter_type_key, patient_key),
    -- Q3: specialty readmission rate, scanning only index admissions
    KEY idx_fact_q3 (is_index_admission, specialty_key, is_readmitted_30d),
    -- Q4: revenue by specialty and month -> covering index
    KEY idx_fact_q4 (specialty_key, encounter_date_key, claim_count, total_allowed_amount, total_claim_amount),
    -- patient history (ETL readmission recompute, drill-through)
    KEY idx_fact_patient_date (patient_key, encounter_datetime),
    KEY idx_fact_provider (provider_key),
    KEY idx_fact_department (department_key),

    CONSTRAINT fk_fact_enc_date   FOREIGN KEY (encounter_date_key)    REFERENCES dim_date(date_key),
    CONSTRAINT fk_fact_dis_date   FOREIGN KEY (discharge_date_key)    REFERENCES dim_date(date_key),
    CONSTRAINT fk_fact_patient    FOREIGN KEY (patient_key)           REFERENCES dim_patient(patient_key),
    CONSTRAINT fk_fact_provider   FOREIGN KEY (provider_key)          REFERENCES dim_provider(provider_key),
    CONSTRAINT fk_fact_specialty  FOREIGN KEY (specialty_key)         REFERENCES dim_specialty(specialty_key),
    CONSTRAINT fk_fact_department FOREIGN KEY (department_key)        REFERENCES dim_department(department_key),
    CONSTRAINT fk_fact_enc_type   FOREIGN KEY (encounter_type_key)    REFERENCES dim_encounter_type(encounter_type_key),
    CONSTRAINT fk_fact_primary_dx FOREIGN KEY (primary_diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key)
) ENGINE=InnoDB COMMENT='Encounter fact, grain = one encounter';

-- ---------------------------------------------------------------------
-- bridge_encounter_diagnoses: all diagnoses for an encounter.
-- Clustered on (encounter_key, diagnosis_sequence) so all of an
-- encounter's diagnoses sit together on disk; the secondary index
-- supports "all encounters with diagnosis X".
-- ---------------------------------------------------------------------
CREATE TABLE bridge_encounter_diagnoses (
    encounter_key      BIGINT   NOT NULL,
    diagnosis_sequence SMALLINT NOT NULL COMMENT '1 = primary',
    diagnosis_key      INT      NOT NULL,
    is_primary         BOOLEAN  NOT NULL DEFAULT FALSE,
    PRIMARY KEY (encounter_key, diagnosis_sequence),
    KEY idx_bed_diagnosis (diagnosis_key, encounter_key),
    CONSTRAINT fk_bed_encounter FOREIGN KEY (encounter_key) REFERENCES fact_encounters(encounter_key),
    CONSTRAINT fk_bed_diagnosis FOREIGN KEY (diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key)
) ENGINE=InnoDB COMMENT='Bridge: encounter <-> diagnosis (many-to-many)';

-- ---------------------------------------------------------------------
-- bridge_encounter_procedures: all procedures for an encounter.
-- ---------------------------------------------------------------------
CREATE TABLE bridge_encounter_procedures (
    encounter_key      BIGINT   NOT NULL,
    procedure_seq      SMALLINT NOT NULL COMMENT 'Order within encounter (by OLTP id)',
    procedure_key      INT      NOT NULL,
    procedure_date_key INT      NOT NULL,
    PRIMARY KEY (encounter_key, procedure_seq),
    KEY idx_bep_procedure (procedure_key, encounter_key),
    CONSTRAINT fk_bep_encounter FOREIGN KEY (encounter_key)      REFERENCES fact_encounters(encounter_key),
    CONSTRAINT fk_bep_procedure FOREIGN KEY (procedure_key)      REFERENCES dim_procedure(procedure_key),
    CONSTRAINT fk_bep_date      FOREIGN KEY (procedure_date_key) REFERENCES dim_date(date_key)
) ENGINE=InnoDB COMMENT='Bridge: encounter <-> procedure (many-to-many)';

-- ---------------------------------------------------------------------
-- agg_dx_px_pairs_monthly: aggregate built from the two bridges.
-- One row per (month, diagnosis, procedure) with the number of DISTINCT
-- encounters carrying both codes. Because an encounter falls in exactly
-- one month, encounter_count is additive across months, so any date
-- range can be answered with a plain SUM.
-- ---------------------------------------------------------------------
CREATE TABLE agg_dx_px_pairs_monthly (
    year_month_key   INT    NOT NULL COMMENT 'YYYYMM of encounter',
    diagnosis_key    INT    NOT NULL,
    procedure_key    INT    NOT NULL,
    encounter_count  INT    NOT NULL,
    PRIMARY KEY (year_month_key, diagnosis_key, procedure_key),
    KEY idx_agg_pair (diagnosis_key, procedure_key, encounter_count),
    CONSTRAINT fk_agg_dx FOREIGN KEY (diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key),
    CONSTRAINT fk_agg_px FOREIGN KEY (procedure_key) REFERENCES dim_procedure(procedure_key)
) ENGINE=InnoDB COMMENT='Aggregate: diagnosis-procedure co-occurrence by month';

-- ---------------------------------------------------------------------
-- etl_batch_log: watermark and audit table for incremental loads.
-- ---------------------------------------------------------------------
CREATE TABLE etl_batch_log (
    etl_batch_id      INT          NOT NULL AUTO_INCREMENT,
    started_at        DATETIME     NOT NULL,
    finished_at       DATETIME     NULL,
    high_watermark    DATETIME     NULL COMMENT 'Max source change timestamp processed',
    rows_inserted     INT          NULL,
    rows_updated      INT          NULL,
    status            VARCHAR(20)  NOT NULL DEFAULT 'RUNNING',
    PRIMARY KEY (etl_batch_id)
) ENGINE=InnoDB COMMENT='ETL run log / watermark';