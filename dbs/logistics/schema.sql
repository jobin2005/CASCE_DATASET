CREATE TABLE warehouses (
    warehouse_id SERIAL PRIMARY KEY,
    code VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(150) NOT NULL,
    address VARCHAR(255) NOT NULL,
    city VARCHAR(100) NOT NULL,
    state VARCHAR(100),
    country VARCHAR(100) NOT NULL,
    latitude NUMERIC(9,6),
    longitude NUMERIC(9,6),
    capacity_sqft INTEGER,
    current_utilization_pct NUMERIC(5,2),
    timezone VARCHAR(50),
    manager_name VARCHAR(100),
    manager_phone VARCHAR(50),
    is_hazmat_certified BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE carriers (
    carrier_id SERIAL PRIMARY KEY,
    company_name VARCHAR(150) NOT NULL,
    carrier_code VARCHAR(50) UNIQUE NOT NULL,
    contact_name VARCHAR(100),
    phone VARCHAR(50),
    email VARCHAR(150),
    service_tiers TEXT,
    dot_number VARCHAR(20),
    mc_number VARCHAR(20),
    insurance_expiry DATE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    carrier_id INTEGER NOT NULL REFERENCES carriers(carrier_id) ON DELETE CASCADE,
    license_plate VARCHAR(50) UNIQUE NOT NULL,
    vehicle_type VARCHAR(50) CHECK (vehicle_type IN ('SEMI','BOX_TRUCK','VAN','FLATBED','REFRIGERATED','AIR_CARGO')),
    capacity_kg NUMERIC(10,2),
    max_volume_cbm NUMERIC(8,2),
    fuel_type VARCHAR(20),
    manufacture_year SMALLINT,
    last_service_date DATE,
    current_location VARCHAR(100),
    status VARCHAR(50) CHECK (status IN ('AVAILABLE','IN_TRANSIT','MAINTENANCE','DECOMMISSIONED')),
    is_hazmat_certified BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE inventory_items (
    sku VARCHAR(64) PRIMARY KEY,
    warehouse_id INTEGER NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE CASCADE,
    product_name VARCHAR(200) NOT NULL,
    category VARCHAR(100),
    quantity_on_hand INTEGER NOT NULL DEFAULT 0,
    reserved_quantity INTEGER NOT NULL DEFAULT 0,
    reorder_threshold INTEGER NOT NULL DEFAULT 0,
    unit_weight_kg NUMERIC(8,3),
    unit_volume_cbm NUMERIC(8,4),
    unit_cost NUMERIC(10,2),
    last_restocked_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE shipments (
    shipment_id SERIAL PRIMARY KEY,
    shipment_number VARCHAR(100) UNIQUE NOT NULL,
    origin_warehouse_id INTEGER NOT NULL REFERENCES warehouses(warehouse_id),
    dest_warehouse_id INTEGER NOT NULL REFERENCES warehouses(warehouse_id),
    carrier_id INTEGER NOT NULL REFERENCES carriers(carrier_id),
    vehicle_id INTEGER REFERENCES vehicles(vehicle_id),
    status VARCHAR(50) CHECK (status IN ('DRAFT','BOOKED','DISPATCHED','IN_TRANSIT','OUT_FOR_DELIVERY','DELIVERED','FAILED','CANCELLED')),
    total_weight_kg NUMERIC(10,2),
    total_volume_cbm NUMERIC(8,2),
    declared_value NUMERIC(12,2),
    currency CHAR(3) NOT NULL DEFAULT 'USD',
    is_fragile BOOLEAN NOT NULL DEFAULT FALSE,
    is_hazmat BOOLEAN NOT NULL DEFAULT FALSE,
    special_instructions TEXT,
    customs_ref VARCHAR(100),
    priority VARCHAR(50) CHECK (priority IN ('STANDARD','EXPRESS','SAME_DAY','FREIGHT')),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    dispatched_at TIMESTAMP WITH TIME ZONE,
    estimated_arrival TIMESTAMP WITH TIME ZONE,
    actual_arrival TIMESTAMP WITH TIME ZONE
);

CREATE TABLE shipment_items (
    item_id SERIAL PRIMARY KEY,
    shipment_id INTEGER NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    sku VARCHAR(64) NOT NULL REFERENCES inventory_items(sku),
    quantity INTEGER NOT NULL,
    unit_weight_kg NUMERIC(8,3),
    description VARCHAR(255)
);

CREATE TABLE tracking_events (
    event_id SERIAL PRIMARY KEY,
    shipment_id INTEGER NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    event_type VARCHAR(60) NOT NULL,
    location VARCHAR(150) NOT NULL,
    latitude NUMERIC(9,6),
    longitude NUMERIC(9,6),
    carrier_scan_code VARCHAR(40),
    temperature_c NUMERIC(4,1),
    notes TEXT,
    recorded_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE TABLE routes (
    route_id SERIAL PRIMARY KEY,
    origin_warehouse_id INTEGER NOT NULL REFERENCES warehouses(warehouse_id),
    dest_warehouse_id INTEGER NOT NULL REFERENCES warehouses(warehouse_id),
    carrier_id INTEGER NOT NULL REFERENCES carriers(carrier_id),
    transit_days_standard SMALLINT,
    transit_days_express SMALLINT,
    distance_km NUMERIC(8,2),
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE invoices (
    invoice_id SERIAL PRIMARY KEY,
    shipment_id INTEGER NOT NULL REFERENCES shipments(shipment_id),
    invoice_number VARCHAR(100) UNIQUE NOT NULL,
    amount NUMERIC(12,2) NOT NULL,
    currency CHAR(3) NOT NULL DEFAULT 'USD',
    status VARCHAR(50) CHECK (status IN ('DRAFT','ISSUED','PAID','OVERDUE','CANCELLED')),
    issued_at TIMESTAMP WITH TIME ZONE,
    due_date TIMESTAMP WITH TIME ZONE,
    paid_at TIMESTAMP WITH TIME ZONE
);

-- Indexes
CREATE INDEX idx_warehouses_code ON warehouses(code);
CREATE INDEX idx_carriers_code ON carriers(carrier_code);
CREATE INDEX idx_vehicles_carrier ON vehicles(carrier_id);
CREATE INDEX idx_vehicles_license ON vehicles(license_plate);
CREATE INDEX idx_inventory_warehouse ON inventory_items(warehouse_id);
CREATE INDEX idx_shipments_number ON shipments(shipment_number);
CREATE INDEX idx_shipments_origin ON shipments(origin_warehouse_id);
CREATE INDEX idx_shipments_dest ON shipments(dest_warehouse_id);
CREATE INDEX idx_shipment_items_shipment ON shipment_items(shipment_id);
CREATE INDEX idx_tracking_shipment ON tracking_events(shipment_id);
CREATE INDEX idx_routes_origin_dest ON routes(origin_warehouse_id, dest_warehouse_id);
CREATE INDEX idx_invoices_shipment ON invoices(shipment_id);
CREATE INDEX idx_invoices_number ON invoices(invoice_number);
