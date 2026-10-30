
-- Healthcare Analytics: OLTP Schema
-- Script: 01_oltp_schema.sql

CREATE DATABASE IF NOT EXISTS healthcare_analytics;
USE healthcare_analytics;

-- 1. Patients
CREATE TABLE patients (
    patient_id INT PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    date_of_birth DATE,
    gender VARCHAR(20),
    mrn VARCHAR(30) UNIQUE
);

-- 2. Specialties
CREATE TABLE specialties (
    specialty_id INT PRIMARY KEY,
    specialty_name VARCHAR(100) NOT NULL,
    specialty_code VARCHAR(20)
);

-- 3. Departments
CREATE TABLE departments (
    department_id INT PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL,
    floor INT,
    capacity INT
);

-- 4. Providers
CREATE TABLE providers (
    provider_id INT PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    credential VARCHAR(50),
    specialty_id INT,
    department_id INT,
    FOREIGN KEY (specialty_id)
        REFERENCES specialties(specialty_id),
    FOREIGN KEY (department_id)
        REFERENCES departments(department_id)
);

-- 5. Encounters
CREATE TABLE encounters (
    encounter_id INT PRIMARY KEY,
    patient_id INT NOT NULL,
    provider_id INT NOT NULL,
    encounter_type VARCHAR(50),
    encounter_date DATETIME NOT NULL,   -- was DATE: kept only the day, dropped the time
    discharge_date DATETIME,
    department_id INT,
    FOREIGN KEY (patient_id)
        REFERENCES patients(patient_id),
    FOREIGN KEY (provider_id)
        REFERENCES providers(provider_id),
    FOREIGN KEY (department_id)
        REFERENCES departments(department_id),
    INDEX idx_encounter_date (encounter_date)
);

-- 6. Diagnoses
CREATE TABLE diagnoses (
    diagnosis_id INT PRIMARY KEY,
    icd10_code VARCHAR(10) NOT NULL,
    icd10_description VARCHAR(255)
);

-- 7. Encounter-Diagnosis junction table
CREATE TABLE encounter_diagnoses (
    encounter_diagnosis_id INT PRIMARY KEY,
    encounter_id INT NOT NULL,
    diagnosis_id INT NOT NULL,
    diagnosis_sequence INT,
    FOREIGN KEY (encounter_id)
        REFERENCES encounters(encounter_id),
    FOREIGN KEY (diagnosis_id)
        REFERENCES diagnoses(diagnosis_id)
);

-- 8. Procedures
CREATE TABLE procedures (
    procedure_id INT PRIMARY KEY,
    cpt_code VARCHAR(10) NOT NULL,
    cpt_description VARCHAR(255)
);

-- 9. Encounter-Procedure junction table
CREATE TABLE encounter_procedures (
    encounter_procedure_id INT PRIMARY KEY,
    encounter_id INT NOT NULL,
    procedure_id INT NOT NULL,
    procedure_date DATE,
    FOREIGN KEY (encounter_id)
        REFERENCES encounters(encounter_id),
    FOREIGN KEY (procedure_id)
        REFERENCES procedures(procedure_id)
);

-- 10. Billing
CREATE TABLE billing (
    billing_id INT PRIMARY KEY,
    encounter_id INT NOT NULL,
    claim_amount DECIMAL(10,2),
    allowed_amount DECIMAL(10,2),
    claim_date DATE,
    claim_status VARCHAR(30),
    FOREIGN KEY (encounter_id)
        REFERENCES encounters(encounter_id),
    INDEX idx_claim_date (claim_date)
);