-- ============================================================================
-- Logistics Database Schema
-- ============================================================================

DROP TABLE IF EXISTS tracking_events CASCADE;
DROP TABLE IF EXISTS shipments CASCADE;
DROP TABLE IF EXISTS inventory_items CASCADE;
DROP TABLE IF EXISTS vehicles CASCADE;
DROP TABLE IF EXISTS carriers CASCADE;
DROP TABLE IF EXISTS warehouses CASCADE;

CREATE TABLE warehouses (
    warehouse_id SERIAL PRIMARY KEY,
    code VARCHAR(30) UNIQUE NOT NULL,
    city VARCHAR(100) NOT NULL,
    country VARCHAR(100) NOT NULL,
    capacity_sqft INTEGER NOT NULL CHECK (capacity_sqft > 0),
    current_utilization_pct NUMERIC(5, 2) NOT NULL DEFAULT 0.0 CHECK (current_utilization_pct >= 0 AND current_utilization_pct <= 100)
);

CREATE TABLE carriers (
    carrier_id SERIAL PRIMARY KEY,
    company_name VARCHAR(150) NOT NULL,
    contact_person VARCHAR(100) NOT NULL,
    phone VARCHAR(30) NOT NULL,
    service_tier VARCHAR(30) NOT NULL DEFAULT 'STANDARD' CHECK (service_tier IN ('STANDARD', 'EXPRESS', 'FREIGHT', 'AIR'))
);

CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    carrier_id INTEGER REFERENCES carriers(carrier_id) ON DELETE CASCADE,
    license_plate VARCHAR(30) UNIQUE NOT NULL,
    vehicle_type VARCHAR(50) NOT NULL,
    capacity_kg NUMERIC(10, 2) NOT NULL CHECK (capacity_kg > 0),
    status VARCHAR(30) NOT NULL DEFAULT 'AVAILABLE' CHECK (status IN ('AVAILABLE', 'IN_TRANSIT', 'MAINTENANCE', 'DECOMMISSIONED'))
);

CREATE TABLE inventory_items (
    sku VARCHAR(64) PRIMARY KEY,
    warehouse_id INTEGER REFERENCES warehouses(warehouse_id) ON DELETE CASCADE,
    product_name VARCHAR(255) NOT NULL,
    quantity_on_hand INTEGER NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
    reorder_threshold INTEGER NOT NULL DEFAULT 10 CHECK (reorder_threshold >= 0)
);

CREATE TABLE shipments (
    shipment_id SERIAL PRIMARY KEY,
    origin_warehouse_id INTEGER REFERENCES warehouses(warehouse_id) ON DELETE RESTRICT,
    dest_warehouse_id INTEGER REFERENCES warehouses(warehouse_id) ON DELETE RESTRICT,
    carrier_id INTEGER REFERENCES carriers(carrier_id) ON DELETE RESTRICT,
    vehicle_id INTEGER REFERENCES vehicles(vehicle_id) ON DELETE SET NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'CREATED' CHECK (status IN ('CREATED', 'DISPATCHED', 'IN_TRANSIT', 'DELIVERED', 'CANCELLED')),
    weight_kg NUMERIC(10, 2) NOT NULL CHECK (weight_kg > 0),
    departure_time TIMESTAMP WITH TIME ZONE,
    estimated_arrival TIMESTAMP WITH TIME ZONE
);

CREATE TABLE tracking_events (
    event_id SERIAL PRIMARY KEY,
    shipment_id INTEGER REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    event_type VARCHAR(50) NOT NULL,
    location VARCHAR(150) NOT NULL,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    notes TEXT
);

CREATE INDEX idx_shipments_origin ON shipments(origin_warehouse_id);
CREATE INDEX idx_shipments_dest ON shipments(dest_warehouse_id);
CREATE INDEX idx_tracking_shipment ON tracking_events(shipment_id);
CREATE INDEX idx_inventory_warehouse ON inventory_items(warehouse_id);

