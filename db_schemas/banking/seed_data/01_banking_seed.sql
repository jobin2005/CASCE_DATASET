-- Seed data for Banking database

INSERT INTO branches (branch_name, city, state, assets) VALUES
('Downtown Main Branch', 'New York', 'NY', 25000000.00),
('Westside Plaza Branch', 'San Francisco', 'CA', 18000000.00),
('Midwest Regional Branch', 'Chicago', 'IL', 12000000.00);

INSERT INTO customers (full_name, ssn_hash, phone, email, address) VALUES
('Jonathan Edwards', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', '555-0101', 'j.edwards@example.com', '12 Wall Street, NY'),
('Sarah Connor', 'a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e', '555-0102', 's.connor@example.com', '45 Market St, SF'),
('Arthur Dent', '2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae', '555-0103', 'a.dent@example.com', '15 Country Lane, Chicago'),
('Bruce Wayne', 'fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9', '555-0104', 'b.wayne@example.com', '1007 Mountain Drive, Gotham');

INSERT INTO tellers (branch_id, teller_name, hire_date) VALUES
(1, 'Michael Scott', '2021-03-15'),
(2, 'Jim Halpert', '2022-06-01'),
(3, 'Pam Beesly', '2023-01-10');

INSERT INTO accounts (customer_id, branch_id, account_type, balance, status) VALUES
(1, 1, 'CHECKING', 15420.50, 'ACTIVE'),
(1, 1, 'SAVINGS', 48900.00, 'ACTIVE'),
(2, 2, 'CHECKING', 3200.75, 'ACTIVE'),
(3, 3, 'SAVINGS', 850.00, 'ACTIVE'),
(4, 1, 'BUSINESS', 5500000.00, 'ACTIVE');

INSERT INTO transactions (account_id, teller_id, txn_type, amount, balance_after, description) VALUES
(1, 1, 'DEPOSIT', 5000.00, 15420.50, 'Payroll direct deposit'),
(2, 2, 'WITHDRAWAL', 200.00, 3200.75, 'ATM cash withdrawal'),
(3, 3, 'DEPOSIT', 150.00, 850.00, 'Branch counter cash deposit');

INSERT INTO loans (customer_id, branch_id, amount, interest_rate, status) VALUES
(1, 1, 350000.00, 4.25, 'ACTIVE'),
(2, 2, 25000.00, 6.50, 'APPROVED');
