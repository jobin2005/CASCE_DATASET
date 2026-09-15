CREATE TABLE departments (
    dept_id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    code VARCHAR(10) UNIQUE NOT NULL,
    head_doctor_id INT,
    building VARCHAR(50),
    floor SMALLINT,
    phone VARCHAR(20),
    is_active BOOLEAN DEFAULT true
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    dept_id INT REFERENCES departments(dept_id) ON DELETE SET NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    specialty VARCHAR(100),
    license_number VARCHAR(50) UNIQUE NOT NULL,
    npi_number CHAR(10) UNIQUE NOT NULL,
    phone VARCHAR(20),
    email VARCHAR(100) UNIQUE NOT NULL,
    years_experience SMALLINT,
    is_active BOOLEAN DEFAULT true,
    joined_date DATE
);

ALTER TABLE departments
ADD CONSTRAINT fk_head_doctor FOREIGN KEY (head_doctor_id) REFERENCES doctors(doctor_id) ON DELETE SET NULL;

CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    mrn VARCHAR(12) UNIQUE NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    date_of_birth DATE NOT NULL,
    gender VARCHAR(10) CHECK (gender IN ('M', 'F', 'Other')),
    blood_type VARCHAR(5),
    phone VARCHAR(20),
    email VARCHAR(100),
    address VARCHAR(255),
    city VARCHAR(100),
    state VARCHAR(100),
    postal_code VARCHAR(20),
    allergies TEXT,
    emergency_contact_name VARCHAR(100),
    emergency_contact_phone VARCHAR(20),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    is_active BOOLEAN DEFAULT true
);

CREATE TABLE insurance (
    insurance_id SERIAL PRIMARY KEY,
    patient_id INT REFERENCES patients(patient_id) ON DELETE CASCADE,
    provider_name VARCHAR(100) NOT NULL,
    policy_number VARCHAR(50) UNIQUE NOT NULL,
    group_number VARCHAR(50),
    member_id VARCHAR(50),
    coverage_type VARCHAR(20) CHECK (coverage_type IN ('HMO', 'PPO', 'EPO', 'POS', 'MEDICAID', 'MEDICARE')),
    deductible NUMERIC(8, 2),
    copay NUMERIC(6, 2),
    coverage_start DATE,
    coverage_end DATE,
    is_active BOOLEAN DEFAULT true
);

CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INT REFERENCES patients(patient_id) ON DELETE CASCADE,
    doctor_id INT REFERENCES doctors(doctor_id) ON DELETE CASCADE,
    dept_id INT REFERENCES departments(dept_id) ON DELETE CASCADE,
    appointment_date TIMESTAMP WITH TIME ZONE NOT NULL,
    duration_minutes SMALLINT,
    reason TEXT,
    status VARCHAR(20) CHECK (status IN ('SCHEDULED', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED', 'NO_SHOW')),
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE medical_records (
    record_id SERIAL PRIMARY KEY,
    patient_id INT REFERENCES patients(patient_id) ON DELETE CASCADE,
    doctor_id INT REFERENCES doctors(doctor_id) ON DELETE CASCADE,
    appointment_id INT REFERENCES appointments(appointment_id) ON DELETE SET NULL,
    visit_date DATE NOT NULL,
    chief_complaint TEXT,
    diagnosis TEXT,
    diagnosis_code VARCHAR(10),
    treatment_plan TEXT,
    follow_up_date DATE,
    is_confidential BOOLEAN DEFAULT false
);

CREATE TABLE prescriptions (
    prescription_id SERIAL PRIMARY KEY,
    record_id INT REFERENCES medical_records(record_id) ON DELETE CASCADE,
    patient_id INT REFERENCES patients(patient_id) ON DELETE CASCADE,
    doctor_id INT REFERENCES doctors(doctor_id) ON DELETE CASCADE,
    medication_name VARCHAR(255) NOT NULL,
    dosage VARCHAR(100),
    frequency VARCHAR(100),
    route VARCHAR(30),
    days_supply SMALLINT,
    quantity SMALLINT,
    refills_allowed SMALLINT,
    refills_remaining SMALLINT,
    instructions TEXT,
    issued_date DATE NOT NULL,
    expiry_date DATE
);

CREATE TABLE lab_results (
    result_id SERIAL PRIMARY KEY,
    patient_id INT REFERENCES patients(patient_id) ON DELETE CASCADE,
    doctor_id INT REFERENCES doctors(doctor_id) ON DELETE CASCADE,
    record_id INT REFERENCES medical_records(record_id) ON DELETE SET NULL,
    test_name VARCHAR(100) NOT NULL,
    test_code VARCHAR(20),
    result_value VARCHAR(50),
    result_unit VARCHAR(20),
    reference_range VARCHAR(50),
    is_abnormal BOOLEAN,
    collected_at TIMESTAMP WITH TIME ZONE,
    resulted_at TIMESTAMP WITH TIME ZONE,
    notes TEXT
);

CREATE TABLE vital_signs (
    vitals_id SERIAL PRIMARY KEY,
    patient_id INT REFERENCES patients(patient_id) ON DELETE CASCADE,
    appointment_id INT REFERENCES appointments(appointment_id) ON DELETE CASCADE,
    temperature_c NUMERIC(4, 1),
    pulse_bpm SMALLINT,
    systolic_bp SMALLINT,
    diastolic_bp SMALLINT,
    respiratory_rate SMALLINT,
    oxygen_saturation NUMERIC(4, 1),
    weight_kg NUMERIC(5, 1),
    height_cm SMALLINT,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_doctors_dept ON doctors(dept_id);
CREATE INDEX idx_patients_mrn ON patients(mrn);
CREATE INDEX idx_insurance_patient ON insurance(patient_id);
CREATE INDEX idx_appointments_patient ON appointments(patient_id);
CREATE INDEX idx_appointments_doctor ON appointments(doctor_id);
CREATE INDEX idx_appointments_date ON appointments(appointment_date);
CREATE INDEX idx_medical_records_patient ON medical_records(patient_id);
CREATE INDEX idx_prescriptions_patient ON prescriptions(patient_id);
CREATE INDEX idx_lab_results_patient ON lab_results(patient_id);
CREATE INDEX idx_vital_signs_patient ON vital_signs(patient_id);
