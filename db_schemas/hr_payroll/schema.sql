-- ============================================================================
-- HR / Payroll Database Schema
-- ============================================================================

DROP TABLE IF EXISTS timesheets CASCADE;
DROP TABLE IF EXISTS salaries CASCADE;
DROP TABLE IF EXISTS employees CASCADE;
DROP TABLE IF EXISTS departments CASCADE;

CREATE TABLE departments (
    department_id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    cost_center VARCHAR(50) NOT NULL
);

CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    department_id INTEGER REFERENCES departments(department_id) ON DELETE RESTRICT,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    job_title VARCHAR(100) NOT NULL,
    hire_date DATE NOT NULL
);

CREATE TABLE salaries (
    salary_id SERIAL PRIMARY KEY,
    employee_id INTEGER REFERENCES employees(employee_id) ON DELETE CASCADE,
    annual_amount NUMERIC(12, 2) NOT NULL CHECK (annual_amount > 0),
    effective_date DATE NOT NULL
);

CREATE TABLE timesheets (
    timesheet_id SERIAL PRIMARY KEY,
    employee_id INTEGER REFERENCES employees(employee_id) ON DELETE CASCADE,
    week_start_date DATE NOT NULL,
    hours_worked NUMERIC(5, 2) NOT NULL CHECK (hours_worked >= 0 AND hours_worked <= 168),
    approved BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_employees_dept ON employees(department_id);
CREATE INDEX idx_salaries_emp ON salaries(employee_id);
CREATE INDEX idx_timesheets_emp ON timesheets(employee_id);
