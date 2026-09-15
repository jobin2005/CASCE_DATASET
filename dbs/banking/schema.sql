
CREATE TABLE branches (
    branch_id SERIAL PRIMARY KEY,
    branch_code VARCHAR(10) UNIQUE NOT NULL,
    branch_name VARCHAR(100) NOT NULL,
    address VARCHAR(200) NOT NULL,
    city VARCHAR(100) NOT NULL,
    state VARCHAR(50) NOT NULL,
    country VARCHAR(50) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    routing_number VARCHAR(20) UNIQUE NOT NULL,
    manager_id INT,
    assets NUMERIC(18,2) NOT NULL,
    opened_date DATE NOT NULL
);

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    customer_number VARCHAR(20) UNIQUE NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    phone VARCHAR(20) NOT NULL,
    date_of_birth DATE NOT NULL,
    ssn_hash CHAR(64) NOT NULL,
    address VARCHAR(200) NOT NULL,
    city VARCHAR(100) NOT NULL,
    state VARCHAR(50) NOT NULL,
    postal_code VARCHAR(20) NOT NULL,
    country VARCHAR(50) NOT NULL,
    kyc_status VARCHAR(20) NOT NULL CHECK (kyc_status IN ('PENDING','VERIFIED','REJECTED')),
    credit_score SMALLINT NOT NULL CHECK (credit_score BETWEEN 300 AND 850),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL,
    is_active BOOLEAN NOT NULL
);

CREATE TABLE tellers (
    teller_id SERIAL PRIMARY KEY,
    branch_id INT NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    employee_id VARCHAR(20) UNIQUE NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    hire_date DATE NOT NULL,
    is_active BOOLEAN NOT NULL
);

CREATE TABLE accounts (
    account_id SERIAL PRIMARY KEY,
    account_number CHAR(16) UNIQUE NOT NULL,
    customer_id INT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    branch_id INT NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    account_type VARCHAR(20) NOT NULL CHECK (account_type IN ('CHECKING','SAVINGS','BUSINESS','CD','MONEY_MARKET')),
    balance NUMERIC(14,2) NOT NULL,
    interest_rate NUMERIC(5,4) NOT NULL,
    overdraft_limit NUMERIC(10,2) NOT NULL,
    status VARCHAR(20) NOT NULL CHECK (status IN ('ACTIVE','FROZEN','DORMANT','CLOSED')),
    opened_at TIMESTAMP WITH TIME ZONE NOT NULL,
    closed_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE transactions (
    txn_id SERIAL PRIMARY KEY,
    account_id INT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    teller_id INT REFERENCES tellers(teller_id) ON DELETE SET NULL,
    txn_type VARCHAR(20) NOT NULL CHECK (txn_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER_IN','TRANSFER_OUT','FEE','INTEREST','REVERSAL')),
    amount NUMERIC(12,2) NOT NULL,
    balance_after NUMERIC(14,2) NOT NULL,
    reference_number VARCHAR(32) UNIQUE NOT NULL,
    merchant_name VARCHAR(100),
    category VARCHAR(50),
    is_reversal BOOLEAN NOT NULL,
    original_txn_id INT REFERENCES transactions(txn_id) ON DELETE SET NULL,
    description TEXT,
    txn_time TIMESTAMP WITH TIME ZONE NOT NULL
);

CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,
    loan_number VARCHAR(20) UNIQUE NOT NULL,
    customer_id INT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    branch_id INT NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    loan_type VARCHAR(20) NOT NULL CHECK (loan_type IN ('PERSONAL','MORTGAGE','AUTO','BUSINESS','STUDENT')),
    principal NUMERIC(14,2) NOT NULL,
    interest_rate NUMERIC(5,4) NOT NULL,
    term_months SMALLINT NOT NULL,
    monthly_installment NUMERIC(10,2) NOT NULL,
    outstanding_balance NUMERIC(14,2) NOT NULL,
    status VARCHAR(20) NOT NULL CHECK (status IN ('PENDING','ACTIVE','CLOSED','DEFAULTED')),
    disbursed_at TIMESTAMP WITH TIME ZONE,
    next_due_date DATE
);

CREATE TABLE loan_payments (
    payment_id SERIAL PRIMARY KEY,
    loan_id INT NOT NULL REFERENCES loans(loan_id) ON DELETE CASCADE,
    amount NUMERIC(10,2) NOT NULL,
    principal_component NUMERIC(10,2) NOT NULL,
    interest_component NUMERIC(10,2) NOT NULL,
    paid_at TIMESTAMP WITH TIME ZONE NOT NULL,
    payment_method VARCHAR(30) NOT NULL
);

CREATE TABLE audit_log (
    log_id SERIAL PRIMARY KEY,
    table_name VARCHAR(50) NOT NULL,
    record_id INT NOT NULL,
    action VARCHAR(10) NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
    changed_by VARCHAR(100) NOT NULL,
    changed_at TIMESTAMP WITH TIME ZONE NOT NULL,
    old_values JSONB,
    new_values JSONB
);

-- Add indexes
CREATE INDEX idx_customers_email ON customers(email);
CREATE INDEX idx_accounts_customer_id ON accounts(customer_id);
CREATE INDEX idx_transactions_account_id ON transactions(account_id);
CREATE INDEX idx_transactions_txn_time ON transactions(txn_time);
CREATE INDEX idx_loans_customer_id ON loans(customer_id);
