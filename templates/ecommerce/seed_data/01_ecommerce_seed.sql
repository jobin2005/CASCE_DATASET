-- Seed data for E-Commerce database

INSERT INTO categories (name, description) VALUES
('Electronics', 'Smartphones, laptops, monitors, and audio gear'),
('Apparel', 'Clothing, footwear, and accessories'),
('Home & Kitchen', 'Appliances, cookware, and furniture'),
('Books', 'Technical books, literature, and magazines');

INSERT INTO products (category_id, name, sku, price, stock_quantity) VALUES
(1, 'UltraBook Pro 15', 'TECH-LAP-001', 1299.99, 50),
(1, 'Wireless Noise-Cancelling Headphones', 'TECH-AUD-002', 199.99, 120),
(1, '4K Gaming Monitor 27"', 'TECH-MON-003', 349.50, 45),
(2, 'Classic Cotton T-Shirt', 'APP-TSH-010', 24.99, 300),
(2, 'All-Weather Waterproof Jacket', 'APP-JKT-011', 89.95, 80),
(3, 'Espresso Coffee Machine', 'HOME-COF-101', 249.00, 35),
(3, 'Stainless Steel Chef Knife 8"', 'HOME-KNF-102', 45.00, 150),
(4, 'Designing Data-Intensive Applications', 'BOOK-CS-501', 49.99, 200),
(4, 'PostgreSQL High Performance Manual', 'BOOK-DB-502', 59.95, 110);

INSERT INTO customers (email, first_name, last_name, address, city, postal_code, country) VALUES
('alice.smith@example.com', 'Alice', 'Smith', '742 Evergreen Terrace', 'Springfield', '97477', 'USA'),
('bob.jones@example.com', 'Bob', 'Jones', '10 Elm Street', 'Metropolis', '62960', 'USA'),
('clara.oswald@example.com', 'Clara', 'Oswald', '221B Baker Street', 'London', 'NW1 6XE', 'UK'),
('david.miller@example.com', 'David', 'Miller', '45 Friedrichstrasse', 'Berlin', '10117', 'Germany');

INSERT INTO orders (customer_id, order_date, status, total_amount, shipping_address) VALUES
(1, CURRENT_TIMESTAMP - INTERVAL '3 days', 'DELIVERED', 1499.98, '742 Evergreen Terrace, Springfield, 97477, USA'),
(2, CURRENT_TIMESTAMP - INTERVAL '1 day', 'PROCESSING', 249.00, '10 Elm Street, Metropolis, 62960, USA');

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
(1, 1, 1, 1299.99),
(1, 2, 1, 199.99),
(2, 6, 1, 249.00);

INSERT INTO payments (order_id, payment_method, amount, status) VALUES
(1, 'CREDIT_CARD', 1499.98, 'COMPLETED'),
(2, 'PAYPAL', 249.00, 'COMPLETED');

INSERT INTO reviews (product_id, customer_id, rating, comment) VALUES
(1, 1, 5, 'Superb build quality and battery life!'),
(2, 1, 4, 'Great sound isolation, slightly heavy on head.');

