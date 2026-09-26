-- =====================================================================
-- Banking Database Schema (PostgreSQL 14+)
-- Covers: customers & KYC, branches, account products, accounts,
--         double-entry ledger, transfers, cards, loans, auditing
-- =====================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS banking;
SET search_path TO banking;

-- ---------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------
CREATE TYPE customer_type    AS ENUM ('individual', 'business');
CREATE TYPE kyc_status       AS ENUM ('pending', 'verified', 'rejected', 'expired');
CREATE TYPE account_status   AS ENUM ('pending', 'active', 'dormant', 'frozen', 'closed');
CREATE TYPE account_category AS ENUM ('checking', 'savings', 'fixed_deposit', 'loan', 'credit_card', 'internal');
CREATE TYPE holder_role      AS ENUM ('primary', 'joint', 'authorized_signatory', 'beneficiary');
CREATE TYPE entry_direction  AS ENUM ('debit', 'credit');
CREATE TYPE txn_status       AS ENUM ('pending', 'posted', 'reversed', 'failed');
CREATE TYPE transfer_status  AS ENUM ('initiated', 'processing', 'completed', 'failed', 'cancelled');
CREATE TYPE card_status      AS ENUM ('issued', 'active', 'blocked', 'expired', 'cancelled');
CREATE TYPE loan_status      AS ENUM ('applied', 'approved', 'rejected', 'disbursed', 'active', 'delinquent', 'closed', 'written_off');

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
CREATE TABLE currencies (
    currency_code   CHAR(3) PRIMARY KEY,             -- ISO 4217
    name            VARCHAR(50) NOT NULL,
    minor_units     SMALLINT NOT NULL DEFAULT 2
);

CREATE TABLE exchange_rates (
    base_currency   CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    quote_currency  CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    rate            NUMERIC(18,8) NOT NULL CHECK (rate > 0),
    effective_at    TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (base_currency, quote_currency, effective_at)
);

CREATE TABLE branches (
    branch_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_code     VARCHAR(20) UNIQUE NOT NULL,     -- e.g. IFSC / sort code / routing
    name            VARCHAR(150) NOT NULL,
    address         TEXT NOT NULL,
    city            VARCHAR(100) NOT NULL,
    country         CHAR(2) NOT NULL,
    phone           VARCHAR(30),
    opened_on       DATE NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE employees (
    employee_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_id       BIGINT REFERENCES branches(branch_id),
    employee_code   VARCHAR(20) UNIQUE NOT NULL,
    full_name       VARCHAR(200) NOT NULL,
    role            VARCHAR(50) NOT NULL,            -- teller, loan_officer, manager
    email           VARCHAR(255) UNIQUE NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------------
-- Customers & KYC
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_number VARCHAR(20) UNIQUE NOT NULL,
    customer_type   customer_type NOT NULL,
    -- individual fields
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    date_of_birth   DATE,
    national_id_hash VARCHAR(128),                   -- store hashed, never raw
    -- business fields
    legal_name      VARCHAR(255),
    registration_no VARCHAR(50),
    -- common
    email           VARCHAR(255),
    phone           VARCHAR(30),
    kyc_status      kyc_status NOT NULL DEFAULT 'pending',
    risk_rating     VARCHAR(10) NOT NULL DEFAULT 'low' CHECK (risk_rating IN ('low','medium','high')),
    home_branch_id  BIGINT REFERENCES branches(branch_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (
        (customer_type = 'individual' AND first_name IS NOT NULL AND last_name IS NOT NULL)
     OR (customer_type = 'business'   AND legal_name IS NOT NULL)
    )
);
CREATE INDEX idx_customers_name ON customers (last_name, first_name);

CREATE TABLE customer_addresses (
    address_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    address_type    VARCHAR(20) NOT NULL CHECK (address_type IN ('residential','mailing','business')),
    line1           VARCHAR(200) NOT NULL,
    line2           VARCHAR(200),
    city            VARCHAR(100) NOT NULL,
    state           VARCHAR(100),
    postal_code     VARCHAR(20),
    country         CHAR(2) NOT NULL,
    valid_from      DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_to        DATE
);

CREATE TABLE kyc_documents (
    document_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    document_type   VARCHAR(30) NOT NULL,            -- passport, drivers_license, utility_bill
    document_number_hash VARCHAR(128) NOT NULL,
    issuing_country CHAR(2),
    issued_on       DATE,
    expires_on      DATE,
    storage_uri     TEXT NOT NULL,
    status          kyc_status NOT NULL DEFAULT 'pending',
    verified_by     BIGINT REFERENCES employees(employee_id),
    verified_at     TIMESTAMPTZ
);

-- ---------------------------------------------------------------------
-- Products & accounts
-- ---------------------------------------------------------------------
CREATE TABLE account_products (
    product_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_code    VARCHAR(20) UNIQUE NOT NULL,
    name            VARCHAR(100) NOT NULL,
    category        account_category NOT NULL,
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    interest_rate   NUMERIC(7,4) NOT NULL DEFAULT 0,  -- annual %
    minimum_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
    monthly_fee     NUMERIC(10,2) NOT NULL DEFAULT 0,
    overdraft_limit NUMERIC(18,2) NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE accounts (
    account_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_number  VARCHAR(34) UNIQUE NOT NULL,     -- fits IBAN
    product_id      BIGINT NOT NULL REFERENCES account_products(product_id),
    branch_id       BIGINT NOT NULL REFERENCES branches(branch_id),
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    status          account_status NOT NULL DEFAULT 'pending',
    -- cached balances, authoritative source is ledger_entries
    ledger_balance    NUMERIC(18,2) NOT NULL DEFAULT 0,
    available_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
    opened_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at       TIMESTAMPTZ,
    last_activity_at TIMESTAMPTZ,
    version         INTEGER NOT NULL DEFAULT 0,      -- optimistic locking
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_accounts_status ON accounts (status);

CREATE TABLE account_holders (
    account_id      BIGINT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    role            holder_role NOT NULL DEFAULT 'primary',
    added_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, customer_id)
);
CREATE INDEX idx_account_holders_customer ON account_holders (customer_id);

-- ---------------------------------------------------------------------
-- Double-entry ledger
-- A transaction groups balanced ledger entries (sum debits = sum credits)
-- ---------------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference       VARCHAR(40) UNIQUE NOT NULL,
    transaction_type VARCHAR(30) NOT NULL,           -- deposit, withdrawal, transfer, fee, interest, loan_disbursement
    channel         VARCHAR(20) NOT NULL,            -- branch, atm, online, mobile, pos, batch
    description     VARCHAR(255),
    status          txn_status NOT NULL DEFAULT 'pending',
    initiated_by    BIGINT REFERENCES employees(employee_id),
    idempotency_key VARCHAR(64) UNIQUE,
    value_date      DATE NOT NULL DEFAULT CURRENT_DATE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    posted_at       TIMESTAMPTZ,
    reversal_of     BIGINT REFERENCES transactions(transaction_id)
);
CREATE INDEX idx_transactions_created ON transactions (created_at);

CREATE TABLE ledger_entries (
    entry_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT NOT NULL REFERENCES transactions(transaction_id),
    account_id      BIGINT NOT NULL REFERENCES accounts(account_id),
    direction       entry_direction NOT NULL,
    amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    balance_after   NUMERIC(18,2),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_ledger_account_time ON ledger_entries (account_id, created_at DESC);
CREATE INDEX idx_ledger_txn          ON ledger_entries (transaction_id);

-- Ledger entries are immutable: corrections happen via reversal transactions
CREATE OR REPLACE FUNCTION forbid_ledger_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'ledger_entries are append-only';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_ledger_no_update BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION forbid_ledger_mutation();

-- ---------------------------------------------------------------------
-- Payees & transfers
-- ---------------------------------------------------------------------
CREATE TABLE payees (
    payee_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    nickname        VARCHAR(100),
    payee_name      VARCHAR(200) NOT NULL,
    bank_name       VARCHAR(200),
    bank_code       VARCHAR(20),                     -- SWIFT/BIC, routing, IFSC
    account_number  VARCHAR(34) NOT NULL,
    currency_code   CHAR(3) REFERENCES currencies(currency_code),
    is_verified     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE transfers (
    transfer_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_account_id BIGINT NOT NULL REFERENCES accounts(account_id),
    to_account_id   BIGINT REFERENCES accounts(account_id),   -- internal
    payee_id        BIGINT REFERENCES payees(payee_id),       -- external
    amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    fx_rate         NUMERIC(18,8),
    fee_amount      NUMERIC(10,2) NOT NULL DEFAULT 0,
    rail            VARCHAR(20) NOT NULL,            -- internal, ach, wire, swift, sepa, upi, imps, neft
    status          transfer_status NOT NULL DEFAULT 'initiated',
    transaction_id  BIGINT REFERENCES transactions(transaction_id),
    memo            VARCHAR(255),
    scheduled_for   DATE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at    TIMESTAMPTZ,
    failure_reason  VARCHAR(255),
    CHECK ((to_account_id IS NOT NULL) <> (payee_id IS NOT NULL))
);
CREATE INDEX idx_transfers_from ON transfers (from_account_id, created_at DESC);

CREATE TABLE standing_orders (
    standing_order_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_account_id BIGINT NOT NULL REFERENCES accounts(account_id),
    payee_id        BIGINT NOT NULL REFERENCES payees(payee_id),
    amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    frequency       VARCHAR(10) NOT NULL CHECK (frequency IN ('weekly','monthly','quarterly','yearly')),
    next_run_date   DATE NOT NULL,
    end_date        DATE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------------
-- Cards
-- ---------------------------------------------------------------------
CREATE TABLE cards (
    card_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id      BIGINT NOT NULL REFERENCES accounts(account_id),
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    card_type       VARCHAR(10) NOT NULL CHECK (card_type IN ('debit','credit','prepaid')),
    network         VARCHAR(20) NOT NULL,            -- visa, mastercard, rupay, amex
    pan_token       VARCHAR(64) UNIQUE NOT NULL,     -- tokenised PAN (PCI-DSS)
    last4           CHAR(4) NOT NULL,
    expiry_month    SMALLINT NOT NULL CHECK (expiry_month BETWEEN 1 AND 12),
    expiry_year     SMALLINT NOT NULL,
    status          card_status NOT NULL DEFAULT 'issued',
    daily_limit     NUMERIC(12,2),
    credit_limit    NUMERIC(18,2),
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE card_authorizations (
    authorization_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    card_id         BIGINT NOT NULL REFERENCES cards(card_id),
    merchant_name   VARCHAR(200),
    merchant_category_code CHAR(4),
    amount          NUMERIC(18,2) NOT NULL,
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    approved        BOOLEAN NOT NULL,
    decline_reason  VARCHAR(100),
    transaction_id  BIGINT REFERENCES transactions(transaction_id),
    authorized_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_card_auth_card ON card_authorizations (card_id, authorized_at DESC);

-- ---------------------------------------------------------------------
-- Loans
-- ---------------------------------------------------------------------
CREATE TABLE loans (
    loan_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_number     VARCHAR(20) UNIQUE NOT NULL,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    loan_account_id BIGINT UNIQUE REFERENCES accounts(account_id),
    disbursement_account_id BIGINT REFERENCES accounts(account_id),
    loan_type       VARCHAR(30) NOT NULL,            -- personal, home, auto, business, education
    principal       NUMERIC(18,2) NOT NULL CHECK (principal > 0),
    interest_rate   NUMERIC(7,4) NOT NULL,
    term_months     SMALLINT NOT NULL CHECK (term_months > 0),
    status          loan_status NOT NULL DEFAULT 'applied',
    collateral_description TEXT,
    officer_id      BIGINT REFERENCES employees(employee_id),
    applied_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_at     TIMESTAMPTZ,
    disbursed_at    TIMESTAMPTZ,
    maturity_date   DATE,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE loan_schedule (
    loan_id         BIGINT NOT NULL REFERENCES loans(loan_id) ON DELETE CASCADE,
    installment_no  SMALLINT NOT NULL,
    due_date        DATE NOT NULL,
    principal_due   NUMERIC(18,2) NOT NULL,
    interest_due    NUMERIC(18,2) NOT NULL,
    principal_paid  NUMERIC(18,2) NOT NULL DEFAULT 0,
    interest_paid   NUMERIC(18,2) NOT NULL DEFAULT 0,
    penalty_amount  NUMERIC(18,2) NOT NULL DEFAULT 0,
    paid_on         DATE,
    PRIMARY KEY (loan_id, installment_no)
);
CREATE INDEX idx_loan_schedule_due ON loan_schedule (due_date) WHERE paid_on IS NULL;

-- ---------------------------------------------------------------------
-- Compliance & audit
-- ---------------------------------------------------------------------
CREATE TABLE aml_alerts (
    alert_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    transaction_id  BIGINT REFERENCES transactions(transaction_id),
    rule_code       VARCHAR(50) NOT NULL,
    score           NUMERIC(5,2),
    status          VARCHAR(30) NOT NULL DEFAULT 'open' CHECK (status IN ('open','investigating','escalated','closed_false_positive','reported')),
    assigned_to     BIGINT REFERENCES employees(employee_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at     TIMESTAMPTZ
);

CREATE TABLE audit_log (
    audit_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_type      VARCHAR(20) NOT NULL CHECK (actor_type IN ('employee','customer','system')),
    actor_id        BIGINT,
    action          VARCHAR(50) NOT NULL,
    entity          VARCHAR(50) NOT NULL,
    entity_id       BIGINT,
    old_values      JSONB,
    new_values      JSONB,
    ip_address      INET,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_entity ON audit_log (entity, entity_id);

CREATE TRIGGER trg_customers_updated BEFORE UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_accounts_updated  BEFORE UPDATE ON accounts  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_loans_updated     BEFORE UPDATE ON loans     FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;