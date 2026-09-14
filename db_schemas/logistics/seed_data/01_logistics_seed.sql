-- Seed data for Logistics database

INSERT INTO warehouses (code, city, country, capacity_sqft, current_utilization_pct) VALUES
('WH-ORD-01', 'Chicago', 'USA', 150000, 72.5),
('WH-DFW-02', 'Dallas', 'USA', 200000, 65.0),
('WH-SEA-03', 'Seattle', 'USA', 120000, 80.0),
('WH-FRA-04', 'Frankfurt', 'Germany', 180000, 55.0);

INSERT INTO carriers (company_name, contact_person, phone, service_tier) VALUES
('Apex Global Freight', 'Marcus Vance', '555-2001', 'EXPRESS'),
('Titan Line Logistics', 'Elena Rostova', '555-2002', 'FREIGHT'),
('SwiftAir Express', 'Kenji Sato', '555-2003', 'AIR');

INSERT INTO vehicles (carrier_id, license_plate, vehicle_type, capacity_kg, status) VALUES
(1, 'IL-TRK-9011', 'Semi-Trailer', 24000.00, 'AVAILABLE'),
(1, 'IL-VAN-4022', 'Sprinter Cargo Van', 3500.00, 'AVAILABLE'),
(2, 'TX-FRT-8800', 'Heavy Freight Truck', 32000.00, 'IN_TRANSIT'),
(3, 'WA-AIR-1010', 'Air Cargo Container Pod', 8000.00, 'AVAILABLE');

INSERT INTO inventory_items (sku, warehouse_id, product_name, quantity_on_hand, reorder_threshold) VALUES
('LOG-COMP-001', 1, 'Server Rack Enclosure 42U', 45, 10),
('LOG-COMP-002', 1, '10GbE Fiber Optic Switch', 120, 25),
('LOG-AUTO-010', 2, 'Lithium Traction Battery Module', 60, 15),
('LOG-AUTO-011', 2, 'Inverter Control Board', 180, 40),
('LOG-MED-050', 3, 'Centrifuge Medical Diagnostic Unit', 30, 8);

INSERT INTO shipments (origin_warehouse_id, dest_warehouse_id, carrier_id, vehicle_id, status, weight_kg, departure_time, estimated_arrival) VALUES
(1, 2, 1, 1, 'IN_TRANSIT', 5200.00, CURRENT_TIMESTAMP - INTERVAL '6 hours', CURRENT_TIMESTAMP + INTERVAL '18 hours'),
(2, 3, 2, 3, 'DISPATCHED', 12400.00, CURRENT_TIMESTAMP - INTERVAL '1 hour', CURRENT_TIMESTAMP + INTERVAL '30 hours');

INSERT INTO tracking_events (shipment_id, event_type, location, notes) VALUES
(1, 'DEPARTURE_SCAN', 'Chicago Hub (WH-ORD-01)', 'Departed on schedule via IL-TRK-9011'),
(1, 'WAYPOINT_PASS', 'St. Louis Transit Center', 'Weight check verified; GPS nominal'),
(2, 'DEPARTURE_SCAN', 'Dallas Facility (WH-DFW-02)', 'Cargo strapped and sealed');
