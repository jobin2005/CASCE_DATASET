-- =====================================================================
-- Healthcare Database Schema (PostgreSQL 14+)
-- Covers: patients, providers, scheduling, encounters, clinical data,
--         prescriptions, labs, insurance & billing, auditing
-- =====================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS healthcare;
SET search_path TO healthcare;

-- ---------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------
CREATE TYPE sex_at_birth        AS ENUM ('male', 'female', 'intersex', 'unknown');
CREATE TYPE appointment_status  AS ENUM ('scheduled', 'confirmed', 'checked_in', 'completed', 'cancelled', 'no_show');
CREATE TYPE encounter_type      AS ENUM ('outpatient', 'inpatient', 'emergency', 'telehealth', 'home_visit');
CREATE TYPE prescription_status AS ENUM ('active', 'completed', 'discontinued', 'on_hold');
CREATE TYPE lab_order_status    AS ENUM ('ordered', 'collected', 'in_progress', 'resulted', 'cancelled');
CREATE TYPE claim_status        AS ENUM ('draft', 'submitted', 'accepted', 'denied', 'partially_paid', 'paid', 'appealed');
CREATE TYPE allergy_severity    AS ENUM ('mild', 'moderate', 'severe', 'life_threatening');

-- ---------------------------------------------------------------------
-- Shared trigger: keep updated_at current
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Organisation
-- ---------------------------------------------------------------------
CREATE TABLE facilities (
    facility_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            VARCHAR(200) NOT NULL,
    facility_type   VARCHAR(50)  NOT NULL,          -- hospital, clinic, lab, pharmacy
    npi             CHAR(10) UNIQUE,                -- National Provider Identifier (org)
    address_line1   VARCHAR(200) NOT NULL,
    address_line2   VARCHAR(200),
    city            VARCHAR(100) NOT NULL,
    state           VARCHAR(100) NOT NULL,
    postal_code     VARCHAR(20)  NOT NULL,
    country         CHAR(2)      NOT NULL DEFAULT 'US',
    phone           VARCHAR(30),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE departments (
    department_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facility_id     BIGINT NOT NULL REFERENCES facilities(facility_id),
    name            VARCHAR(150) NOT NULL,
    code            VARCHAR(20)  NOT NULL,
    UNIQUE (facility_id, code)
);

CREATE TABLE providers (
    provider_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    npi             CHAR(10) UNIQUE NOT NULL,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    credential      VARCHAR(20),                    -- MD, DO, NP, PA, RN
    specialty       VARCHAR(100),
    license_number  VARCHAR(50),
    license_state   VARCHAR(50),
    license_expires DATE,
    email           VARCHAR(255) UNIQUE,
    phone           VARCHAR(30),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE provider_departments (
    provider_id     BIGINT NOT NULL REFERENCES providers(provider_id) ON DELETE CASCADE,
    department_id   BIGINT NOT NULL REFERENCES departments(department_id) ON DELETE CASCADE,
    is_primary      BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (provider_id, department_id)
);

-- ---------------------------------------------------------------------
-- Patients
-- ---------------------------------------------------------------------
CREATE TABLE patients (
    patient_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mrn                 VARCHAR(20) UNIQUE NOT NULL,     -- Medical Record Number
    first_name          VARCHAR(100) NOT NULL,
    middle_name         VARCHAR(100),
    last_name           VARCHAR(100) NOT NULL,
    date_of_birth       DATE NOT NULL,
    sex_at_birth        sex_at_birth NOT NULL DEFAULT 'unknown',
    gender_identity     VARCHAR(50),
    ssn_last4           CHAR(4),
    email               VARCHAR(255),
    phone               VARCHAR(30),
    address_line1       VARCHAR(200),
    address_line2       VARCHAR(200),
    city                VARCHAR(100),
    state               VARCHAR(100),
    postal_code         VARCHAR(20),
    country             CHAR(2) DEFAULT 'US',
    preferred_language  VARCHAR(50) DEFAULT 'en',
    blood_type          VARCHAR(3) CHECK (blood_type IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
    primary_provider_id BIGINT REFERENCES providers(provider_id),
    is_deceased         BOOLEAN NOT NULL DEFAULT FALSE,
    deceased_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (date_of_birth <= CURRENT_DATE)
);
CREATE INDEX idx_patients_name ON patients (last_name, first_name);
CREATE INDEX idx_patients_dob  ON patients (date_of_birth);

CREATE TABLE emergency_contacts (
    contact_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    full_name       VARCHAR(200) NOT NULL,
    relationship    VARCHAR(50),
    phone           VARCHAR(30) NOT NULL,
    is_primary      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE allergies (
    allergy_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    allergen        VARCHAR(200) NOT NULL,
    reaction        VARCHAR(255),
    severity        allergy_severity NOT NULL,
    onset_date      DATE,
    recorded_by     BIGINT REFERENCES providers(provider_id),
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_allergies_patient ON allergies (patient_id);

-- ---------------------------------------------------------------------
-- Insurance
-- ---------------------------------------------------------------------
CREATE TABLE insurance_payers (
    payer_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            VARCHAR(200) NOT NULL,
    payer_code      VARCHAR(20) UNIQUE NOT NULL,
    phone           VARCHAR(30),
    claims_address  TEXT
);

CREATE TABLE patient_insurance (
    patient_insurance_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id           BIGINT NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    payer_id             BIGINT NOT NULL REFERENCES insurance_payers(payer_id),
    member_id            VARCHAR(50) NOT NULL,
    group_number         VARCHAR(50),
    plan_name            VARCHAR(150),
    subscriber_name      VARCHAR(200),
    relationship_to_subscriber VARCHAR(30) DEFAULT 'self',
    priority             SMALLINT NOT NULL DEFAULT 1 CHECK (priority BETWEEN 1 AND 3), -- 1=primary
    effective_date       DATE NOT NULL,
    termination_date     DATE,
    copay_amount         NUMERIC(10,2),
    CHECK (termination_date IS NULL OR termination_date >= effective_date)
);
CREATE INDEX idx_patient_insurance_patient ON patient_insurance (patient_id);

-- ---------------------------------------------------------------------
-- Scheduling & encounters
-- ---------------------------------------------------------------------
CREATE TABLE appointments (
    appointment_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      BIGINT NOT NULL REFERENCES patients(patient_id),
    provider_id     BIGINT NOT NULL REFERENCES providers(provider_id),
    department_id   BIGINT REFERENCES departments(department_id),
    scheduled_start TIMESTAMPTZ NOT NULL,
    scheduled_end   TIMESTAMPTZ NOT NULL,
    reason          VARCHAR(500),
    status          appointment_status NOT NULL DEFAULT 'scheduled',
    cancel_reason   VARCHAR(255),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (scheduled_end > scheduled_start)
);
CREATE INDEX idx_appointments_provider_time ON appointments (provider_id, scheduled_start);
CREATE INDEX idx_appointments_patient       ON appointments (patient_id, scheduled_start);

CREATE TABLE encounters (
    encounter_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      BIGINT NOT NULL REFERENCES patients(patient_id),
    provider_id     BIGINT NOT NULL REFERENCES providers(provider_id),
    facility_id     BIGINT NOT NULL REFERENCES facilities(facility_id),
    appointment_id  BIGINT UNIQUE REFERENCES appointments(appointment_id),
    encounter_type  encounter_type NOT NULL,
    admitted_at     TIMESTAMPTZ NOT NULL,
    discharged_at   TIMESTAMPTZ,
    chief_complaint TEXT,
    clinical_notes  TEXT,
    discharge_disposition VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (discharged_at IS NULL OR discharged_at >= admitted_at)
);
CREATE INDEX idx_encounters_patient ON encounters (patient_id, admitted_at DESC);

CREATE TABLE vitals (
    vital_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    encounter_id    BIGINT NOT NULL REFERENCES encounters(encounter_id) ON DELETE CASCADE,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    temperature_c   NUMERIC(4,1),
    heart_rate_bpm  SMALLINT,
    systolic_bp     SMALLINT,
    diastolic_bp    SMALLINT,
    respiratory_rate SMALLINT,
    spo2_percent    SMALLINT CHECK (spo2_percent BETWEEN 0 AND 100),
    height_cm       NUMERIC(5,1),
    weight_kg       NUMERIC(5,1),
    recorded_by     BIGINT REFERENCES providers(provider_id)
);

-- ---------------------------------------------------------------------
-- Clinical coding
-- ---------------------------------------------------------------------
CREATE TABLE icd10_codes (
    code            VARCHAR(10) PRIMARY KEY,
    description     VARCHAR(500) NOT NULL
);

CREATE TABLE cpt_codes (
    code            VARCHAR(10) PRIMARY KEY,
    description     VARCHAR(500) NOT NULL,
    standard_charge NUMERIC(12,2)
);

CREATE TABLE diagnoses (
    diagnosis_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    encounter_id    BIGINT NOT NULL REFERENCES encounters(encounter_id) ON DELETE CASCADE,
    icd10_code      VARCHAR(10) NOT NULL REFERENCES icd10_codes(code),
    is_primary      BOOLEAN NOT NULL DEFAULT FALSE,
    notes           TEXT,
    diagnosed_by    BIGINT REFERENCES providers(provider_id)
);
CREATE INDEX idx_diagnoses_encounter ON diagnoses (encounter_id);
CREATE INDEX idx_diagnoses_code      ON diagnoses (icd10_code);

CREATE TABLE procedures (
    procedure_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    encounter_id    BIGINT NOT NULL REFERENCES encounters(encounter_id) ON DELETE CASCADE,
    cpt_code        VARCHAR(10) NOT NULL REFERENCES cpt_codes(code),
    performed_by    BIGINT NOT NULL REFERENCES providers(provider_id),
    performed_at    TIMESTAMPTZ NOT NULL,
    notes           TEXT
);

-- ---------------------------------------------------------------------
-- Medications & prescriptions
-- ---------------------------------------------------------------------
CREATE TABLE medications (
    medication_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ndc_code        VARCHAR(20) UNIQUE,              -- National Drug Code
    generic_name    VARCHAR(200) NOT NULL,
    brand_name      VARCHAR(200),
    strength        VARCHAR(50),
    dosage_form     VARCHAR(50),                     -- tablet, capsule, injection
    is_controlled   BOOLEAN NOT NULL DEFAULT FALSE,
    dea_schedule    VARCHAR(5)
);

CREATE TABLE prescriptions (
    prescription_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      BIGINT NOT NULL REFERENCES patients(patient_id),
    encounter_id    BIGINT REFERENCES encounters(encounter_id),
    prescriber_id   BIGINT NOT NULL REFERENCES providers(provider_id),
    medication_id   BIGINT NOT NULL REFERENCES medications(medication_id),
    dose            VARCHAR(50) NOT NULL,
    route           VARCHAR(30) NOT NULL,            -- oral, IV, topical
    frequency       VARCHAR(50) NOT NULL,            -- BID, q8h
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    refills         SMALLINT NOT NULL DEFAULT 0 CHECK (refills >= 0),
    start_date      DATE NOT NULL,
    end_date        DATE,
    status          prescription_status NOT NULL DEFAULT 'active',
    instructions    TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_prescriptions_patient ON prescriptions (patient_id, status);

-- ---------------------------------------------------------------------
-- Laboratory
-- ---------------------------------------------------------------------
CREATE TABLE lab_tests (
    lab_test_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loinc_code      VARCHAR(20) UNIQUE NOT NULL,
    name            VARCHAR(200) NOT NULL,
    unit            VARCHAR(30),
    reference_low   NUMERIC(12,4),
    reference_high  NUMERIC(12,4),
    specimen_type   VARCHAR(50)
);

CREATE TABLE lab_orders (
    lab_order_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    encounter_id    BIGINT NOT NULL REFERENCES encounters(encounter_id),
    ordered_by      BIGINT NOT NULL REFERENCES providers(provider_id),
    lab_test_id     BIGINT NOT NULL REFERENCES lab_tests(lab_test_id),
    priority        VARCHAR(10) NOT NULL DEFAULT 'routine' CHECK (priority IN ('routine','urgent','stat')),
    status          lab_order_status NOT NULL DEFAULT 'ordered',
    ordered_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    collected_at    TIMESTAMPTZ
);

CREATE TABLE lab_results (
    lab_result_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lab_order_id    BIGINT NOT NULL REFERENCES lab_orders(lab_order_id) ON DELETE CASCADE,
    value_numeric   NUMERIC(12,4),
    value_text      VARCHAR(500),
    abnormal_flag   VARCHAR(2) CHECK (abnormal_flag IN ('N','L','H','LL','HH','A')),
    resulted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    verified_by     BIGINT REFERENCES providers(provider_id),
    comments        TEXT
);

-- ---------------------------------------------------------------------
-- Billing & claims
-- ---------------------------------------------------------------------
CREATE TABLE claims (
    claim_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_number         VARCHAR(30) UNIQUE NOT NULL,
    encounter_id         BIGINT NOT NULL REFERENCES encounters(encounter_id),
    patient_insurance_id BIGINT NOT NULL REFERENCES patient_insurance(patient_insurance_id),
    status               claim_status NOT NULL DEFAULT 'draft',
    total_billed         NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_allowed        NUMERIC(12,2),
    total_paid           NUMERIC(12,2) NOT NULL DEFAULT 0,
    patient_responsibility NUMERIC(12,2) NOT NULL DEFAULT 0,
    denial_reason        VARCHAR(255),
    submitted_at         TIMESTAMPTZ,
    adjudicated_at       TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_claims_status ON claims (status);

CREATE TABLE claim_lines (
    claim_line_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_id        BIGINT NOT NULL REFERENCES claims(claim_id) ON DELETE CASCADE,
    line_number     SMALLINT NOT NULL,
    cpt_code        VARCHAR(10) NOT NULL REFERENCES cpt_codes(code),
    icd10_code      VARCHAR(10) REFERENCES icd10_codes(code),
    units           SMALLINT NOT NULL DEFAULT 1 CHECK (units > 0),
    charge_amount   NUMERIC(12,2) NOT NULL CHECK (charge_amount >= 0),
    paid_amount     NUMERIC(12,2) NOT NULL DEFAULT 0,
    UNIQUE (claim_id, line_number)
);

CREATE TABLE patient_payments (
    payment_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      BIGINT NOT NULL REFERENCES patients(patient_id),
    claim_id        BIGINT REFERENCES claims(claim_id),
    amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    method          VARCHAR(20) NOT NULL CHECK (method IN ('cash','card','check','ach','other')),
    reference       VARCHAR(100),
    paid_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Audit log (HIPAA access tracking)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT,                          -- provider or staff id
    patient_id      BIGINT REFERENCES patients(patient_id),
    action          VARCHAR(20) NOT NULL CHECK (action IN ('view','create','update','delete','export','print')),
    table_name      VARCHAR(100) NOT NULL,
    record_id       BIGINT,
    ip_address      INET,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_patient ON audit_log (patient_id, occurred_at DESC);

-- ---------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_facilities_updated   BEFORE UPDATE ON facilities   FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_providers_updated    BEFORE UPDATE ON providers    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_patients_updated     BEFORE UPDATE ON patients     FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_appointments_updated BEFORE UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_claims_updated       BEFORE UPDATE ON claims       FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;