-- Seed data for Healthcare database

INSERT INTO departments (name, building, floor) VALUES
('Cardiology', 'Wing A', 3),
('Pediatrics', 'Wing B', 1),
('Neurology', 'Wing A', 4),
('Emergency Medicine', 'Main Pavilion', 1);

INSERT INTO doctors (dept_id, full_name, specialty, license_number, phone) VALUES
(1, 'Dr. Gregory House', 'Diagnostic Cardiology', 'MD-99201', '555-1001'),
(2, 'Dr. Allison Cameron', 'Pediatric Care', 'MD-88102', '555-1002'),
(3, 'Dr. James Wilson', 'Neurology', 'MD-77303', '555-1003'),
(4, 'Dr. Lisa Cuddy', 'Emergency Medicine', 'MD-66404', '555-1004');

INSERT INTO patients (full_name, dob, gender, blood_type, emergency_contact) VALUES
('Robert Chase', '1985-04-12', 'M', 'O+', '555-0901 (Wife)'),
('Amber Volakis', '1992-09-23', 'F', 'A-', '555-0902 (Mother)'),
('Eric Foreman', '1979-11-03', 'M', 'B+', '555-0903 (Father)'),
('Martha Masters', '1996-01-30', 'F', 'AB+', '555-0904 (Sister)');

INSERT INTO appointments (patient_id, doctor_id, appointment_date, reason, status) VALUES
(1, 1, CURRENT_TIMESTAMP - INTERVAL '2 days', 'Chronic chest pain and shortness of breath', 'COMPLETED'),
(2, 2, CURRENT_TIMESTAMP - INTERVAL '1 day', 'Routine wellness pediatric checkup', 'COMPLETED'),
(3, 3, CURRENT_TIMESTAMP + INTERVAL '1 day', 'Persistent migraines and aura', 'SCHEDULED');

INSERT INTO medical_records (patient_id, doctor_id, diagnosis, treatment_plan, visit_date) VALUES
(1, 1, 'Mild hypertension and arrhythmia', 'Low sodium diet, moderate cardio, prescribed Lisinopril', CURRENT_TIMESTAMP - INTERVAL '2 days'),
(2, 2, 'Seasonal allergic rhinitis', 'Antihistamines and allergen avoidance', CURRENT_TIMESTAMP - INTERVAL '1 day');

INSERT INTO prescriptions (record_id, patient_id, medication_name, dosage, frequency, refills_remaining) VALUES
(1, 1, 'Lisinopril', '10mg', 'Once daily in morning', 3),
(2, 2, 'Cetirizine', '5mg', 'Once daily at bedtime', 2);
