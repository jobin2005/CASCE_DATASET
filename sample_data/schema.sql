CREATE TABLE IF NOT EXISTS customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   TEXT NOT NULL,
    email       TEXT UNIQUE NOT NULL,
    created_at  TIMESTAMP DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orders (
    order_id    SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(customer_id),
    amount      NUMERIC(10,2) NOT NULL,
    created_at  TIMESTAMP DEFAULT now()
);

CREATE TABLE IF NOT EXISTS payment_cards (
    card_id     SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(customer_id),
    card_number TEXT NOT NULL,
    expiry      DATE
);